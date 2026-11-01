-- =============================================================================
-- Stage 2 · Migration 3 of 4 — Booking functions
--
-- The assistant books ONLY through these functions. They run as SECURITY
-- INVOKER, so RLS still limits them to the clinic in app.clinic_id.
--
--   slot_is_free          one dentist, one time range: free?
--   available_slots       free start times for a service on a local date
--   available_dates       dates that have at least one free slot (Flow "dates" screen)
--   hold_slot             reserve a slot for a few minutes (Flow "hold" step)
--   confirm_hold          turn a hold into an appointment; idempotent (Flow "complete")
--   cancel_appointment    patient or staff cancels
--   approve_appointment   staff only: pending_approval → booked
--   reject_appointment    staff only: pending_approval → rejected
--
-- Reschedule = hold_slot(..., p_replacing_appointment) then confirm_hold:
-- the old appointment is cancelled and the new one created in one transaction.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- slot_is_free
-- Free = no active appointment, no live hold, no dentist block and no
-- clinic-wide block overlapping [p_start, p_blocked_until).
-- p_ignore_appointment lets a reschedule overlap the appointment it replaces.
-- -----------------------------------------------------------------------------
create or replace function core.slot_is_free(
  p_professional_id     uuid,
  p_start               timestamptz,
  p_blocked_until       timestamptz,
  p_ignore_appointment  uuid default null
)
returns boolean
language sql
stable
security invoker
set search_path = core, pg_temp
as $$
  select
        not exists (
          select 1 from appointments a
           where a.professional_id = p_professional_id
             and is_active_status(a.status)
             and a.id is distinct from p_ignore_appointment
             and tstzrange(a.start_at, a.blocked_until, '[)') && tstzrange(p_start, p_blocked_until, '[)'))
    and not exists (
          select 1 from slot_holds h
           where h.professional_id = p_professional_id
             and h.expires_at > now()
             and tstzrange(h.start_at, h.blocked_until, '[)') && tstzrange(p_start, p_blocked_until, '[)'))
    and not exists (
          select 1 from blocks b
           where b.clinic_id = current_clinic_id()
             and (b.professional_id = p_professional_id or b.professional_id is null)
             and tstzrange(b.start_at, b.end_at, '[)') && tstzrange(p_start, p_blocked_until, '[)'))
$$;

-- -----------------------------------------------------------------------------
-- available_slots
-- Start times step through each working window on the clinic grid
-- (slot_step_minutes), counted from the window's start. A slot is offered
-- only if the whole service + buffer fits inside the window, it respects the
-- minimum notice and horizon, and slot_is_free() says yes.
-- p_professional_id null = any dentist.
-- -----------------------------------------------------------------------------
create or replace function core.available_slots(
  p_service_id          uuid,
  p_local_date          date,
  p_professional_id     uuid default null,
  p_ignore_appointment  uuid default null
)
returns table (professional_id uuid, start_at timestamptz, end_at timestamptz)
language sql
stable
security invoker
set search_path = core, pg_temp
as $$
  with clinic as (
    select c.timezone,
           make_interval(mins => c.slot_step_minutes)  as step,
           now() + make_interval(mins => c.min_notice_minutes) as earliest,
           (now() at time zone c.timezone)::date + c.booking_horizon_days as last_day
      from clinics c
     where c.id = current_clinic_id()
  ),
  service as (
    select make_interval(mins => s.duration_minutes)                    as chair_time,
           make_interval(mins => s.duration_minutes + s.buffer_minutes) as blocked_time
      from services s
     where s.id = p_service_id and s.active
  ),
  windows as (
    select sc.professional_id,
           (p_local_date + sc.start_time) at time zone clinic.timezone as window_start,
           (p_local_date + sc.end_time)   at time zone clinic.timezone as window_end
      from schedules sc
      join professionals p on p.id = sc.professional_id and p.active
     cross join clinic
     where sc.weekday = extract(isodow from p_local_date)
       and p_local_date between sc.valid_from and coalesce(sc.valid_to, 'infinity'::date)
       and p_local_date <= clinic.last_day
       and (p_professional_id is null or sc.professional_id = p_professional_id)
  ),
  candidates as (
    select w.professional_id,
           g                      as start_at,
           g + service.chair_time   as end_at,
           g + service.blocked_time as blocked_until
      from windows w
     cross join service
     cross join clinic
     cross join lateral generate_series(w.window_start, w.window_end - service.blocked_time, clinic.step) as g
  )
  select c.professional_id, c.start_at, c.end_at
    from candidates c
   cross join clinic
   where c.start_at >= clinic.earliest
     and slot_is_free(c.professional_id, c.start_at, c.blocked_until, p_ignore_appointment)
   order by c.start_at, c.professional_id
$$;

-- -----------------------------------------------------------------------------
-- available_dates — local dates with at least one free slot, soonest first.
-- -----------------------------------------------------------------------------
create or replace function core.available_dates(
  p_service_id       uuid,
  p_professional_id  uuid default null,
  p_from             date default null,     -- default: today, clinic local time
  p_max_dates        int  default 10
)
returns table (local_date date, free_slots int)
language sql
stable
security invoker
set search_path = core, pg_temp
as $$
  with clinic as (
    select (now() at time zone c.timezone)::date as today, c.booking_horizon_days
      from clinics c
     where c.id = current_clinic_id()
  )
  select d::date, count(*)::int
    from clinic
   cross join lateral generate_series(coalesce(p_from, clinic.today),
                                      clinic.today + clinic.booking_horizon_days,
                                      interval '1 day') as d
   cross join lateral available_slots(p_service_id, d::date, p_professional_id) s
   group by d
   order by d
   limit p_max_dates
$$;

-- -----------------------------------------------------------------------------
-- hold_slot — reserve p_start for this patient. Returns the hold id, or null
-- if the slot is no longer free (show the patient fresh slots).
-- With "any dentist" it tries each free dentist in turn.
-- A patient holds at most one slot: a new hold replaces their previous one.
-- -----------------------------------------------------------------------------
create or replace function core.hold_slot(
  p_patient_id             uuid,
  p_service_id             uuid,
  p_start                  timestamptz,
  p_professional_id        uuid default null,
  p_replacing_appointment  uuid default null
)
returns uuid
language plpgsql
volatile
security invoker
set search_path = core, pg_temp
as $$
declare
  v_clinic            clinics%rowtype;
  v_service           services%rowtype;
  v_replacing_version int;
  v_professional_id   uuid;
  v_hold_id           uuid;
begin
  select * into v_clinic from clinics where id = current_clinic_id();
  if not found then
    raise exception 'no clinic context: set app.clinic_id first' using errcode = 'insufficient_privilege';
  end if;

  select * into v_service from services where id = p_service_id and active;
  if not found then
    raise exception 'unknown or inactive service %', p_service_id using errcode = 'no_data_found';
  end if;
  if not v_service.bookable_by_patient then
    raise exception 'service % is staff-booked only', v_service.code using errcode = 'insufficient_privilege';
  end if;

  if p_replacing_appointment is not null then
    select version into v_replacing_version
      from appointments
     where id = p_replacing_appointment
       and patient_id = p_patient_id
       and is_active_status(status);
    if not found then
      raise exception 'appointment % is not an active appointment of this patient', p_replacing_appointment
        using errcode = 'no_data_found';
    end if;
  end if;

  delete from slot_holds where patient_id = p_patient_id;

  for v_professional_id in
    select s.professional_id
      from available_slots(p_service_id,
                           (p_start at time zone v_clinic.timezone)::date,
                           p_professional_id,
                           p_replacing_appointment) s
     where s.start_at = p_start
  loop
    -- One booking decision per dentist at a time: check-then-insert is race-free.
    perform pg_advisory_xact_lock(hashtextextended(v_professional_id::text, 0));
    delete from slot_holds where professional_id = v_professional_id and expires_at <= now();

    if slot_is_free(v_professional_id,
                    p_start,
                    p_start + make_interval(mins => v_service.duration_minutes + v_service.buffer_minutes),
                    p_replacing_appointment) then
      insert into slot_holds (clinic_id, patient_id, professional_id, service_id,
                              start_at, end_at, blocked_until, expires_at,
                              replacing_appointment_id, replacing_version)
      values (v_clinic.id, p_patient_id, v_professional_id, p_service_id,
              p_start,
              p_start + make_interval(mins => v_service.duration_minutes),
              p_start + make_interval(mins => v_service.duration_minutes + v_service.buffer_minutes),
              now() + make_interval(mins => v_clinic.hold_minutes),
              p_replacing_appointment, v_replacing_version)
      returning id into v_hold_id;
      return v_hold_id;
    end if;
  end loop;

  return null;
end
$$;

-- -----------------------------------------------------------------------------
-- confirm_hold — create the appointment from a live hold.
-- Status is pending_approval when the service requires approval, else booked.
-- Idempotent: confirming the same hold again returns the same appointment
-- (the Flow's completion webhook can be delivered more than once).
-- Returns no row if the hold expired — re-offer slots.
-- -----------------------------------------------------------------------------
create or replace function core.confirm_hold(
  p_hold_id       uuid,
  p_patient_id    uuid,
  p_display_name  text default null
)
returns table (appointment_id uuid, status text)
language plpgsql
volatile
security invoker
set search_path = core, pg_temp
as $$
declare
  v_hold      slot_holds%rowtype;
  v_approval  boolean;
  v_appt_id   uuid;
  v_status    text;
begin
  -- Replay of a confirmation that already succeeded.
  return query
    select a.id, a.status from appointments a
     where a.source_hold_id = p_hold_id and a.patient_id = p_patient_id;
  if found then
    return;
  end if;

  select * into v_hold
    from slot_holds
   where id = p_hold_id and patient_id = p_patient_id and expires_at > now()
     for update;
  if not found then
    return;   -- expired or unknown
  end if;

  -- Reschedule: cancel the old appointment, but only if nobody changed it since.
  if v_hold.replacing_appointment_id is not null then
    update appointments
       set status = 'cancelled', cancel_reason = 'rescheduled'
     where id = v_hold.replacing_appointment_id
       and version = v_hold.replacing_version
       and is_active_status(appointments.status);
    if not found then
      raise exception 'appointment % changed since the reschedule started', v_hold.replacing_appointment_id
        using errcode = 'serialization_failure';
    end if;
  end if;

  select requires_approval into v_approval from services where id = v_hold.service_id;
  v_status := case when v_approval then 'pending_approval' else 'booked' end;

  insert into appointments (clinic_id, patient_id, professional_id, service_id,
                            start_at, end_at, blocked_until, status, booked_by,
                            source_hold_id, rescheduled_from)
  values (v_hold.clinic_id, v_hold.patient_id, v_hold.professional_id, v_hold.service_id,
          v_hold.start_at, v_hold.end_at, v_hold.blocked_until, v_status,
          case when current_setting('app.actor', true) = 'assistant' then 'assistant' else 'staff' end,
          v_hold.id, v_hold.replacing_appointment_id)
  returning id into v_appt_id;

  delete from slot_holds where id = v_hold.id;

  if nullif(btrim(p_display_name), '') is not null then
    update patients
       set display_name = btrim(p_display_name)
     where id = v_hold.patient_id
       and display_name is distinct from btrim(p_display_name);
  end if;

  appointment_id := v_appt_id;
  status         := v_status;
  return next;
end
$$;

-- -----------------------------------------------------------------------------
-- cancel_appointment — true if cancelled; false if it was already changed
-- (stale version), is not this patient's, or is no longer active.
-- -----------------------------------------------------------------------------
create or replace function core.cancel_appointment(
  p_appointment_id    uuid,
  p_patient_id        uuid,
  p_expected_version  int,
  p_reason            text default null
)
returns boolean
language plpgsql
volatile
security invoker
set search_path = core, pg_temp
as $$
begin
  update appointments
     set status = 'cancelled', cancel_reason = p_reason
   where id = p_appointment_id
     and patient_id = p_patient_id
     and version = p_expected_version
     and status in ('pending_approval', 'booked', 'confirmed');
  return found;
end
$$;

-- -----------------------------------------------------------------------------
-- approve_appointment / reject_appointment — staff only (see grants).
-- -----------------------------------------------------------------------------
create or replace function core.approve_appointment(
  p_appointment_id    uuid,
  p_expected_version  int
)
returns boolean
language plpgsql
volatile
security invoker
set search_path = core, pg_temp
as $$
begin
  update appointments
     set status = 'booked'
   where id = p_appointment_id
     and version = p_expected_version
     and status = 'pending_approval';
  return found;
end
$$;

create or replace function core.reject_appointment(
  p_appointment_id    uuid,
  p_expected_version  int,
  p_reason            text default null
)
returns boolean
language plpgsql
volatile
security invoker
set search_path = core, pg_temp
as $$
begin
  update appointments
     set status = 'rejected', cancel_reason = p_reason
   where id = p_appointment_id
     and version = p_expected_version
     and status = 'pending_approval';
  return found;
end
$$;
