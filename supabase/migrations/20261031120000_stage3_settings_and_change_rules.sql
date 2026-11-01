-- =============================================================================
-- Stage 3 · Migration 1 of 4 — Messaging settings and assistant change rules
--
-- Decisions (SOP.md, Stage 3):
--   Q4  Message text is erased after 180 days (clinic setting).
--   Q7  Through the assistant, patients cannot cancel or reschedule within
--       4 hours of the appointment (clinic setting). Staff are not limited.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 1. Per-clinic settings (admin-editable)
-- -----------------------------------------------------------------------------
alter table core.clinics
  add column message_retention_days         int not null default 180
    check (message_retention_days between 30 and 3650),
  add column patient_change_cutoff_minutes  int not null default 240
    check (patient_change_cutoff_minutes between 0 and 10080),
  add column echo_pause_minutes             int not null default 30
    check (echo_pause_minutes between 0 and 1440);

comment on column core.clinics.message_retention_days        is 'Message text and media ids are erased after this many days; metadata is kept.';
comment on column core.clinics.patient_change_cutoff_minutes is 'The assistant may not cancel or reschedule an appointment starting sooner than this.';
comment on column core.clinics.echo_pause_minutes            is 'After a dentist/staff reply, the assistant stays silent in that conversation for this long.';

grant update (message_retention_days, patient_change_cutoff_minutes, echo_pause_minutes)
  on core.clinics to authenticated;      -- admin_edit_settings policy limits this to admins

-- -----------------------------------------------------------------------------
-- 2. 24-hour WhatsApp service window: when did the patient last write?
--    Free-form replies are allowed only within 24h of it; otherwise templates.
-- -----------------------------------------------------------------------------
alter table core.patients
  add column last_inbound_at timestamptz;

-- -----------------------------------------------------------------------------
-- 3. What the assistant may do to an appointment
--    Enforced in a trigger so it holds for every path (cancel, reschedule,
--    direct update). Staff are not affected.
--      • The assistant may only set status to 'confirmed' or 'cancelled'.
--      • It may not cancel (which includes rescheduling away from) an
--        appointment that starts within the clinic's cutoff.
--    Error DP001 = "too late to change via the assistant"; the bot should
--    tell the patient to call the clinic.
-- -----------------------------------------------------------------------------
create or replace function core.appointments_assistant_rules()
returns trigger
language plpgsql
as $$
declare
  v_cutoff_minutes int;
begin
  if current_user <> 'dentpilot_agent' or new.status is not distinct from old.status then
    return new;
  end if;

  if new.status not in ('confirmed', 'cancelled') then
    raise exception 'the assistant may only confirm or cancel appointments (tried %)', new.status
      using errcode = 'insufficient_privilege';
  end if;

  if new.status = 'cancelled' then
    select patient_change_cutoff_minutes into v_cutoff_minutes
      from core.clinics where id = old.clinic_id;

    if old.start_at < now() + make_interval(mins => v_cutoff_minutes) then
      raise exception 'appointment % starts too soon to change via the assistant', old.id
        using errcode = 'DP001',
              hint    = 'Ask the patient to contact the clinic directly.';
    end if;
  end if;

  return new;
end
$$;

-- BEFORE triggers run in name order; "zz_" makes this run after guard_status,
-- so an invalid transition is reported as such before this rule is checked.
create trigger zz_assistant_rules before update on core.appointments
  for each row execute function core.appointments_assistant_rules();

-- -----------------------------------------------------------------------------
-- 4. Can the patient still change this appointment through the assistant?
--    For the bot's UX (offer or hide "cancel / reschedule"). The trigger above
--    is the enforcement; this is the friendly pre-check.
-- -----------------------------------------------------------------------------
create or replace function core.patient_can_change(p_appointment_id uuid)
returns boolean
language sql
stable
security invoker
set search_path = core, pg_temp
as $$
  select coalesce((
    select is_active_status(a.status)
       and a.start_at >= now() + make_interval(mins => c.patient_change_cutoff_minutes)
      from appointments a
      join clinics c on c.id = a.clinic_id
     where a.id = p_appointment_id
  ), false)
$$;
