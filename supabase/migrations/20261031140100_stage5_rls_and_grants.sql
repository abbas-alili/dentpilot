-- =============================================================================
-- Stage 5 · Migration 2 of 2 — Row-level security and grants for clinical
--
--   price_list            every staff member of the clinic: read, add, edit (Q10)
--   treatment_records     admin/receptionist: whole clinic
--                         dentist: only records where they are the treating dentist (Q11)
--   treatment_line_items  follow the visibility of their record
--   Nobody deletes price-list entries or treatment records (deactivate / correct).
--   dentpilot_agent, service_role, anon: nothing (no USAGE on the schema).
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 1. RLS
-- -----------------------------------------------------------------------------
alter table clinical.price_list           enable row level security;
alter table clinical.treatment_records    enable row level security;
alter table clinical.treatment_line_items enable row level security;

alter table clinical.price_list           force row level security;
alter table clinical.treatment_records    force row level security;
alter table clinical.treatment_line_items force row level security;

create policy staff_price_list on clinical.price_list
  for all to authenticated
  using      (clinic_id in (select ops.my_clinic_ids()))
  with check (clinic_id in (select ops.my_clinic_ids()));

create policy staff_treatments on clinical.treatment_records
  for all to authenticated
  using      (clinical.can_access_treatments(clinic_id, professional_id))
  with check (clinical.can_access_treatments(clinic_id, professional_id));

-- A line is visible/writable exactly when its record is (the subquery runs
-- under the caller's RLS on treatment_records).
create policy staff_line_items on clinical.treatment_line_items
  for all to authenticated
  using      (exists (select 1 from clinical.treatment_records r where r.id = treatment_id))
  with check (exists (select 1 from clinical.treatment_records r where r.id = treatment_id));

-- -----------------------------------------------------------------------------
-- 2. Grants — authenticated (staff app) only
-- -----------------------------------------------------------------------------
grant usage on schema clinical to authenticated;

grant select, insert, update on clinical.price_list to authenticated;

grant select, insert on clinical.treatment_records to authenticated;
grant update (patient_id, professional_id, appointment_id, treated_on, notes, total_override, override_reason,
              updated_at)   -- updated_at: line-item edits "touch" their record to bump its version
  on clinical.treatment_records to authenticated;

grant select, insert, delete on clinical.treatment_line_items to authenticated;
grant update (quantity, tooth) on clinical.treatment_line_items to authenticated;   -- never unit_price

grant select on clinical.treatment_totals to authenticated;

grant execute on function
  clinical.can_access_treatments(uuid, uuid),
  ops.my_professional_id(uuid)
to authenticated;


-- -----------------------------------------------------------------------------
-- 3. The wall, restated so nobody "fixes" it, and PUBLIC lock-down
-- -----------------------------------------------------------------------------
revoke all on schema clinical from dentpilot_agent, service_role, anon;
revoke all on all tables in schema clinical from dentpilot_agent, service_role, anon;

revoke execute on all functions in schema core, clinical, ops from public;
