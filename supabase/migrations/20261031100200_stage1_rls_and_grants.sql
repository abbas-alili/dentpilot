-- =============================================================================
-- Stage 1 · Migration 3 of 3 — Row-level security and grants
--
-- Two kinds of caller reach these tables:
--   dentpilot_agent   the assistant. Sees one clinic: the one in app.clinic_id.
--   authenticated     signed-in staff (Supabase Auth). Sees the clinics listed
--                     for them in ops.staff.
-- service_role (ops code) bypasses RLS and is granted core + ops only.
-- anon gets nothing.
--
-- RLS is ENABLED on every table. On core tables it is also FORCED, so even the
-- table owner is filtered. The two ops tables are not forced: they are read and
-- written by SECURITY DEFINER functions (ops.my_clinic_ids, ops.audit_row) that
-- run as the owner, and forcing RLS there would silently empty staff lookups and
-- block audit writes.
-- Granting a table does not open it: a row is visible only if a policy for that
-- role matches it.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 1. Turn on RLS
-- -----------------------------------------------------------------------------
alter table core.clinics       enable row level security;
alter table core.professionals enable row level security;
alter table core.services      enable row level security;
alter table core.patients      enable row level security;
alter table ops.staff          enable row level security;
alter table ops.audit_events   enable row level security;

alter table core.clinics       force row level security;
alter table core.professionals force row level security;
alter table core.services      force row level security;
alter table core.patients      force row level security;

-- -----------------------------------------------------------------------------
-- 2. Policies
-- -----------------------------------------------------------------------------

-- clinics: the tenant row itself is keyed by id, not clinic_id.
create policy agent_own_clinic on core.clinics
  for select to dentpilot_agent
  using (id = core.current_clinic_id());

create policy staff_own_clinics on core.clinics
  for select to authenticated
  using (id in (select ops.my_clinic_ids()));

-- Every other tenant table: one agent policy and one staff policy each.
do $$
declare
  t text;
begin
  foreach t in array array['core.professionals', 'core.services', 'core.patients']
  loop
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

-- ops.staff: a staff member may read their own memberships. Changes to staff
-- are made by an admin through service_role during the pilot.
create policy staff_read_self on ops.staff
  for select to authenticated
  using (user_id = auth.uid());

-- ops.audit_events: staff may read their clinics' history. Nobody writes
-- directly; rows arrive only through the ops.audit_row() trigger.
create policy staff_read_audit on ops.audit_events
  for select to authenticated
  using (clinic_id in (select ops.my_clinic_ids()));

-- -----------------------------------------------------------------------------
-- 3. Grants — dentpilot_agent
--    Reference data: read only. Patients: read, create, update. No deletes.
-- -----------------------------------------------------------------------------
grant usage on schema core to dentpilot_agent;

grant select                 on core.clinics, core.professionals, core.services to dentpilot_agent;
grant select, insert, update on core.patients                                 to dentpilot_agent;

grant execute on function core.current_clinic_id() to dentpilot_agent;

-- Explicitly none on clinical. (Already the default; stated so nobody "fixes" it.)
revoke all on schema clinical from dentpilot_agent;

-- -----------------------------------------------------------------------------
-- 4. Grants — authenticated (staff app)
-- -----------------------------------------------------------------------------
grant usage on schema core, ops to authenticated;

grant select                 on core.clinics                                    to authenticated;
grant select, insert, update on core.professionals, core.services, core.patients to authenticated;
grant select                 on ops.staff, ops.audit_events                     to authenticated;

grant execute on function core.current_clinic_id(), ops.my_clinic_ids() to authenticated;

-- -----------------------------------------------------------------------------
-- 5. Grants — service_role (onboarding, webhook ingress, cron sweeps)
--    service_role bypasses RLS but, on Supabase, is not a superuser: it still
--    needs grants. It gets core and ops, and deliberately NOTHING on clinical,
--    so a bug in ops code cannot read treatment or price data either.
-- -----------------------------------------------------------------------------
grant usage on schema core, ops to service_role;
grant select, insert, update, delete on all tables in schema core, ops to service_role;
grant execute on all functions in schema core, ops to service_role;

-- -----------------------------------------------------------------------------
-- 6. anon — nothing; PUBLIC — no function execution
--    Run at the end of every grants migration, after all functions exist.
-- -----------------------------------------------------------------------------
revoke all on schema core, clinical, ops from anon;
revoke execute on all functions in schema core, clinical, ops from public;
