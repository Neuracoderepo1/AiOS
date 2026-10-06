# AiOS

**Agent Execution Control.** Core principle: *access is not authority.*

AiOS is a deterministic execution-control layer between autonomous agents and production systems. A model can only *propose*; the database kernel decides whether anything runs.

```
MODEL -> UNTRUSTED PROPOSAL -> TOOL REGISTRY -> CANONICAL EXECUTION KERNEL
 -> AGENT IDENTITY -> ACTIVE CONTRACT -> RISK + LIMITS -> APPROVAL BOUNDARY
 -> TRUSTED EXECUTOR -> OUTPUT VALIDATION -> EVALUATION -> MEMORY -> AUDIT CHAIN
```

## Components

- **Supabase Postgres** (project `jtkcdwhiduixoiodhbfn`): `aios_*` tables, RLS, and the kernel functions (`public` and `private` schemas). The database is the core.
- **Edge Functions** (`supabase/functions/`): `launch-mission`, `execute-task`, `invoke-tool`, `review-approval`. They authenticate the caller, then call the kernel; they do not hold authority themselves.
- **Docs** (`docs/`): current deployment state and known security findings.

## Status

This repository is a source-controlled baseline of the **current live implementation**. Live end-to-end certification is a separate phase and has **not** been performed. See `docs/operations/current-state.md` for exactly what is and is not captured.
