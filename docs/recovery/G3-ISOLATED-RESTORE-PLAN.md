# G3 Isolated Restore Plan

**Status:** DESIGN COMPLETE; target availability NOT VERIFIED.

## Zero-budget candidate

Use an already-installed local PostgreSQL server on the Human Director's Mac if it is present and has adequate disk space. No external SSD is assumed. No paid Supabase branch/project or additional hosted service is proposed.

The repository CI already provisions an ephemeral local Supabase/PostgreSQL stack and executes synthetic export/restore and preflight-matrix tests. This is useful repeatable engineering evidence, but GitHub-hosted CI is not the approved long-term production recovery target: it is ephemeral, not owner-controlled backup storage, and may have retention/size limits.

## Compatibility requirements

- Match the source PostgreSQL major version or document and test an explicit supported upgrade/downgrade path. Current recorded hosted observation: PostgreSQL 17.6.
- Install all required extension binaries/control files before restore. Extension metadata in a dump cannot install provider-managed binaries.
- Compare Supabase-specific extensions and provider-managed objects; a generic PostgreSQL install may not reproduce Supabase Auth, Storage, Realtime, Edge Functions, Vault, cron, secrets, or provider control-plane settings.
- Keep target network-bound to loopback and isolate it from unrelated local applications.
- Require free space for the encrypted artifact, temporary decrypted archive, restored database, WAL/temp overhead and evidence. If capacity is unknown or insufficient, stop before export.
- Disable outbound side effects and do not reuse production secrets.

## Target readiness checklist

- [ ] Local PostgreSQL version and binaries identified.
- [ ] Required extension binaries available.
- [ ] Local disk free space measured and adequate.
- [ ] FileVault status confirmed by owner.
- [ ] Workspace location excluded from cloud sync.
- [ ] Loopback-only binding verified.
- [ ] Fresh `aios_restore_*` database created.
- [ ] Restore credentials local-only and protected.
- [ ] Outbound integrations disabled.
- [ ] Synthetic restore completed and evidence retained.
- [ ] Agent 003 accepts the target design.

## Known limitations

The agent cannot inspect the Human Director's local device, FileVault state, free storage or installed PostgreSQL binaries from the connected GitHub/Supabase integrations. Do not infer those facts from the user's previous macOS version. Until owner-side checks are supplied, target readiness remains BLOCKED.

A local-only backup is not off-site disaster recovery. Google Drive remains the preferred off-site destination but is not currently connected or verified. No alternate destination is approved by this plan.
