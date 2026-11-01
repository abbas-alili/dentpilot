-- =============================================================================
-- Stage 4 · Migration 4 of 5 — Row-level security and grants
--
-- The job worker (run-jobs Edge Function) connects as dentpilot_agent, the
-- same as the webhook: it claims jobs through ops functions, then sets
-- app.clinic_id = job.clinic_id before doing that clinic's work. No direct
-- table access to ops is granted to the agent.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 1. RLS (enabled, not forced: SECURITY DEFINER functions own these writes)
-- -----------------------------------------------------------------------------
alter table ops.background_jobs     enable row level security;   -- no policies: functions only
alter table ops.staff_notifications enable row level security;
alter table ops.push_subscriptions  enable row level security;

create policy own_notifications on ops.staff_notifications
  for select to authenticated
  using (user_id = auth.uid());

create policy own_push_subscriptions on ops.push_subscriptions
  for select to authenticated
  using (user_id = auth.uid());

create policy delete_own_push_subscriptions on ops.push_subscriptions
  for delete to authenticated
  using (user_id = auth.uid());

-- -----------------------------------------------------------------------------
-- 2. dentpilot_agent (webhook + job worker)
-- -----------------------------------------------------------------------------
grant usage on schema ops to dentpilot_agent;

grant execute on function
  ops.enqueue_job(text, uuid, jsonb, text, timestamptz, int),
  ops.claim_jobs(text[], int, text, int),
  ops.complete_job(uuid),
  ops.fail_job(uuid, text),
  ops.run_approval_reminder(uuid),
  ops.push_targets(uuid),
  ops.record_push_result(uuid, boolean, boolean),
  core.appointment_message_details(uuid),
  core.confirm_attendance(uuid, uuid),
  core.set_reminder_opt_out(uuid, boolean)
to dentpilot_agent;

-- confirm_attendance / set_reminder_opt_out run as the caller:
grant update (opted_out_at) on core.patients to dentpilot_agent;

-- -----------------------------------------------------------------------------
-- 3. authenticated (staff app)
-- -----------------------------------------------------------------------------
grant select on ops.staff_notifications to authenticated;
grant select, delete on ops.push_subscriptions to authenticated;

grant execute on function
  ops.register_push_subscription(text, text, text, text),
  ops.mark_notifications_read(uuid[]),
  core.appointment_message_details(uuid),
  core.confirm_attendance(uuid, uuid),
  core.set_reminder_opt_out(uuid, boolean)
to authenticated;

-- -----------------------------------------------------------------------------
-- 4. service_role (cron, operator tooling) and PUBLIC
-- -----------------------------------------------------------------------------
grant select, insert, update, delete on all tables    in schema core, ops to service_role;
grant execute                        on all functions in schema core, ops to service_role;

revoke execute on all functions in schema core, clinical, ops from public;
