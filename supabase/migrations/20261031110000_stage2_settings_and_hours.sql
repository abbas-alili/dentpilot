-- =============================================================================
-- Stage 2 · Migration 1 of 4 — Booking settings, working hours, time off
--
-- Decisions (SOP.md, Stage 2):
--   • Availability is per dentist. Chairs can be added later as a second
--     constraint without changing these tables.
--   • Booking start times follow a per-clinic grid (default 45 min), editable
--     by clinic admins.
--   • Some services need staff approval; that is a per-service flag.
-- =============================================================================

create extension if not exists btree_gist with schema extensions;  -- uuid "=" inside GiST exclusion constraints

-- -----------------------------------------------------------------------------
-- 1. Per-clinic booking settings (all editable by clinic admins)
-- -----------------------------------------------------------------------------
alter table core.clinics
  add column slot_step_minutes     int not null default 45
    check (slot_step_minutes between 5 and 240),
  add column min_notice_minutes    int not null default 60
    check (min_notice_minutes between 0 and 10080),
  add column booking_horizon_days  int not null default 60
    check (booking_horizon_days between 1 and 365),
  add column hold_minutes          int not null default 10
    check (hold_minutes between 2 and 30);

comment on column core.clinics.slot_step_minutes    is 'Grid for appointment start times, counted from the start of each working window.';
comment on column core.clinics.min_notice_minutes   is 'Earliest bookable start = now() + this.';
comment on column core.clinics.booking_horizon_days is 'Latest bookable day = today + this.';
comment on column core.clinics.hold_minutes         is 'How long a slot stays reserved while the patient confirms in the Flow.';

-- -----------------------------------------------------------------------------
-- 2. Per-service approval rule
-- -----------------------------------------------------------------------------
alter table core.services
  add column requires_approval boolean not null default false;

comment on column core.services.requires_approval is
  'true = bookings start as pending_approval and need staff approval; the slot is still blocked meanwhile.';

-- -----------------------------------------------------------------------------
-- 3. Staff role helper (used by policies that only admins may pass)
-- -----------------------------------------------------------------------------
create or replace function ops.has_clinic_role(p_clinic_id uuid, p_roles text[])
returns boolean
language sql
stable
security definer
set search_path = ops, pg_temp
as $$
  select exists (
    select 1 from ops.staff
     where user_id = auth.uid() and clinic_id = p_clinic_id and role = any (p_roles)
  )
$$;

-- -----------------------------------------------------------------------------
-- 3b. Tenant context for staff
--    The assistant always sets app.clinic_id. A staff member calling the booking
--    functions from the web app may not; if they belong to exactly one clinic,
--    use it. Staff in several clinics must set app.clinic_id explicitly.
--    (Replaces the Stage 1 version; behaviour for the assistant is unchanged.)
-- -----------------------------------------------------------------------------
create or replace function core.current_clinic_id()
returns uuid
language plpgsql
stable
as $$
declare
  v_clinic_id uuid := nullif(current_setting('app.clinic_id', true), '')::uuid;
begin
  if v_clinic_id is null and current_user = 'authenticated' then
    select (array_agg(c))[1] into v_clinic_id
      from ops.my_clinic_ids() as c
    having count(*) = 1;
  end if;
  return v_clinic_id;
end
$$;

-- -----------------------------------------------------------------------------
-- 4. Optimistic locking helper: every UPDATE bumps version by one.
--    Functions then write  "... where version = p_expected_version".
-- -----------------------------------------------------------------------------
create or replace function core.bump_version()
returns trigger
language plpgsql
as $$
begin
  new.version := old.version + 1;
  return new;
end
$$;

-- -----------------------------------------------------------------------------
-- 5. schedules — weekly working hours
--    weekday: ISO, 1 = Monday … 7 = Sunday.
--    Several rows per day are allowed (split shifts) but may not overlap.
--    valid_from / valid_to let a new timetable start on a date (e.g. summer hours).
-- -----------------------------------------------------------------------------
create table core.schedules (
  id               uuid        primary key default gen_random_uuid(),
  clinic_id        uuid        not null references core.clinics (id),
  professional_id  uuid        not null,
  weekday          int         not null check (weekday between 1 and 7),
  start_time       time        not null,
  end_time         time        not null,
  valid_from       date        not null default current_date,
  valid_to         date,                                   -- null = open-ended
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now(),

  foreign key (clinic_id, professional_id) references core.professionals (clinic_id, id),
  constraint schedules_time_order  check (end_time > start_time),
  constraint schedules_date_order  check (valid_to is null or valid_to >= valid_from),

  -- No two rows for the same dentist, weekday and date range may overlap in time.
  -- (Times are placed on a fixed dummy date so they can be compared as ranges.)
  constraint schedules_no_overlap exclude using gist (
    professional_id with =,
    weekday         with =,
    daterange(valid_from, valid_to, '[]')                                  with &&,
    tsrange(date '2000-01-01' + start_time, date '2000-01-01' + end_time)  with &&
  )
);

create index schedules_lookup_idx on core.schedules (professional_id, weekday);

-- -----------------------------------------------------------------------------
-- 6. blocks — one-off unavailable time
--    professional_id set   → that dentist is unavailable (leave, lunch, paper-diary entry)
--    professional_id null  → the whole clinic is closed (public holiday)
-- -----------------------------------------------------------------------------
create table core.blocks (
  id               uuid        primary key default gen_random_uuid(),
  clinic_id        uuid        not null references core.clinics (id),
  professional_id  uuid,
  start_at         timestamptz not null,
  end_at           timestamptz not null,
  reason           text,                                   -- staff-facing only
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now(),

  foreign key (clinic_id, professional_id) references core.professionals (clinic_id, id),
  constraint blocks_time_order check (end_at > start_at)
);

create index blocks_lookup_idx on core.blocks using gist (clinic_id, professional_id, tstzrange(start_at, end_at));

-- -----------------------------------------------------------------------------
-- 7. Triggers
-- -----------------------------------------------------------------------------
create trigger set_updated_at before update on core.schedules for each row execute function core.set_updated_at();
create trigger set_updated_at before update on core.blocks    for each row execute function core.set_updated_at();
create trigger audit after insert or update or delete on core.schedules for each row execute function ops.audit_row();
create trigger audit after insert or update or delete on core.blocks    for each row execute function ops.audit_row();
