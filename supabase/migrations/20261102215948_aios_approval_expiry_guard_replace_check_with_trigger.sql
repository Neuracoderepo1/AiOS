-- Replace the CHECK with a trigger guard. Insert: NULL expiry is defaulted to now()+24h. Update: a pending approval with a valid
-- expiry can never be cleared. The single quarantined legacy NULL row (manual-review) is intentionally untouched; the janitor
-- (private.aios_expire_stale_approvals) still converges legacy NULL rows via its 24h-from-creation fallback.
alter table public.aios_approvals drop constraint if exists aios_approvals_pending_expiry_required;
create or replace function private.aios_approval_default_expiry()
returns trigger language plpgsql security definer set search_path = ''
as $$
begin
  if new.status = 'pending' and new.expires_at is null then
    if tg_op = 'INSERT' then
      new.expires_at := now() + interval '24 hours';
    elsif old.expires_at is not null then
      raise exception 'a pending approval must keep a valid expiry' using errcode = '23514';
    end if;
  end if;
  return new;
end $$;
revoke all on function private.aios_approval_default_expiry() from public, anon, authenticated;
drop trigger if exists trg_aios_approval_default_expiry on public.aios_approvals;
create trigger trg_aios_approval_default_expiry
  before insert or update of expires_at, status on public.aios_approvals
  for each row execute function private.aios_approval_default_expiry();
