-- =============================================================================
-- Emergency reply bypasses shadow mode (decision S1, 2026-11-03)
--
-- In shadow mode every bot message waits for the doctor — except ONE: the
-- fixed emergency reply telling the patient to call 103 themselves. It is
-- sent at once, because a delay of hours could matter.
--
-- The guarantee lives in the database: the text is a clinic setting
-- (reviewed, admin-editable), and only core.queue_emergency_reply() may queue
-- it as 'pending' in shadow mode. It takes no text argument, so neither the
-- pipeline nor the LLM can push anything else past the doctor this way.
-- =============================================================================

alter table core.clinics
  add column emergency_reply_az text not null default
    'Mesajınızı dərhal həkimə çatdırdıq, sizinlə tezliklə əlaqə saxlanılacaq. Vəziyyət ağırdırsa, 103-ə zəng edin.'
    check (length(btrim(emergency_reply_az)) between 10 and 1000),
  add column emergency_reply_ru text not null default
    'Мы сразу передали ваше сообщение врачу, с вами скоро свяжутся. Если состояние тяжёлое, звоните 103.'
    check (length(btrim(emergency_reply_ru)) between 10 and 1000);

comment on column core.clinics.emergency_reply_az is
  'Fixed reply to an emergency message (Azerbaijani). Sent immediately, even in shadow mode. Review with the clinic.';
comment on column core.clinics.emergency_reply_ru is
  'Fixed reply to an emergency message (Russian). Sent immediately, even in shadow mode. Review with the clinic.';

grant update (emergency_reply_az, emergency_reply_ru) on core.clinics to authenticated;   -- admins only (policy)

create or replace function core.queue_emergency_reply(p_patient_id uuid, p_send_key text)
returns table (message_id uuid, delivery_status text)
language plpgsql
volatile
security invoker
set search_path = core, pg_temp
as $$
declare
  v_clinic_id        uuid := current_clinic_id();
  v_text             text;
  v_conversation_id  uuid;
begin
  -- Idempotent: the same inbound emergency never gets two replies.
  return query
    select m.id, m.delivery_status from messages m
     where m.clinic_id = v_clinic_id and m.send_key = p_send_key;
  if found then
    return;
  end if;

  select case p.preferred_language when 'ru' then c.emergency_reply_ru else c.emergency_reply_az end
    into v_text
    from patients p join clinics c on c.id = p.clinic_id
   where p.id = p_patient_id;
  if v_text is null then
    raise exception 'patient % not found', p_patient_id using errcode = 'no_data_found';
  end if;

  v_conversation_id := open_conversation_for(p_patient_id);

  return query
    insert into messages (clinic_id, patient_id, conversation_id, direction, source, kind,
                          body, send_key, delivery_status, outbound_payload)
    values (v_clinic_id, p_patient_id, v_conversation_id, 'out', 'assistant', 'text',
            v_text, p_send_key, 'pending',                        -- never a draft
            jsonb_build_object('type', 'text', 'text', jsonb_build_object('body', v_text, 'preview_url', false)))
    returning messages.id, messages.delivery_status;

  update conversations set last_message_at = now() where id = v_conversation_id;
end
$$;

grant execute on function core.queue_emergency_reply(uuid, text) to dentpilot_agent, service_role;
revoke execute on function core.queue_emergency_reply(uuid, text) from public;
