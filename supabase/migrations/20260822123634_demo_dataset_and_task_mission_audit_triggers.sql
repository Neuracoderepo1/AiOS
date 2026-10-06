-- 1) A real, seeded dataset for the demo mission to actually query. Labeled
-- clearly as demo data, not real customer data — this is what makes the
-- "analysis" a real aggregation rather than an LLM inventing numbers.
create table if not exists public.aios_demo_support_tickets (
  id uuid primary key default gen_random_uuid(),
  category text not null,
  issue_summary text not null,
  created_at timestamptz not null default now()
);
comment on table public.aios_demo_support_tickets is
  'Synthetic demo data for exercising the mission execution loop. Not real customer data.';

alter table public.aios_demo_support_tickets enable row level security;
create policy aios_demo_tickets_read on public.aios_demo_support_tickets
  for select to authenticated, anon using (true);

insert into public.aios_demo_support_tickets (category, issue_summary)
select category, issue_summary from (values
  ('Login failures', 'User cannot log in after password reset'),
  ('Login failures', '2FA code never arrives via SMS'),
  ('Login failures', 'Session expires immediately after login'),
  ('Login failures', 'SSO redirect loop on enterprise plan'),
  ('Login failures', 'Locked out after 3 failed attempts, no unlock email'),
  ('Login failures', 'Password reset link expired within a minute'),
  ('Login failures', 'Cannot log in on mobile app, works on web'),
  ('Billing discrepancies', 'Charged twice for the same monthly invoice'),
  ('Billing discrepancies', 'Upgrade proration calculated incorrectly'),
  ('Billing discrepancies', 'Invoice shows wrong currency'),
  ('Billing discrepancies', 'Refund never processed after cancellation'),
  ('Billing discrepancies', 'Coupon code not applied at checkout'),
  ('Billing discrepancies', 'Annual plan charged at monthly rate'),
  ('Data export timeouts', 'CSV export hangs at 90 percent'),
  ('Data export timeouts', 'Large export silently fails with no error'),
  ('Data export timeouts', 'Export API returns 504 on datasets over 50k rows'),
  ('Data export timeouts', 'Scheduled export job stuck in queued state'),
  ('Notification delivery delays', 'Email alerts arrive 6+ hours late'),
  ('Notification delivery delays', 'Push notifications not arriving on iOS'),
  ('Notification delivery delays', 'Slack integration stops posting after a few days'),
  ('Notification delivery delays', 'Digest email sent at wrong time zone'),
  ('Notification delivery delays', 'Webhook retries flood the endpoint'),
  ('Permission/access errors', 'Team member cannot access shared workspace'),
  ('Permission/access errors', 'Admin role downgraded unexpectedly'),
  ('Permission/access errors', 'Guest user can see restricted project'),
  ('Permission/access errors', 'API key scoped incorrectly, missing read access'),
  ('UI rendering bugs', 'Dashboard chart overlaps on small screens'),
  ('UI rendering bugs', 'Dark mode toggle does not persist'),
  ('UI rendering bugs', 'Table columns misaligned after filtering'),
  ('Mobile app crashes', 'App crashes on opening settings page'),
  ('Mobile app crashes', 'Crash when switching organizations'),
  ('Integration sync issues', 'Salesforce sync drops custom fields'),
  ('Integration sync issues', 'Zapier trigger fires twice per event')
) as t(category, issue_summary);

-- 2) Same pattern as the tool-invocation audit trigger: task and mission status
-- changes are now structurally guaranteed to produce an audit event, not
-- dependent on the execute-task function remembering to write one.
create or replace function public.aios_log_task_status_audit()
returns trigger
language plpgsql
security definer
set search_path to 'public'
as $$
begin
  if tg_op = 'UPDATE' and new.status is distinct from old.status then
    insert into public.aios_audit_events(
      organization_id, agent_id, task_id, event_type, risk_level, action, decision, metadata
    ) values (
      new.organization_id, new.assigned_agent_id, new.id,
      'task_status_changed', new.risk_level, new.title, new.status,
      jsonb_build_object('previous_status', old.status, 'mission_id', new.mission_id)
    );
  end if;
  return new;
end;
$$;

create trigger aios_tasks_audit_log
after update of status on public.aios_tasks
for each row execute function public.aios_log_task_status_audit();

create or replace function public.aios_log_mission_status_audit()
returns trigger
language plpgsql
security definer
set search_path to 'public'
as $$
begin
  if tg_op = 'UPDATE' and new.status is distinct from old.status then
    insert into public.aios_audit_events(
      organization_id, event_type, risk_level, action, decision, metadata
    ) values (
      new.organization_id, 'mission_status_changed', 'low', new.title, new.status,
      jsonb_build_object('previous_status', old.status, 'mission_id', new.id)
    );
  end if;
  return new;
end;
$$;

create trigger aios_missions_audit_log
after update of status on public.aios_missions
for each row execute function public.aios_log_mission_status_audit();
