-- =============================================================================
-- Clinic answers (Dr. Ayten, 2026-11-02) — shadow mode and booking approval
--
--   Shadow mode (E6, personal number): everything the assistant or the job
--     worker would send becomes a DRAFT. Staff approve (optionally editing the
--     text) or discard it; approval queues the actual send. Staff's own
--     replies are sent directly. Clinic setting, default ON for every clinic.
--   All bookings need the doctor's approval (B10): clinic setting
--     all_bookings_need_approval, on top of the per-service flag.
--   Durations vary 15–240 min (B5): the doctor can set the real duration when
--     approving; the slot is held at the service's (shortest) duration until then.
--   Patients book a specific doctor (B4): clinic setting offer_any_dentist.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 1. Settings (admin-editable)
-- -----------------------------------------------------------------------------
alter table core.clinics
  add column shadow_mode                 boolean not null default true,
  add column all_bookings_need_approval  boolean not null default false,
  add column offer_any_dentist           boolean not null default true;

comment on column core.clinics.shadow_mode is
  'true = assistant/system messages are drafts until staff approve them. Default for new clinics.';
comment on column core.clinics.all_bookings_need_approval is
  'true = every patient booking starts as pending_approval, whatever the service flag says.';
comment on column core.clinics.offer_any_dentist is
  'false = the booking Flow has no "any dentist" option (patients book a specific doctor).';

grant update (shadow_mode, all_bookings_need_approval, offer_any_dentist) on core.clinics to authenticated;

-- -----------------------------------------------------------------------------
-- 2. Drafts on core.messages
--    draft ──approve──▶ pending ──send job──▶ sent / failed
--      └───discard──▶ discarded
-- -----------------------------------------------------------------------------
alter table core.messages drop constraint messages_delivery_status_check;
alter table core.messages add constraint messages_delivery_status_check
  check (delivery_status in ('draft', 'discarded', 'pending', 'sent', 'delivered', 'read', 'failed'));

alter table core.messages
  add column outbound_payload  jsonb,                               -- exact WhatsApp message to send
  add column reviewed_by       uuid references auth.users (id),
  add column reviewed_at       timestamptz,
  add column edited            boolean not null default false;     -- staff changed the bot's text

comment on column core.messages.outbound_payload is 'WhatsApp message object (text / interactive / template) to send after approval.';
comment on column core.messages.edited is 'Staff edited the draft before sending — a labelled example for evaluation.';

create index messages_drafts_idx on core.messages (clinic_id, created_at) where delivery_status = 'draft';

-- queue_outbound_message gains the payload and the shadow-mode decision.
-- (New signature → drop the old one; grants are re-issued in the grants migration.)
drop function core.queue_outbound_message(uuid, text, text, text, text, text);

create or replace function core.queue_outbound_message(
  p_patient_id     uuid,
  p_source         text,                 -- 'assistant' | 'staff' | 'system'
  p_kind           text,
  p_body           text  default null,
  p_template_name  text  default null,
  p_send_key       text  default null,
  p_payload        jsonb default null
)
returns table (message_id uuid, delivery_status text)
language plpgsql
volatile
security invoker
set search_path = core, pg_temp
as $$
declare
  v_clinic_id        uuid := current_clinic_id();
  v_conversation_id  uuid;
  v_status           text;
begin
  if p_source not in ('assistant', 'staff', 'system') then
    raise exception 'invalid outbound source %', p_source using errcode = 'check_violation';
  end if;

  if p_send_key is not null then
    return query
      select m.id, m.delivery_status from messages m
       where m.clinic_id = v_clinic_id and m.send_key = p_send_key;
    if found then
      return;
    end if;
  end if;

  select case when c.shadow_mode and p_source <> 'staff' then 'draft' else 'pending' end
    into v_status
    from clinics c where c.id = v_clinic_id;

  v_conversation_id := open_conversation_for(p_patient_id);

  return query
    insert into messages (clinic_id, patient_id, conversation_id, direction, source, kind,
                          body, template_name, send_key, delivery_status, outbound_payload)
    values (v_clinic_id, p_patient_id, v_conversation_id, 'out', p_source, p_kind,
            p_body, p_template_name, p_send_key, v_status, p_payload)
    returning messages.id, messages.delivery_status;

  update conversations
     set last_message_at     = now(),
         last_human_reply_at = case when p_source = 'staff' then now() else last_human_reply_at end
   where id = v_conversation_id;
end
$$;

-- Staff: approve a draft, optionally with new text (text and interactive
-- bodies only; template wording is fixed by Meta).
create or replace function core.approve_draft(p_message_id uuid, p_new_text text default null)
returns boolean
language plpgsql
volatile
security definer                       -- staff have no UPDATE on messages; membership checked below
set search_path = core, pg_temp
as $$
declare
  v_msg messages%rowtype;
  v_text text := nullif(btrim(p_new_text), '');
begin
  select * into v_msg
    from messages
   where id = p_message_id
     and delivery_status = 'draft'
     and clinic_id in (select ops.my_clinic_ids())
     for update;
  if not found then
    return false;
  end if;

  if v_text is not null and v_msg.outbound_payload ->> 'type' not in ('text', 'interactive') then
    raise exception 'template messages cannot be edited' using errcode = 'check_violation';
  end if;

  update messages
     set delivery_status  = 'pending',
         reviewed_by      = auth.uid(),
         reviewed_at      = now(),
         edited           = v_text is not null and v_text is distinct from v_msg.body,
         body             = coalesce(v_text, body),
         outbound_payload = case
           when v_text is null then outbound_payload
           when outbound_payload ->> 'type' = 'text'
             then jsonb_set(outbound_payload, '{text,body}', to_jsonb(v_text))
           else jsonb_set(outbound_payload, '{interactive,body,text}', to_jsonb(v_text))
         end
   where id = p_message_id;
  return true;
end
$$;

create or replace function core.discard_draft(p_message_id uuid)
returns boolean
language plpgsql
volatile
security definer
set search_path = core, pg_temp
as $$
begin
  update messages
     set delivery_status = 'discarded', reviewed_by = auth.uid(), reviewed_at = now()
   where id = p_message_id
     and delivery_status = 'draft'
     and clinic_id in (select ops.my_clinic_ids());
  return found;
end
$$;

-- -----------------------------------------------------------------------------
-- 3. Sending what staff released or wrote
--    An approved draft (draft → pending) or a staff-written message (inserted
--    as pending) gets a 'send_message' job; run-jobs sends it.
--    Staff are told a draft is waiting (at most one push per conversation a minute).
-- -----------------------------------------------------------------------------
alter table ops.background_jobs drop constraint background_jobs_kind_check;
alter table ops.background_jobs add constraint background_jobs_kind_check check (kind in (
  'process_message', 'send_reminder', 'notify_patient', 'approval_reminder', 'push_notification',
  'send_message',    -- send an approved draft or a staff reply
  'gcal_sync'));     -- write an appointment to the dentist's Google Calendar

alter table ops.staff_notifications drop constraint staff_notifications_kind_check;
alter table ops.staff_notifications add constraint staff_notifications_kind_check check (kind in (
  'escalation', 'handover', 'pending_approval', 'approval_reminder',
  'draft_waiting', 'calendar_disconnected'));

create or replace function ops.on_outbound_message()
returns trigger
language plpgsql
security definer
set search_path = ops, core, pg_temp
as $$
begin
  if new.direction <> 'out' then
    return null;
  end if;

  if new.delivery_status = 'pending'
     and ((tg_op = 'UPDATE' and old.delivery_status = 'draft')
          or (tg_op = 'INSERT' and new.source = 'staff')) then
    perform enqueue_job('send_message', new.clinic_id,
                        jsonb_build_object('message_id', new.id), 'send:' || new.id);
  end if;

  if tg_op = 'INSERT' and new.delivery_status = 'draft' then
    perform notify_staff(new.clinic_id, 'draft_waiting',
                         'draft:' || new.conversation_id || ':' || (extract(epoch from now()) / 60)::bigint,
                         p_conversation_id => new.conversation_id);
  end if;
  return null;
end
$$;

create trigger outbound_automation after insert or update of delivery_status on core.messages
  for each row execute function ops.on_outbound_message();

-- -----------------------------------------------------------------------------
-- 4. Bookings: clinic-wide approval rule (replaces the Stage 2 confirm_hold)
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

  select s.requires_approval or c.all_bookings_need_approval into v_approval
    from services s join clinics c on c.id = s.clinic_id
   where s.id = v_hold.service_id;
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
-- 5. Approve with the real duration (replaces the Stage 2 approve_appointment)
--    p_duration_minutes null = keep the held duration. A longer duration that
--    would overlap another booking fails with 23P01 (the staff app says so).
-- -----------------------------------------------------------------------------
drop function core.approve_appointment(uuid, int);

create or replace function core.approve_appointment(
  p_appointment_id    uuid,
  p_expected_version  int,
  p_duration_minutes  int default null
)
returns boolean
language plpgsql
volatile
security invoker
set search_path = core, pg_temp
as $$
begin
  if p_duration_minutes is not null and p_duration_minutes not between 5 and 480 then
    raise exception 'duration must be 5–480 minutes' using errcode = 'check_violation';
  end if;

  update appointments a
     set status        = 'booked',
         end_at        = case when p_duration_minutes is null then a.end_at
                              else a.start_at + make_interval(mins => p_duration_minutes) end,
         blocked_until = case when p_duration_minutes is null then a.blocked_until
                              else a.start_at + make_interval(mins => p_duration_minutes + s.buffer_minutes) end
    from services s
   where a.id = p_appointment_id
     and s.id = a.service_id
     and a.version = p_expected_version
     and a.status = 'pending_approval';
  return found;
end
$$;
