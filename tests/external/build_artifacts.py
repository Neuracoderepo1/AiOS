#!/usr/bin/env python3
"""Phase 2 of tests/external/e2e.sh: builds EXTERNALLY RETAINED checkpoint artifacts for positions 6 (git) and 9 (RFC3161).
Everything created here is a labelled TEST_FIXTURE: a throw-away OpenSSL CA/TSA and a local git repo. None of it is production evidence."""
import hashlib, json, os, shutil, subprocess, sys

D = sys.argv[1]
ORG = "e2e00000-0000-4000-8000-0000000000e1"
digests = json.load(open(os.path.join(D, "digests.json")))


def sh(*a, cwd=None, env=None):
    r = subprocess.run(a, cwd=cwd, capture_output=True, text=True, env=env)
    if r.returncode: sys.exit("command failed: %s\n%s%s" % (a, r.stdout, r.stderr))
    return r.stdout


def checkpoint_text_py(org, count, head_id, head_hash, head_at_iso):   # independent of the verifier module: written out again on purpose
    m = __import__("re").match(r"^(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2})(\.\d+)?\+00:00$", head_at_iso)
    frac = ((m.group(2) or ".")[1:] + "000000")[:6]
    return "aios-audit-checkpoint-v1\n%s\n%s\n%s\n%s\n%s.%sZ" % (org, count, head_id, head_hash, m.group(1), frac)


cpd = os.path.join(D, "checkpoints", ORG); shutil.rmtree(os.path.join(D, "checkpoints"), ignore_errors=True); os.makedirs(cpd)
tsa = os.path.join(D, "tsa"); shutil.rmtree(tsa, ignore_errors=True); os.makedirs(tsa)
for other in ("tsa_other",):
    shutil.rmtree(os.path.join(D, other), ignore_errors=True)

# --- test TSA ---------------------------------------------------------------------------------------------------------------------------------
def make_ca(dirn, cn):
    os.makedirs(dirn, exist_ok=True)
    sh("openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-keyout", "ca.key", "-out", "ca.crt", "-subj", "/CN=%s" % cn, "-days", "2", cwd=dirn)
    sh("openssl", "req", "-newkey", "rsa:2048", "-nodes", "-keyout", "tsa.key", "-out", "tsa.csr", "-subj", "/CN=AIOS TEST TSA (TEST_FIXTURE)", cwd=dirn)
    open(os.path.join(dirn, "ext.cnf"), "w").write("extendedKeyUsage = critical, timeStamping\nbasicConstraints = CA:FALSE\n")
    sh("openssl", "x509", "-req", "-in", "tsa.csr", "-CA", "ca.crt", "-CAkey", "ca.key", "-CAcreateserial", "-out", "tsa.crt", "-days", "2", "-extfile", "ext.cnf", cwd=dirn)
    open(os.path.join(dirn, "tsa_serial"), "w").write("01\n")
    open(os.path.join(dirn, "ts.cnf"), "w").write("""[ tsa ]
default_tsa = t1
[ t1 ]
dir = .
serial = ./tsa_serial
crypto_device = builtin
signer_cert = ./tsa.crt
certs = ./ca.crt
signer_key = ./tsa.key
default_policy = 1.2.3.4.5
other_policies = 1.2.3.4.6
signer_digest = sha256
digests = sha256
accuracy = secs:1
ordering = yes
tsa_name = yes
ess_cert_id_chain = no
ess_cert_id_alg = sha256
""")
make_ca(tsa, "AIOS TEST CA (TEST_FIXTURE)")
make_ca(os.path.join(D, "tsa_other"), "OTHER UNTRUSTED CA (TEST_FIXTURE)")

anchors = []
for d in digests:
    n = d["event_count"]
    text = checkpoint_text_py(ORG, n, d["head_id"], d["head_hash"], d["head_at"])
    assert text == d["checkpoint_text"], "python checkpoint text differs from the database's aios_audit_checkpoint_text (n=%d)" % n
    digest = hashlib.sha256(text.encode()).hexdigest()
    assert digest == d["digest"], "python checkpoint digest differs from the database digest (n=%d)" % n
    cp = dict(version="aios-audit-checkpoint-v1", organization_id=ORG, event_count=n, head_event_id=d["head_id"], head_hash=d["head_hash"], head_at_iso=d["head_at"],
              checkpoint_sha256=digest, **{"class": "TEST_FIXTURE"})
    if n == 6:   # git evidence: a local repository whose origin identity is declared
        repo = os.path.join(cpd, "repo"); os.makedirs(os.path.join(repo, "cp", ORG), exist_ok=True)
        sh("git", "init", "-q", "-b", "main", repo)
        sh("git", "-C", repo, "remote", "add", "origin", "https://github.com/example/aios-audit-checkpoints.git")
        open(os.path.join(repo, "cp", ORG, "%d.txt" % n), "w", newline="").write(text)
        env = dict(os.environ, GIT_AUTHOR_NAME="t", GIT_AUTHOR_EMAIL="t@example.test", GIT_COMMITTER_NAME="t", GIT_COMMITTER_EMAIL="t@example.test")
        sh("git", "-C", repo, "add", "."); sh("git", "-C", repo, "commit", "-q", "-m", "checkpoint %d" % n, env=env)
        commit = sh("git", "-C", repo, "rev-parse", "HEAD").strip()
        cp.update(evidence_type="git", artifact_sha256=digest, artifact=dict(repo_dir="repo", commit=commit, manifest_path="cp/%s/%d.txt" % (ORG, n)))
        ev = dict(repository="example/aios-audit-checkpoints", commit=commit, manifest_path="cp/%s/%d.txt" % (ORG, n), manifest_sha256=digest, verified_by="e2e-build_artifacts", **{"class": "TEST_FIXTURE"})
        anchors.append(dict(event_count=n, head_event_id=d["head_id"], head_hash=d["head_hash"], head_at=d["head_at"], evidence_type="git", artifact_sha256=digest, artifact_ref="git:example/aios-audit-checkpoints@%s" % commit, evidence=ev))
    else:        # RFC3161: real token from the throw-away TSA over the exact checkpoint text
        txt = os.path.join(cpd, "%d.txt" % n); open(txt, "w", newline="").write(text)
        sh("openssl", "ts", "-query", "-data", txt, "-sha256", "-cert", "-out", os.path.join(cpd, "%d.tsq" % n))
        sh("openssl", "ts", "-reply", "-queryfile", os.path.join(cpd, "%d.tsq" % n), "-config", "ts.cnf", "-section", "t1", "-out", os.path.join(cpd, "%d.tsr" % n), cwd=tsa)
        tokhash = hashlib.sha256(open(os.path.join(cpd, "%d.tsr" % n), "rb").read()).hexdigest()
        cp.update(evidence_type="rfc3161", artifact_sha256=tokhash, artifact=dict(tsr="%d.tsr" % n, checkpoint_text="%d.txt" % n))
        ev = dict(message_imprint=digest, token_sha256=tokhash, tsa_name="AIOS TEST TSA (TEST_FIXTURE)", gen_time="2026-03-01T00:00:00Z", verified_by="e2e-build_artifacts", **{"class": "TEST_FIXTURE"})
        anchors.append(dict(event_count=n, head_event_id=d["head_id"], head_hash=d["head_hash"], head_at=d["head_at"], evidence_type="rfc3161", artifact_sha256=tokhash, artifact_ref="test://tsr/%d" % n, evidence=ev))
    json.dump(cp, open(os.path.join(cpd, "%d.checkpoint.json" % n), "w"), indent=2)
json.dump(anchors, open(os.path.join(D, "anchors_for_db.json"), "w"))
shutil.copy(os.path.join(tsa, "ca.crt"), os.path.join(D, "tsa-roots.pem"))
shutil.copy(os.path.join(D, "tsa_other", "ca.crt"), os.path.join(D, "tsa-roots-other.pem"))
print("built %d checkpoints (TEST_FIXTURE)" % len(anchors))
