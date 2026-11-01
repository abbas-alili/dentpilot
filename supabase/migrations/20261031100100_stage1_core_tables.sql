-- =============================================================================
-- Stage 1 · Migration 2 of 3 — Tenant and reference tables
-- clinics · professionals · services · patients · ops.staff
--
-- Conventions used in every DentPilot table:
--   • uuid primary keys (never sequential ids in anything patient-facing)
--   • clinic_id on every tenant row
--   • composite foreign keys (clinic_id, x_id) so a row can never point at
--     another clinic's data, even from privileged code
--   • CHECK constraints on every status/enum-like column
--   • created_at / updated_at as timestamptz
-- =============================================================================

-- -----------------------------------------------------------------------------
-- clinics — one row per tenant
-- -----------------------------------------------------------------------------
create or replace function core.is_valid_timezone(tz text)
returns boolean
language plpgsql
stable
as $$
begin
  perform now() at time zone tz;
  return true;
exception
  when invalid_parameter_value then
    return false;
end
$$;

create table core.clinics (
  id                  uuid        primary key default gen_random_uuid(),
  name                text        not null check (btrim(name) <> ''),
  timezone            text        not null default 'Asia/Baku',
  -- WhatsApp routing: an inbound webhook names the phone number it arrived on;
  -- this is how we find the clinic. Credentials are NOT stored here.
  wa_phone_number_id  text        unique,
  waba_id             text,
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now(),

  constraint clinics_timezone_valid check (core.is_valid_timezone(timezone))
);

comment on table  core.clinics is 'Tenants. One row per clinic.';
comment on column core.clinics.wa_phone_number_id is 'Meta phone_number_id; resolves inbound webhooks to a clinic.';

-- -----------------------------------------------------------------------------
-- professionals — dentists who can be booked
-- -----------------------------------------------------------------------------
create table core.professionals (
  id            uuid        primary key default gen_random_uuid(),
  clinic_id     uuid        not null references core.clinics (id),
  display_name  text        not null check (btrim(display_name) <> ''),  -- as patients see it: 'Dr. Elvin'
  active        boolean     not null default true,
  sort_order    int         not null default 0,                           -- order in the booking Flow
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),

  unique (clinic_id, id)    -- target for composite foreign keys
);

create index professionals_clinic_idx on core.professionals (clinic_id) where active;

-- -----------------------------------------------------------------------------
-- services — bookable appointment types
-- duration = chair time; buffer = cleanup after. Both in minutes.
-- -----------------------------------------------------------------------------
create table core.services (
  id                   uuid        primary key default gen_random_uuid(),
  clinic_id            uuid        not null references core.clinics (id),
  code                 text        not null check (code ~ '^[a-z][a-z0-9_]{1,39}$'),  -- 'svc_exam', used in Flows
  name_az              text        not null check (btrim(name_az) <> ''),
  name_ru              text        not null check (btrim(name_ru) <> ''),
  duration_minutes     int         not null check (duration_minutes between 5 and 480),
  buffer_minutes       int         not null default 0 check (buffer_minutes between 0 and 120),
  bookable_by_patient  boolean     not null default true,   -- false = staff-only booking
  active               boolean     not null default true,
  sort_order           int         not null default 0,
  created_at           timestamptz not null default now(),
  updated_at           timestamptz not null default now(),

  unique (clinic_id, code),
  unique (clinic_id, id)
);

-- -----------------------------------------------------------------------------
-- patients — one row per WhatsApp user per clinic
-- -----------------------------------------------------------------------------
create table core.patients (
  id                  uuid        primary key default gen_random_uuid(),
  clinic_id           uuid        not null references core.clinics (id),
  wa_id               text        not null check (wa_id ~ '^[0-9]{6,20}$'),   -- Meta user id (digits)
  display_name        text,                                                    -- as given by the patient
  preferred_language  text        not null default 'az' check (preferred_language in ('az', 'ru', 'en')),
  opted_out_at        timestamptz,                                             -- reminders "stop"; null = subscribed
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now(),

  unique (clinic_id, wa_id),
  unique (clinic_id, id)
);

comment on column core.patients.opted_out_at is 'Set when the patient opts out of reminders. Null = reminders allowed.';

-- -----------------------------------------------------------------------------
-- ops.staff — which Supabase Auth users work at which clinic
-- -----------------------------------------------------------------------------
create table ops.staff (
  user_id          uuid        not null references auth.users (id) on delete cascade,
  clinic_id        uuid        not null references core.clinics (id),
  role             text        not null check (role in ('dentist', 'receptionist', 'admin')),
  professional_id  uuid,                                  -- set when this user is a bookable dentist
  created_at       timestamptz not null default now(),

  primary key (user_id, clinic_id),
  foreign key (clinic_id, professional_id) references core.professionals (clinic_id, id),
  constraint staff_dentist_has_professional
    check (role <> 'dentist' or professional_id is not null)
);

-- Clinics the signed-in staff member belongs to. SECURITY DEFINER so RLS
-- policies can call it without needing (or recursing into) access to ops.staff.
create or replace function ops.my_clinic_ids()
returns setof uuid
language sql
stable
security definer
set search_path = ops, pg_temp
as $$
  select clinic_id from ops.staff where user_id = auth.uid()
$$;

-- -----------------------------------------------------------------------------
-- Triggers: updated_at + audit
-- -----------------------------------------------------------------------------
do $$
declare
  t text;
begin
  foreach t in array array['core.clinics', 'core.professionals', 'core.services', 'core.patients']
  loop
    execute format(
      'create trigger set_updated_at before update on %s
         for each row execute function core.set_updated_at()', t);
    execute format(
      'create trigger audit after insert or update or delete on %s
         for each row execute function ops.audit_row()', t);
  end loop;
end
$$;

create trigger audit after insert or update or delete on ops.staff
  for each row execute function ops.audit_row();
