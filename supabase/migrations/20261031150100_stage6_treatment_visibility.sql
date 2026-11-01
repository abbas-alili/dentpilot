-- =============================================================================
-- Stage 6 · Migration 2 of 6 — Treatment visibility for shared patients (A11 revised)
--
--   READ   admin/receptionist: whole clinic
--          dentist: every record of "their" patients, including other
--          dentists' treatments of them
--   WRITE  unchanged — a dentist writes only records where they are the
--          treating dentist; admin/receptionist write any
--
-- "Their" patient = the dentist has treated them (any treatment record) or has
-- an appointment with them (any status except cancelled/rejected).
-- =============================================================================

-- SECURITY DEFINER so the check can read treatment_records without
-- re-entering the policy on that same table (that would be infinite policy
-- recursion). The owner (postgres) has BYPASSRLS on Supabase — see SOP §5.
create or replace function clinical.is_my_patient(p_clinic_id uuid, p_patient_id uuid)
returns boolean
language sql
stable
security definer
set search_path = clinical, core, pg_temp
as $$
  with me as (select ops.my_professional_id(p_clinic_id) as professional_id)
  select me.professional_id is not null
     and (exists (select 1 from core.appointments a
                   where a.clinic_id = p_clinic_id
                     and a.patient_id = p_patient_id
                     and a.professional_id = me.professional_id
                     and a.status not in ('cancelled', 'rejected'))
          or exists (select 1 from clinical.treatment_records r
                      where r.clinic_id = p_clinic_id
                        and r.patient_id = p_patient_id
                        and r.professional_id = me.professional_id))
    from me
$$;

create or replace function clinical.can_read_treatments(p_clinic_id uuid, p_professional_id uuid, p_patient_id uuid)
returns boolean
language sql
stable
security invoker
set search_path = clinical, pg_temp
as $$
  select clinical.can_access_treatments(p_clinic_id, p_professional_id)
      or (ops.has_clinic_role(p_clinic_id, array['dentist'])
          and clinical.is_my_patient(p_clinic_id, p_patient_id))
$$;

comment on function clinical.can_access_treatments(uuid, uuid) is
  'WRITE rule: admin/receptionist any record; dentist only as the treating dentist.';
comment on function clinical.can_read_treatments(uuid, uuid, uuid) is
  'READ rule: write rule, plus a dentist may read all records of patients they treat or have booked.';

-- -----------------------------------------------------------------------------
-- Records: split the single policy into read and write policies
-- -----------------------------------------------------------------------------
drop policy staff_treatments on clinical.treatment_records;

create policy staff_read_treatments on clinical.treatment_records
  for select to authenticated
  using (clinical.can_read_treatments(clinic_id, professional_id, patient_id));

create policy staff_insert_treatments on clinical.treatment_records
  for insert to authenticated
  with check (clinical.can_access_treatments(clinic_id, professional_id));

create policy staff_update_treatments on clinical.treatment_records
  for update to authenticated
  using      (clinical.can_access_treatments(clinic_id, professional_id))
  with check (clinical.can_access_treatments(clinic_id, professional_id));

-- -----------------------------------------------------------------------------
-- Line items: read with the record; write only if the record is writable
-- -----------------------------------------------------------------------------
drop policy staff_line_items on clinical.treatment_line_items;

create policy staff_read_line_items on clinical.treatment_line_items
  for select to authenticated
  using (exists (select 1 from clinical.treatment_records r where r.id = treatment_id));

create policy staff_write_line_items on clinical.treatment_line_items
  for all to authenticated
  using      (exists (select 1 from clinical.treatment_records r
                       where r.id = treatment_id
                         and clinical.can_access_treatments(r.clinic_id, r.professional_id)))
  with check (exists (select 1 from clinical.treatment_records r
                       where r.id = treatment_id
                         and clinical.can_access_treatments(r.clinic_id, r.professional_id)));

grant execute on function
  clinical.is_my_patient(uuid, uuid),
  clinical.can_read_treatments(uuid, uuid, uuid)
to authenticated;
