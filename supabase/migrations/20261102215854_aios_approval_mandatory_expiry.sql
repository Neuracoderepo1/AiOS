-- Mandatory expiry for pending approvals (step 1; superseded in part by 20261102215948).
-- Adds a BEFORE INSERT default of now()+24h and a pending-expiry CHECK. The CHECK was replaced by a trigger guard in the next
-- migration because CHECK constraints also fire under session_replication_role=replica and broke legacy-shaped test fixtures.
create or replace function private.aios_approval_default_expiry()
returns trigger language plpgsql security definer set search_path = ''
as $$
begin
  if new.status = 'pending' and new.expires_at is null then
    new.expires_at := now() + interval '24 hours';
  end if;
  return new;
end $$;
revoke all on function private.aios_approval_default_expiry() from public, anon, authenticated;
drop trigger if exists trg_aios_approval_default_expiry on public.aios_approvals;
create trigger trg_aios_approval_default_expiry
  before insert on public.aios_approvals
  for each row execute function private.aios_approval_default_expiry();
alter table public.aios_approvals
  add constraint aios_approvals_pending_expiry_required
  check (status <> 'pending' or expires_at is not null) not valid;
