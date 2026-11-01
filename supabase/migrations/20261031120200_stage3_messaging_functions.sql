-- =============================================================================
-- Stage 3 · Migration 3 of 4 — Messaging functions
--
-- Tenant resolvers (SECURITY DEFINER, return only a clinic id):
--   clinic_for_phone_number   webhook → which clinic?
--   clinic_for_flow_token     Flow endpoint → which clinic?
-- Everything else is SECURITY INVOKER and runs inside app.clinic_id.
--
-- Webhook (whatsapp-webhook, as dentpilot_agent):
--   1. clinic_id := clinic_for_phone_number(metadata.phone_number_id)
--   2. set app.clinic_id, app.actor = 'assistant'
--   3. messages        → record_inbound_message(...)
--      echoes          → record_echo_message(...)
--      statuses        → update_delivery_status(...)
--   4. return 200; invoke process-message for new inbound ids
--
-- Assistant (process-message):
--   assistant_may_reply → (emergency gate) → … → queue_outbound_message →
--   send via Cloud API → mark_outbound_sent / mark_outbound_failed →
--   mark_message_processed
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 1. Tenant resolvers
-- -----------------------------------------------------------------------------
create or replace function core.clinic_for_phone_number(p_phone_number_id text)
returns uuid
language sql
stable
security definer
set search_path = core, pg_temp
as $$
  select id from clinics where wa_phone_number_id = p_phone_number_id
$$;

create or replace function core.clinic_for_flow_token(p_token text)
returns uuid
language sql
stable
security definer
set search_path = core, pg_temp
as $$
  select clinic_id from flow_tokens where token = p_token and expires_at > now()
$$;

-- -----------------------------------------------------------------------------
-- 2. Open conversation for a patient (create one if none is open)
-- -----------------------------------------------------------------------------
create or replace function core.open_conversation_for(p_patient_id uuid)
returns uuid
language plpgsql
volatile
security invoker
set search_path = core, pg_temp
as $$
declare
  v_conversation_id uuid;
begin
  insert into conversations (clinic_id, patient_id)
  values (current_clinic_id(), p_patient_id)
  on conflict (patient_id) where status <> 'closed' do nothing
  returning id into v_conversation_id;

  if v_conversation_id is null then
    select id into v_conversation_id
      from conversations
     where patient_id = p_patient_id and status <> 'closed';
  end if;

  return v_conversation_id;
end
$$;

-- -----------------------------------------------------------------------------
-- 3. Inbound patient message. Idempotent on wa_message_id: a redelivered
--    webhook returns the existing row with is_duplicate = true, and the
--    caller must NOT process it again.
-- -----------------------------------------------------------------------------
create or replace function core.record_inbound_message(
  p_wa_message_id           text,
  p_wa_id                   text,
  p_kind                    text,
  p_body                    text        default null,
  p_media_id                text        default null,
  p_media_mime              text        default null,
  p_sent_at                 timestamptz default null,
  p_reply_to_wa_message_id  text        default null,
  p_profile_name            text        default null
)
returns table (message_id uuid, patient_id uuid, conversation_id uuid, is_duplicate boolean)
language plpgsql
volatile
security invoker
set search_path = core, pg_temp
as $$
declare
  v_clinic_id        uuid := current_clinic_id();
  v_received_at      timestamptz := coalesce(p_sent_at, now());
  v_patient_id       uuid;
  v_conversation_id  uuid;
  v_message_id       uuid;
begin
  if v_clinic_id is null then
    raise exception 'no clinic context: set app.clinic_id first' using errcode = 'insufficient_privilege';
  end if;

  -- Already seen?
  return query
    select m.id, m.patient_id, m.conversation_id, true
      from messages m where m.wa_message_id = p_wa_message_id;
  if found then
    return;
  end if;

  insert into patients as p (clinic_id, wa_id, display_name, last_inbound_at)
  values (v_clinic_id, p_wa_id, nullif(btrim(p_profile_name), ''), v_received_at)
  on conflict (clinic_id, wa_id) do update
     set last_inbound_at = greatest(p.last_inbound_at, excluded.last_inbound_at),
         display_name    = coalesce(p.display_name, excluded.display_name)
  returning p.id into v_patient_id;

  v_conversation_id := open_conversation_for(v_patient_id);

  insert into messages (clinic_id, patient_id, conversation_id, direction, source, kind,
                        body, media_id, media_mime, reply_to_wa_message_id, wa_message_id, sent_at)
  values (v_clinic_id, v_patient_id, v_conversation_id, 'in', 'patient', p_kind,
          p_body, p_media_id, p_media_mime, p_reply_to_wa_message_id, p_wa_message_id, v_received_at)
  on conflict (wa_message_id) do nothing
  returning id into v_message_id;

  if v_message_id is null then          -- lost a race with a concurrent delivery
    return query
      select m.id, m.patient_id, m.conversation_id, true
        from messages m where m.wa_message_id = p_wa_message_id;
    return;
  end if;

  update conversations
     set last_message_at = greatest(last_message_at, v_received_at)
   where id = v_conversation_id;

  message_id      := v_message_id;
  patient_id      := v_patient_id;
  conversation_id := v_conversation_id;
  is_duplicate    := false;
  return next;
end
$$;

-- -----------------------------------------------------------------------------
-- 4. Echo of a message the dentist sent from the WhatsApp Business App
--    (Coexistence). Recorded so the assistant knows a human is talking.
-- -----------------------------------------------------------------------------
create or replace function core.record_echo_message(
  p_wa_message_id  text,
  p_patient_wa_id  text,
  p_kind           text,
  p_body           text        default null,
  p_sent_at        timestamptz default null
)
returns uuid
language plpgsql
volatile
security invoker
set search_path = core, pg_temp
as $$
declare
  v_clinic_id        uuid := current_clinic_id();
  v_sent_at          timestamptz := coalesce(p_sent_at, now());
  v_patient_id       uuid;
  v_conversation_id  uuid;
  v_message_id       uuid;
begin
  if v_clinic_id is null then
    raise exception 'no clinic context: set app.clinic_id first' using errcode = 'insufficient_privilege';
  end if;

  select id into v_message_id from messages where wa_message_id = p_wa_message_id;
  if found then
    return v_message_id;
  end if;

  insert into patients (clinic_id, wa_id)
  values (v_clinic_id, p_patient_wa_id)
  on conflict (clinic_id, wa_id) do nothing
  returning id into v_patient_id;

  if v_patient_id is null then
    select id into v_patient_id from patients where wa_id = p_patient_wa_id;
  end if;

  v_conversation_id := open_conversation_for(v_patient_id);

  insert into messages (clinic_id, patient_id, conversation_id, direction, source, kind,
                        body, wa_message_id, delivery_status, sent_at)
  values (v_clinic_id, v_patient_id, v_conversation_id, 'out', 'doctor_echo', p_kind,
          p_body, p_wa_message_id, 'sent', v_sent_at)
  on conflict (wa_message_id) do nothing
  returning id into v_message_id;

  update conversations
     set last_message_at     = greatest(last_message_at, v_sent_at),
         last_human_reply_at = greatest(coalesce(last_human_reply_at, v_sent_at), v_sent_at)
   where id = v_conversation_id;

  return coalesce(v_message_id, (select id from messages where wa_message_id = p_wa_message_id));
end
$$;

-- -----------------------------------------------------------------------------
-- 5. Should the assistant reply in this conversation right now?
--    No if a human has taken over, it is escalated/closed, or a dentist/staff
--    member replied within the clinic's echo pause.
-- -----------------------------------------------------------------------------
create or replace function core.assistant_may_reply(p_conversation_id uuid)
returns boolean
language sql
stable
security invoker
set search_path = core, pg_temp
as $$
  select coalesce((
    select cv.status = 'assistant'
       and (cv.last_human_reply_at is null
            or cv.last_human_reply_at <= now() - make_interval(mins => c.echo_pause_minutes))
      from conversations cv
      join clinics c on c.id = cv.clinic_id
     where cv.id = p_conversation_id
  ), false)
$$;

-- Within WhatsApp's 24-hour customer service window? (Outside it: templates only.)
create or replace function core.service_window_open(p_patient_id uuid)
returns boolean
language sql
stable
security invoker
set search_path = core, pg_temp
as $$
  select coalesce((select last_inbound_at > now() - interval '24 hours'
                     from patients where id = p_patient_id), false)
$$;

-- -----------------------------------------------------------------------------
-- 6. Outbound messages: write first, send second.
--    queue_outbound_message is idempotent on p_send_key: the same key returns
--    the same row, so a retried job never sends twice. Check delivery_status
--    on the returned row; only 'pending' rows should be sent.
-- -----------------------------------------------------------------------------
create or replace function core.queue_outbound_message(
  p_patient_id     uuid,
  p_source         text,                 -- 'assistant' | 'staff' | 'system'
  p_kind           text,
  p_body           text default null,
  p_template_name  text default null,
  p_send_key       text default null
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

  v_conversation_id := open_conversation_for(p_patient_id);

  return query
    insert into messages (clinic_id, patient_id, conversation_id, direction, source, kind,
                          body, template_name, send_key, delivery_status)
    values (v_clinic_id, p_patient_id, v_conversation_id, 'out', p_source, p_kind,
            p_body, p_template_name, p_send_key, 'pending')
    returning messages.id, messages.delivery_status;

  update conversations
     set last_message_at     = now(),
         last_human_reply_at = case when p_source = 'staff' then now() else last_human_reply_at end
   where id = v_conversation_id;
end
$$;

create or replace function core.mark_outbound_sent(p_message_id uuid, p_wa_message_id text)
returns boolean
language plpgsql
volatile
security invoker
set search_path = core, pg_temp
as $$
begin
  update messages
     set wa_message_id = p_wa_message_id, delivery_status = 'sent', sent_at = now()
   where id = p_message_id and direction = 'out' and delivery_status = 'pending';
  return found;
end
$$;

create or replace function core.mark_outbound_failed(p_message_id uuid, p_error text)
returns boolean
language plpgsql
volatile
security invoker
set search_path = core, pg_temp
as $$
begin
  update messages
     set delivery_status = 'failed', delivery_error = left(p_error, 1000)
   where id = p_message_id and direction = 'out' and delivery_status in ('pending', 'sent');
  return found;
end
$$;

-- Status webhooks arrive out of order; only move forward
-- (pending → sent → delivered → read). 'failed' is accepted until delivered.
create or replace function core.update_delivery_status(
  p_wa_message_id  text,
  p_status         text,
  p_error          text default null
)
returns boolean
language plpgsql
volatile
security invoker
set search_path = core, pg_temp
as $$
declare
  v_rank constant jsonb := '{"pending":0, "sent":1, "delivered":2, "read":3}';
begin
  if p_status = 'failed' then
    update messages
       set delivery_status = 'failed', delivery_error = left(p_error, 1000)
     where wa_message_id = p_wa_message_id and delivery_status in ('pending', 'sent');
  elsif v_rank ? p_status then
    update messages
       set delivery_status = p_status
     where wa_message_id = p_wa_message_id
       and delivery_status <> 'failed'
       and (v_rank ->> delivery_status)::int < (v_rank ->> p_status)::int;
  else
    raise exception 'unknown delivery status %', p_status using errcode = 'check_violation';
  end if;
  return found;
end
$$;

-- -----------------------------------------------------------------------------
-- 7. Inbound processing bookkeeping (the reconciler finds rows still null)
-- -----------------------------------------------------------------------------
create or replace function core.mark_message_processed(p_message_id uuid)
returns boolean
language plpgsql
volatile
security invoker
set search_path = core, pg_temp
as $$
begin
  update messages
     set processed_at = now(), process_attempts = process_attempts + 1
   where id = p_message_id and direction = 'in' and processed_at is null;
  return found;
end
$$;

create or replace function core.mark_message_attempt_failed(p_message_id uuid)
returns int
language sql
volatile
security invoker
set search_path = core, pg_temp
as $$
  update messages
     set process_attempts = process_attempts + 1
   where id = p_message_id and direction = 'in' and processed_at is null
  returning process_attempts
$$;

-- -----------------------------------------------------------------------------
-- 8. Conversation control
-- -----------------------------------------------------------------------------
create or replace function core.set_conversation_status(
  p_conversation_id  uuid,
  p_status           text,
  p_reason           text default null
)
returns boolean
language plpgsql
volatile
security invoker
set search_path = core, pg_temp
as $$
begin
  update conversations
     set status        = p_status,
         status_reason = p_reason,
         assigned_to   = case when p_status = 'assistant' then null else assigned_to end
   where id = p_conversation_id and status <> p_status;
  return found;
end
$$;

comment on function core.set_conversation_status(uuid, text, text) is
  'Assistant: escalate anytime, or hand over from assistant. Staff: any status; closed is final.';

-- -----------------------------------------------------------------------------
-- 9. Flow tokens
-- -----------------------------------------------------------------------------
create or replace function core.issue_flow_token(
  p_patient_id      uuid,
  p_language        text,
  p_purpose         text default 'book',
  p_appointment_id  uuid default null
)
returns text
language sql
volatile
security invoker
set search_path = core, pg_temp
as $$
  insert into flow_tokens (clinic_id, patient_id, language, purpose, appointment_id)
  values (current_clinic_id(), p_patient_id, p_language, p_purpose, p_appointment_id)
  returning token
$$;

-- Call after clinic_for_flow_token + set app.clinic_id. Null row = expired/unknown.
create or replace function core.read_flow_token(p_token text)
returns table (patient_id uuid, language text, purpose text, appointment_id uuid)
language sql
stable
security invoker
set search_path = core, pg_temp
as $$
  select f.patient_id, f.language, f.purpose, f.appointment_id
    from flow_tokens f
   where f.token = p_token and f.expires_at > now()
$$;

-- -----------------------------------------------------------------------------
-- 10. Retention: erase message text and media ids older than each clinic's
--     retention period. Metadata (who, when, kind, status) is kept.
--     Runs across all clinics → service_role only. Scheduled in Stage 4.
-- -----------------------------------------------------------------------------
create or replace function core.purge_message_bodies(p_batch_size int default 5000)
returns int
language sql
volatile
security invoker
set search_path = core, pg_temp
as $$
  with due as (
    select m.id
      from messages m
      join clinics c on c.id = m.clinic_id
     where m.body_purged_at is null
       and m.created_at < now() - make_interval(days => c.message_retention_days)
     limit p_batch_size
  ), purged as (
    update messages m
       set body = null, media_id = null, body_purged_at = now()
      from due
     where m.id = due.id
    returning 1
  )
  select count(*)::int from purged
$$;

-- Expired Flow tokens are useless; remove them (also Stage 4 cron).
create or replace function core.purge_expired_flow_tokens()
returns int
language sql
volatile
security invoker
set search_path = core, pg_temp
as $$
  with gone as (delete from flow_tokens where expires_at < now() - interval '1 day' returning 1)
  select count(*)::int from gone
$$;
