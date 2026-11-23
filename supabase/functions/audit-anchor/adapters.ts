// External anchor adapters. Secrets come ONLY from environment variables (never committed, never logged).
import { AnchorAdapter, AdapterResult, Checkpoint, ExternalDependencyBlocked, sha256Hex } from "./core.ts";

const b64 = (s: string) => btoa(String.fromCharCode(...new TextEncoder().encode(s)));
const unb64 = (s: string) => new TextDecoder().decode(Uint8Array.from(atob(s.replace(/\n/g, "")), (c) => c.charCodeAt(0)));

/** Git checkpoint: commits the exact checkpoint text to a dedicated repository via the GitHub contents API, then READS IT BACK at the commit SHA.
 *  Env: AUDIT_CHECKPOINT_GITHUB_REPO (owner/name), AUDIT_CHECKPOINT_GITHUB_TOKEN (fine-grained, contents:write on that repo only), AUDIT_CHECKPOINT_BRANCH (default main). */
export class GitAnchorAdapter implements AnchorAdapter {
  readonly type = "git" as const;
  constructor(private env: { repo?: string; token?: string; branch?: string }, private fetcher: typeof fetch = fetch) {}
  async submit(cp: Checkpoint): Promise<AdapterResult> {
    const { repo, token } = this.env, branch = this.env.branch ?? "main";
    if (!repo || !token) throw new ExternalDependencyBlocked("git checkpoint repository/token not configured (AUDIT_CHECKPOINT_GITHUB_REPO / _TOKEN)");
    if (!/^[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+$/.test(repo)) throw new Error("invalid repository name");
    const path = `cp/${cp.organization_id}/${cp.event_count}.txt`;
    const url = `https://api.github.com/repos/${repo}/contents/${path}`;
    const h = { authorization: `Bearer ${token}`, accept: "application/vnd.github+json", "content-type": "application/json", "user-agent": "aios-audit-anchor" };
    const put = await this.fetcher(url, { method: "PUT", headers: h, body: JSON.stringify({ message: `audit checkpoint ${cp.organization_id} #${cp.event_count}`, content: b64(cp.text), branch }) });
    let commit: string | undefined;
    if (put.status === 201 || put.status === 200) commit = (await put.json())?.commit?.sha;
    else if (put.status === 422) {   // already exists (idempotent retry): find the commit that holds this exact content
      const cur = await this.fetcher(`${url}?ref=${branch}`, { headers: h });
      if (!cur.ok) throw new Error(`git contents lookup failed: ${cur.status}`);
      const body = await cur.json();
      if (unb64(body.content) !== cp.text) throw new Error("a DIFFERENT manifest already exists at this path");
      const lc = await this.fetcher(`https://api.github.com/repos/${repo}/commits?path=${path}&sha=${branch}&per_page=1`, { headers: h });
      commit = (await lc.json())?.[0]?.sha;
    } else throw new Error(`git commit failed: ${put.status}`);
    if (!commit || !/^[0-9a-f]{40}$/.test(commit)) throw new Error("no commit sha returned");
    // read back at the commit SHA: the retained artifact must equal the checkpoint text exactly
    const rb = await this.fetcher(`${url}?ref=${commit}`, { headers: h });
    if (!rb.ok) throw new Error(`git read-back failed: ${rb.status}`);
    const back = unb64((await rb.json()).content);
    if (back !== cp.text || (await sha256Hex(back)) !== cp.digest) throw new Error("git read-back does not match the checkpoint");
    return {
      artifact_sha256: cp.digest, artifact_ref: `git:${repo}@${commit}`,
      evidence: { repository: repo, commit, manifest_path: path, manifest_sha256: cp.digest, verified_by: "audit-anchor-edge-function", verification: "git_readback_ok" },
    };
  }
}

/** RFC3161: BLOCKED until a real TSA and a token verifier are configured and independently validated.
 *  A token must be verified cryptographically (message imprint, signature, certificate chain to pinned trust roots, validity, policy) BEFORE being
 *  submitted. The Deno runtime has no vetted CMS/TSP verifier, so this adapter refuses to fabricate evidence. tools/audit-verify (OpenSSL) verifies
 *  retained tokens in CI. Env that must exist before this can be enabled: AUDIT_TSA_URL, AUDIT_TSA_TRUST_ROOTS_PEM, AUDIT_TSA_VERIFIER_URL. */
export class Rfc3161Adapter implements AnchorAdapter {
  readonly type = "rfc3161" as const;
  constructor(private env: { tsaUrl?: string; trustRoots?: string; verifierUrl?: string }) {}
  submit(_cp: Checkpoint): Promise<AdapterResult> {
    if (!this.env.tsaUrl || !this.env.trustRoots || !this.env.verifierUrl) {
      return Promise.reject(new ExternalDependencyBlocked("RFC3161 TSA, pinned trust roots and a token verifier are not configured (EXTERNAL_DEPENDENCY_BLOCKED)"));
    }
    return Promise.reject(new ExternalDependencyBlocked("RFC3161 live anchoring is not implemented/validated in this release (EXTERNAL_DEPENDENCY_BLOCKED)"));
  }
}
