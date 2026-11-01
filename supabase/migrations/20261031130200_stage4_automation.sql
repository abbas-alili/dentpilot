-- =============================================================================
-- Stage 4 · Migration 3 of 5 — Automation
-- Triggers turn business events into jobs and staff notifications, so no
-- Edge Function has to remember to do it:
--
--   appointment booked/confirmed      → reminder jobs (one per clinic offset)
--   appointment moved or ended        → stale reminder jobs cancelled
--   booking pending approval          → staff notified + approval reminder job
--   pending booking approved/rejected → approval reminder cancelled,
--                                       patient told (notify_patient job)
--   conversation escalated/handed over → staff notified
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 1. Reminder jobs for one appointment
--    Key includes the start time, so moving an appointment creates new
--    reminders and the old ones are cancelled. Offsets whose time has already
--    passed (booked late) are skipped.
-- -----------------------------------------------------------------------------
create or replace function ops.reminder_key_prefix(p_appointment_id uuid, p_start_at timestamptz)
returns text
language sql
immutable
as $$
  select 'reminder:' || p_appointment_id || ':' || extract(epoch from p_start_at)::bigint || ':'
$$;

create or replace function ops.sync_reminders(p_appointment_id uuid)
returns void
language plpgsql
volatile
security definer
set search_path = ops, core, pg_temp
as $$
declare
  v_appt    core.appointments%rowtype;
  v_offsets int[];
  v_offset  int;
  v_prefix  text;
begin
  select * into v_appt from core.appointments where id = p_appointment_id;
  v_prefix := reminder_key_prefix(v_appt.id, v_appt.start_at);

  if v_appt.status not in ('booked', 'confirmed') then
    perform cancel_appointment_jobs(v_appt.id, array['send_reminder']);
    return;
  end if;

  -- Drop reminders made for an earlier start time.
  perform cancel_appointment_jobs(v_appt.id, array['send_reminder'], v_prefix || '%');

  select reminder_offsets_minutes into v_offsets from core.clinics where id = v_appt.clinic_id;
  foreach v_offset in array v_offsets loop
    if v_appt.start_at - make_interval(mins => v_offset) > now() then
      perform enqueue_job('send_reminder', v_appt.clinic_id,
                          jsonb_build_object('appointment_id', v_appt.id, 'offset_minutes', v_offset),
                          v_prefix || v_offset,
                          v_appt.start_at - make_interval(mins => v_offset));
    end if;
  end loop;
end
$$;

-- -----------------------------------------------------------------------------
-- 2. Appointment events
-- -----------------------------------------------------------------------------
create or replace function ops.on_appointment_change()
returns trigger
language plpgsql
security definer
set search_path = ops, core, pg_temp
as $$
declare
  v_status_changed boolean := tg_op = 'INSERT' or new.status is distinct from old.status;
  v_moved          boolean := tg_op = 'UPDATE' and new.start_at is distinct from old.start_at;
  v_after_minutes  int;
begin
  -- Reminders follow status and start time.
  if v_status_changed or v_moved then
    perform sync_reminders(new.id);
  end if;

  -- New pending booking: tell staff now, remind them later if still pending.
  if new.status = 'pending_approval' and v_status_changed then
    perform notify_staff(new.clinic_id, 'pending_approval', 'pending:' || new.id,
                         p_appointment_id => new.id);

    select approval_reminder_minutes into v_after_minutes from clinics where id = new.clinic_id;
    if v_after_minutes > 0 then
      perform enqueue_job('approval_reminder', new.clinic_id,
                          jsonb_build_object('appointment_id', new.id),
                          'approval_reminder:' || new.id,
                          now() + make_interval(mins => v_after_minutes));
    end if;
  end if;

  -- Decision on a pending booking.
  if tg_op = 'UPDATE' and old.status = 'pending_approval' and new.status <> 'pending_approval' then
    perform cancel_appointment_jobs(new.id, array['approval_reminder']);

    if new.status in ('booked', 'rejected') then
      perform enqueue_job('notify_patient', new.clinic_id,
                          jsonb_build_object('appointment_id', new.id,
                                             'event', case new.status when 'booked' then 'approved' else 'rejected' end),
                          'notify:' || new.id || ':' || new.status);
    end if;
  end if;

  return null;
end
$$;

create trigger automation after insert or update of status, start_at on core.appointments
  for each row execute function ops.on_appointment_change();

-- -----------------------------------------------------------------------------
-- 3. Conversation events
-- -----------------------------------------------------------------------------
create or replace function ops.on_conversation_change()
returns trigger
language plpgsql
security definer
set search_path = ops, core, pg_temp
as $$
begin
  if new.status in ('escalated', 'handed_to_staff') and new.status is distinct from old.status then
    perform notify_staff(new.clinic_id,
                         case new.status when 'escalated' then 'escalation' else 'handover' end,
                         new.status || ':' || new.id || ':' || new.version,
                         p_detail          => new.status_reason,
                         p_conversation_id => new.id);
  end if;
  return null;
end
$$;

create trigger automation after update of status on core.conversations
  for each row execute function ops.on_conversation_change();

-- -----------------------------------------------------------------------------
-- 4. Approval reminder job handler (pure database work)
--    Returns true if staff were reminded, false if the booking is no longer
--    pending (nothing to do). Pending bookings never expire.
-- -----------------------------------------------------------------------------
create or replace function ops.run_approval_reminder(p_job_id uuid)
returns boolean
language plpgsql
volatile
security definer
set search_path = ops, core, pg_temp
as $$
declare
  v_appt core.appointments%rowtype;
begin
  select a.* into v_appt
    from background_jobs j
    join core.appointments a on a.id = (j.payload ->> 'appointment_id')::uuid
   where j.id = p_job_id and j.kind = 'approval_reminder';

  if not found or v_appt.status <> 'pending_approval' then
    return false;
  end if;

  perform notify_staff(v_appt.clinic_id, 'approval_reminder', 'approval_reminder:' || v_appt.id,
                       p_appointment_id => v_appt.id);
  return true;
end
$$;

-- -----------------------------------------------------------------------------
-- 5. Reconciler: inbound messages the pipeline never finished
-- -----------------------------------------------------------------------------
create or replace function ops.enqueue_stale_messages(
  p_min_age       interval default '1 minute',
  p_max_attempts  int      default 5
)
returns int
language plpgsql
volatile
security definer
set search_path = ops, core, pg_temp
as $$
declare
  v_message record;
  v_count   int := 0;
begin
  for v_message in
    select m.id, m.clinic_id
      from core.messages m
     where m.direction = 'in'
       and m.processed_at is null
       and m.process_attempts < p_max_attempts
       and m.created_at < now() - p_min_age
       and not exists (select 1 from background_jobs j where j.idempotency_key = 'process:' || m.id)
     order by m.created_at
     limit 200
  loop
    perform enqueue_job('process_message', v_message.clinic_id,
                        jsonb_build_object('message_id', v_message.id),
                        'process:' || v_message.id);
    v_count := v_count + 1;
  end loop;
  return v_count;
end
$$;

-- -----------------------------------------------------------------------------
-- 6. Patient-facing helpers (assistant role, inside app.clinic_id)
-- -----------------------------------------------------------------------------

-- Everything a reminder or approval/rejection message needs. should_send is
-- false (with a reason) if the appointment is no longer active or the patient
-- opted out of reminders; the worker then completes the job without sending.
create or replace function core.appointment_message_details(p_appointment_id uuid)
returns table (
  appointment_id     uuid,
  patient_id         uuid,
  wa_id              text,
  language           text,
  patient_name       text,
  service_name       text,
  professional_name  text,
  local_start        timestamp,
  status             text,
  version            int,
  ask_confirmation   boolean,
  opted_out          boolean,
  window_open        boolean
)
language sql
stable
security invoker
set search_path = core, pg_temp
as $$
  select a.id, p.id, p.wa_id, p.preferred_language, p.display_name,
         case p.preferred_language when 'ru' then s.name_ru else s.name_az end,
         pr.display_name,
         a.start_at at time zone c.timezone,
         a.status, a.version,
         c.reminder_ask_confirmation,
         p.opted_out_at is not null,
         service_window_open(p.id)
    from appointments a
    join patients      p  on p.id  = a.patient_id
    join services      s  on s.id  = a.service_id
    join professionals pr on pr.id = a.professional_id
    join clinics       c  on c.id  = a.clinic_id
   where a.id = p_appointment_id
$$;

-- Patient taps "I'll come" on a reminder.
create or replace function core.confirm_attendance(p_appointment_id uuid, p_patient_id uuid)
returns boolean
language plpgsql
volatile
security invoker
set search_path = core, pg_temp
as $$
begin
  update appointments
     set status = 'confirmed'
   where id = p_appointment_id and patient_id = p_patient_id and status = 'booked';
  return found;
end
$$;

-- Patient says "stop reminders" (or "start" again).
create or replace function core.set_reminder_opt_out(p_patient_id uuid, p_opt_out boolean)
returns boolean
language plpgsql
volatile
security invoker
set search_path = core, pg_temp
as $$
begin
  update patients
     set opted_out_at = case when p_opt_out then coalesce(opted_out_at, now()) end
   where id = p_patient_id;
  return found;
end
$$;
