-- =============================================================================
-- Stage 2 · Migration 4 of 4 — Row-level security and grants for scheduling
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 1. RLS on the new tables: one agent policy and one staff policy each
-- -----------------------------------------------------------------------------
do $$
declare
  t text;
begin
  foreach t in array array['core.schedules', 'core.blocks', 'core.appointments', 'core.slot_holds']
  loop
    execute format('alter table %s enable row level security', t);
    execute format('alter table %s force row level security', t);

    execute format(
      'create policy agent_own_clinic on %s
         for all to dentpilot_agent
         using      (clinic_id = core.current_clinic_id())
         with check (clinic_id = core.current_clinic_id())', t);

    execute format(
      'create policy staff_own_clinics on %s
         for all to authenticated
         using      (clinic_id in (select ops.my_clinic_ids()))
         with check (clinic_id in (select ops.my_clinic_ids()))', t);
  end loop;
end
$$;

-- -----------------------------------------------------------------------------
-- 2. Clinic booking settings: admins of that clinic may edit them
--    (column grant below limits WHICH columns; this policy limits WHO and WHERE)
-- -----------------------------------------------------------------------------
create policy admin_edit_settings on core.clinics
  for update to authenticated
  using      (ops.has_clinic_role(id, array['admin']))
  with check (ops.has_clinic_role(id, array['admin']));

grant update (slot_step_minutes, min_notice_minutes, booking_horizon_days, hold_minutes)
  on core.clinics to authenticated;
-- CHECK constraints run with the caller's rights: an UPDATE of core.clinics
-- re-checks clinics_timezone_valid, which calls this function.
grant execute on function core.is_valid_timezone(text) to authenticated;

-- -----------------------------------------------------------------------------
-- 3. dentpilot_agent — reads schedules; writes only what the booking
--    functions need (they run as the caller).
-- -----------------------------------------------------------------------------
grant select                          on core.schedules, core.blocks to dentpilot_agent;
grant select, insert                  on core.appointments           to dentpilot_agent;
grant update (status, cancel_reason)  on core.appointments           to dentpilot_agent;
grant update (display_name)           on core.patients               to dentpilot_agent;
-- UPDATE on slot_holds is required by SELECT ... FOR UPDATE in confirm_hold.
grant select, insert, update, delete  on core.slot_holds             to dentpilot_agent;

grant execute on function
  core.is_active_status(text),
  core.slot_is_free(uuid, timestamptz, timestamptz, uuid),
  core.available_slots(uuid, date, uuid, uuid),
  core.available_dates(uuid, uuid, date, int),
  core.hold_slot(uuid, uuid, timestamptz, uuid, uuid),
  core.confirm_hold(uuid, uuid, text),
  core.cancel_appointment(uuid, uuid, int, text)
to dentpilot_agent;
-- Deliberately NOT granted to the agent: approve_appointment, reject_appointment.

-- -----------------------------------------------------------------------------
-- 4. authenticated (staff app)
-- -----------------------------------------------------------------------------
grant select, insert, update, delete on core.schedules, core.blocks to authenticated;
grant select, insert, update         on core.appointments           to authenticated;
grant select, delete                 on core.slot_holds             to authenticated;

grant execute on function
  core.is_active_status(text),
  core.slot_is_free(uuid, timestamptz, timestamptz, uuid),
  core.available_slots(uuid, date, uuid, uuid),
  core.available_dates(uuid, uuid, date, int),
  core.hold_slot(uuid, uuid, timestamptz, uuid, uuid),
  core.confirm_hold(uuid, uuid, text),
  core.cancel_appointment(uuid, uuid, int, text),
  core.approve_appointment(uuid, int),
  core.reject_appointment(uuid, int, text),
  ops.has_clinic_role(uuid, text[])
to authenticated;

-- -----------------------------------------------------------------------------
-- 5. service_role — core + ops only (never clinical)
-- -----------------------------------------------------------------------------
grant select, insert, update, delete on all tables    in schema core, ops to service_role;
grant execute                        on all functions in schema core, ops to service_role;

-- -----------------------------------------------------------------------------
-- 6. PUBLIC — no function execution (re-run after every stage's new functions)
-- -----------------------------------------------------------------------------
revoke execute on all functions in schema core, clinical, ops from public;
