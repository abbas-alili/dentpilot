-- =============================================================================
-- Stage 5 · Migration 1 of 2 — Price list and treatment log (schema clinical)
--
-- Staff only. The assistant (dentpilot_agent) and service_role have no access
-- to this schema at all — set in Stage 1 and tested in every stage since.
--
-- Decisions (SOP.md, Stage 5):
--   Q10  Every staff member may edit the price list. Prices are deactivated,
--        never deleted, so past treatments keep their history.
--   Q11  Dentists see only the treatment records where they are the treating
--        dentist. Admins and receptionists see the whole clinic.
--   Q12  A manual total requires a reason.
--
-- Money rules:
--   • A line item's unit price is COPIED from the price list when the line is
--     added and can never be edited. Later price changes don't touch history.
--   • The record total is the sum of its lines, unless a manual total is set
--     together with a reason.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 1. Helper: the signed-in staff member's professional id in a clinic
--    (null for receptionists/admins who are not bookable dentists)
-- -----------------------------------------------------------------------------
create or replace function ops.my_professional_id(p_clinic_id uuid)
returns uuid
language sql
stable
security definer
set search_path = ops, pg_temp
as $$
  select professional_id from ops.staff where user_id = auth.uid() and clinic_id = p_clinic_id
$$;

-- Can the signed-in staff member see/write treatment records of this dentist?
create or replace function clinical.can_access_treatments(p_clinic_id uuid, p_professional_id uuid)
returns boolean
language sql
stable
security invoker
set search_path = clinical, pg_temp
as $$
  select ops.has_clinic_role(p_clinic_id, array['admin', 'receptionist'])
      or (ops.has_clinic_role(p_clinic_id, array['dentist'])
          and ops.my_professional_id(p_clinic_id) = p_professional_id)
$$;

-- -----------------------------------------------------------------------------
-- 2. price_list — internal prices (never shown to patients; the assistant
--    quotes only approved price RANGES from its knowledge base)
-- -----------------------------------------------------------------------------
create table clinical.price_list (
  id          uuid          primary key default gen_random_uuid(),
  clinic_id   uuid          not null references core.clinics (id),
  code        text          not null check (code ~ '^[a-z][a-z0-9_]{1,39}$'),   -- 'filling_composite'
  name        text          not null check (btrim(name) <> ''),
  price_azn   numeric(10,2) not null check (price_azn >= 0),
  active      boolean       not null default true,
  created_at  timestamptz   not null default now(),
  updated_at  timestamptz   not null default now(),

  unique (clinic_id, code),
  unique (clinic_id, id)
);

-- -----------------------------------------------------------------------------
-- 3. treatment_records — one visit's treatment for one patient
-- -----------------------------------------------------------------------------
create table clinical.treatment_records (
  id               uuid          primary key default gen_random_uuid(),
  clinic_id        uuid          not null references core.clinics (id),
  patient_id       uuid          not null,
  professional_id  uuid          not null,                        -- treating dentist
  appointment_id   uuid,                                          -- null for walk-ins / paper-diary visits
  treated_on       date          not null,                        -- clinic local date
  notes            text,
  total_override   numeric(10,2) check (total_override >= 0),
  override_reason  text,
  created_by       uuid          references auth.users (id),      -- set by trigger, not by the client
  version          int           not null default 1,
  created_at       timestamptz   not null default now(),
  updated_at       timestamptz   not null default now(),

  unique (clinic_id, id),
  foreign key (clinic_id, patient_id)      references core.patients      (clinic_id, id),
  foreign key (clinic_id, professional_id) references core.professionals (clinic_id, id),
  foreign key (clinic_id, appointment_id)  references core.appointments  (clinic_id, id),

  -- Q12: a manual total and its reason come together, or not at all.
  constraint treatment_override_needs_reason check (
    (total_override is null and override_reason is null)
    or (total_override is not null and btrim(coalesce(override_reason, '')) <> ''))
);

create index treatment_records_patient_idx      on clinical.treatment_records (patient_id, treated_on desc);
create index treatment_records_professional_idx on clinical.treatment_records (clinic_id, professional_id, treated_on desc);

-- Linked appointment must be the same patient and dentist; record who created it.
create or replace function clinical.treatment_records_before_write()
returns trigger
language plpgsql
as $$
begin
  if tg_op = 'INSERT' then
    new.created_by := auth.uid();
  end if;

  if new.appointment_id is not null and not exists (
       select 1 from core.appointments a
        where a.id = new.appointment_id
          and a.patient_id = new.patient_id
          and a.professional_id = new.professional_id) then
    raise exception 'appointment % does not belong to this patient and dentist', new.appointment_id
      using errcode = 'foreign_key_violation';
  end if;

  return new;
end
$$;

create trigger before_write before insert or update on clinical.treatment_records
  for each row execute function clinical.treatment_records_before_write();

-- -----------------------------------------------------------------------------
-- 4. treatment_line_items — procedures done in one visit
-- -----------------------------------------------------------------------------
create table clinical.treatment_line_items (
  id             uuid          primary key default gen_random_uuid(),
  clinic_id      uuid          not null references core.clinics (id),
  treatment_id   uuid          not null,
  price_list_id  uuid          not null,
  quantity       int           not null default 1 check (quantity between 1 and 100),
  tooth          text          check (tooth ~ '^([1-4][1-8]|[5-8][1-5])$'),   -- FDI notation, optional
  unit_price     numeric(10,2) not null,                                      -- snapshot, set by trigger
  created_at     timestamptz   not null default now(),
  updated_at     timestamptz   not null default now(),

  foreign key (clinic_id, treatment_id)  references clinical.treatment_records (clinic_id, id) on delete cascade,
  foreign key (clinic_id, price_list_id) references clinical.price_list        (clinic_id, id)
);

create index treatment_line_items_treatment_idx on clinical.treatment_line_items (treatment_id);

-- Copy the current price on insert. Whatever the client sent is ignored.
create or replace function clinical.line_items_snapshot_price()
returns trigger
language plpgsql
as $$
begin
  select price_azn into new.unit_price
    from clinical.price_list
   where id = new.price_list_id and clinic_id = new.clinic_id and active;

  if new.unit_price is null then
    raise exception 'price list item % is unknown or inactive', new.price_list_id
      using errcode = 'foreign_key_violation';
  end if;
  return new;
end
$$;

create trigger snapshot_price before insert on clinical.treatment_line_items
  for each row execute function clinical.line_items_snapshot_price();

-- Editing a line counts as editing its record: bump the record's version so
-- a stale editor of the record is stopped (optimistic locking).
create or replace function clinical.line_items_touch_record()
returns trigger
language plpgsql
as $$
begin
  update clinical.treatment_records
     set updated_at = now()
   where id = coalesce(new.treatment_id, old.treatment_id);
  return null;
end
$$;

create trigger touch_record after insert or update or delete on clinical.treatment_line_items
  for each row execute function clinical.line_items_touch_record();

-- -----------------------------------------------------------------------------
-- 5. Totals (security_invoker: rows follow the caller's RLS)
-- -----------------------------------------------------------------------------
create view clinical.treatment_totals
with (security_invoker = true) as
select r.id                                                    as treatment_id,
       r.clinic_id,
       r.patient_id,
       r.professional_id,
       r.treated_on,
       coalesce(sum(li.quantity * li.unit_price), 0)::numeric(10,2) as computed_total,
       r.total_override,
       r.override_reason,
       coalesce(r.total_override, coalesce(sum(li.quantity * li.unit_price), 0))::numeric(10,2) as total
  from clinical.treatment_records r
  left join clinical.treatment_line_items li on li.treatment_id = r.id
 group by r.id;

-- -----------------------------------------------------------------------------
-- 6. Shared triggers: updated_at, version, audit
-- -----------------------------------------------------------------------------
create trigger set_updated_at before update on clinical.price_list           for each row execute function core.set_updated_at();
create trigger set_updated_at before update on clinical.treatment_records    for each row execute function core.set_updated_at();
create trigger set_updated_at before update on clinical.treatment_line_items for each row execute function core.set_updated_at();
create trigger bump_version   before update on clinical.treatment_records    for each row execute function core.bump_version();

create trigger audit after insert or update or delete on clinical.price_list           for each row execute function ops.audit_row();
create trigger audit after insert or update or delete on clinical.treatment_records    for each row execute function ops.audit_row();
create trigger audit after insert or update or delete on clinical.treatment_line_items for each row execute function ops.audit_row();
