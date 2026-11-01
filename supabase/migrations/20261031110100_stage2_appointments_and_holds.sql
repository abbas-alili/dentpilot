-- =============================================================================
-- Stage 2 · Migration 2 of 4 — Appointments and slot holds
--
-- Three times on every booking:
--   start_at       appointment starts
--   end_at         chair time ends (start + service duration) — what calendars show
--   blocked_until  dentist is free again (end + cleanup buffer) — what overlap checks use
--
-- Double-booking is impossible at the database level: an exclusion constraint
-- forbids two ACTIVE appointments for one dentist whose [start_at, blocked_until)
-- ranges overlap, no matter how the rows are written.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 1. Appointment statuses
--    ACTIVE (occupy the dentist): pending_approval, booked, confirmed, checked_in
--    FINAL:                       completed, cancelled, rejected, no_show
-- -----------------------------------------------------------------------------
create or replace function core.is_active_status(p_status text)
returns boolean
language sql
immutable
as $$
  select p_status in ('pending_approval', 'booked', 'confirmed', 'checked_in')
$$;

-- -----------------------------------------------------------------------------
-- 2. appointments
-- -----------------------------------------------------------------------------
create table core.appointments (
  id                 uuid        primary key default gen_random_uuid(),
  clinic_id          uuid        not null references core.clinics (id),
  patient_id         uuid        not null,
  professional_id    uuid        not null,
  service_id         uuid        not null,
  start_at           timestamptz not null,
  end_at             timestamptz not null,
  blocked_until      timestamptz not null,
  status             text        not null default 'booked' check (status in (
                       'pending_approval', 'booked', 'confirmed', 'checked_in',
                       'completed', 'cancelled', 'rejected', 'no_show')),
  booked_by          text        not null default 'staff' check (booked_by in ('assistant', 'staff')),
  source_hold_id     uuid        unique,            -- makes Flow confirmation idempotent
  rescheduled_from   uuid        references core.appointments (id),
  cancel_reason      text,
  status_changed_at  timestamptz not null default now(),
  version            int         not null default 1,
  created_at         timestamptz not null default now(),
  updated_at         timestamptz not null default now(),

  unique (clinic_id, id),
  foreign key (clinic_id, patient_id)      references core.patients      (clinic_id, id),
  foreign key (clinic_id, professional_id) references core.professionals (clinic_id, id),
  foreign key (clinic_id, service_id)      references core.services      (clinic_id, id),

  constraint appointments_time_order check (start_at < end_at and end_at <= blocked_until),

  constraint appointments_no_overlap exclude using gist (
    professional_id                              with =,
    tstzrange(start_at, blocked_until, '[)')     with &&
  ) where (core.is_active_status(status))
);

create index appointments_patient_idx  on core.appointments (patient_id, start_at desc);
create index appointments_calendar_idx on core.appointments (clinic_id, start_at);
create index appointments_pending_idx  on core.appointments (clinic_id, created_at) where status = 'pending_approval';

-- -----------------------------------------------------------------------------
-- 3. Allowed status changes (enforced for every writer, staff included)
-- -----------------------------------------------------------------------------
create or replace function core.appointments_guard_status()
returns trigger
language plpgsql
as $$
begin
  if new.status is distinct from old.status then
    if not (old.status, new.status) in (
      ('pending_approval', 'booked'),
      ('pending_approval', 'rejected'),
      ('pending_approval', 'cancelled'),
      ('booked',           'confirmed'),
      ('booked',           'checked_in'),
      ('booked',           'cancelled'),
      ('booked',           'no_show'),
      ('confirmed',        'checked_in'),
      ('confirmed',        'cancelled'),
      ('confirmed',        'no_show'),
      ('checked_in',       'completed')
    ) then
      raise exception 'appointment status cannot change from % to %', old.status, new.status
        using errcode = 'check_violation';
    end if;
    new.status_changed_at := now();
  end if;
  return new;
end
$$;

create trigger guard_status   before update on core.appointments for each row execute function core.appointments_guard_status();
create trigger bump_version   before update on core.appointments for each row execute function core.bump_version();
create trigger set_updated_at before update on core.appointments for each row execute function core.set_updated_at();
create trigger audit after insert or update or delete on core.appointments for each row execute function ops.audit_row();

-- -----------------------------------------------------------------------------
-- 4. slot_holds — a slot reserved for a few minutes while the patient confirms
--    Live holds may not overlap (exclusion constraint). Expired holds are
--    removed by hold_slot() before it inserts, under a per-dentist lock, so
--    no cron sweep is needed for correctness.
--    (An index "where expires_at > now()" is NOT possible: Postgres requires
--    index predicates to be immutable.)
-- -----------------------------------------------------------------------------
create table core.slot_holds (
  id                        uuid        primary key default gen_random_uuid(),
  clinic_id                 uuid        not null references core.clinics (id),
  patient_id                uuid        not null,
  professional_id           uuid        not null,
  service_id                uuid        not null,
  start_at                  timestamptz not null,
  end_at                    timestamptz not null,
  blocked_until             timestamptz not null,
  expires_at                timestamptz not null,
  -- Reschedule: the appointment this hold will replace, and the version the
  -- patient saw. If staff changed that appointment meanwhile, confirm fails.
  replacing_appointment_id  uuid,
  replacing_version         int,
  created_at                timestamptz not null default now(),

  foreign key (clinic_id, patient_id)               references core.patients      (clinic_id, id),
  foreign key (clinic_id, professional_id)          references core.professionals (clinic_id, id),
  foreign key (clinic_id, service_id)               references core.services      (clinic_id, id),
  foreign key (clinic_id, replacing_appointment_id) references core.appointments  (clinic_id, id),

  constraint slot_holds_time_order   check (start_at < end_at and end_at <= blocked_until),
  constraint slot_holds_replace_pair check ((replacing_appointment_id is null) = (replacing_version is null)),

  constraint slot_holds_no_overlap exclude using gist (
    professional_id                           with =,
    tstzrange(start_at, blocked_until, '[)')  with &&
  )
);

create index slot_holds_patient_idx on core.slot_holds (patient_id);
