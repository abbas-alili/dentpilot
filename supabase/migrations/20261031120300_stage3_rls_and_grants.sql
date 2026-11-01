-- =============================================================================
-- Stage 3 · Migration 4 of 4 — Row-level security and grants for messaging
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 1. RLS on the new tables
-- -----------------------------------------------------------------------------
do $$
declare
  t text;
begin
  foreach t in array array['core.conversations', 'core.messages', 'core.flow_tokens']
  loop
    execute format('alter table %s enable row level security', t);
    execute format('alter table %s force row level security', t);

    execute format(
      'create policy agent_own_clinic on %s
         for all to dentpilot_agent
         using      (clinic_id = core.current_clinic_id())
         with check (clinic_id = core.current_clinic_id())', t);

    execute format(
      'create policy staff_own_clinics on %s
         for all to authenticated
         using      (clinic_id in (select ops.my_clinic_ids()))
         with check (clinic_id in (select ops.my_clinic_ids()))', t);
  end loop;
end
$$;

-- Staff may read message history and queue their own replies — nothing else.
-- Replace the generic all-commands policy on messages with two narrow ones.
drop policy staff_own_clinics on core.messages;

create policy staff_read_messages on core.messages
  for select to authenticated
  using (clinic_id in (select ops.my_clinic_ids()));

create policy staff_queue_replies on core.messages
  for insert to authenticated
  with check (clinic_id in (select ops.my_clinic_ids())
              and direction = 'out' and source = 'staff' and delivery_status = 'pending');

-- -----------------------------------------------------------------------------
-- 2. dentpilot_agent — table rights are only what its functions need
--    (they run as the caller). No deletes on messages or conversations.
-- -----------------------------------------------------------------------------
grant select, insert on core.conversations to dentpilot_agent;
grant update (status, status_reason, assigned_to, last_message_at, last_human_reply_at)
  on core.conversations to dentpilot_agent;

grant select, insert on core.messages to dentpilot_agent;
grant update (wa_message_id, delivery_status, delivery_error, sent_at, processed_at, process_attempts)
  on core.messages to dentpilot_agent;

grant select, insert on core.flow_tokens to dentpilot_agent;

grant execute on function
  core.clinic_for_phone_number(text),
  core.clinic_for_flow_token(text),
  core.open_conversation_for(uuid),
  core.record_inbound_message(text, text, text, text, text, text, timestamptz, text, text),
  core.record_echo_message(text, text, text, text, timestamptz),
  core.assistant_may_reply(uuid),
  core.service_window_open(uuid),
  core.queue_outbound_message(uuid, text, text, text, text, text),
  core.mark_outbound_sent(uuid, text),
  core.mark_outbound_failed(uuid, text),
  core.update_delivery_status(text, text, text),
  core.mark_message_processed(uuid),
  core.mark_message_attempt_failed(uuid),
  core.set_conversation_status(uuid, text, text),
  core.issue_flow_token(uuid, text, text, uuid),
  core.read_flow_token(text),
  core.patient_can_change(uuid)
to dentpilot_agent;

-- -----------------------------------------------------------------------------
-- 3. authenticated (staff app): read conversations and messages, take over,
--    send messages through the queue. Message history is not editable.
-- -----------------------------------------------------------------------------
grant select, insert, update on core.conversations to authenticated;
grant select                 on core.messages      to authenticated;
grant select                 on core.flow_tokens   to authenticated;

grant execute on function
  core.open_conversation_for(uuid),
  core.assistant_may_reply(uuid),
  core.service_window_open(uuid),
  core.queue_outbound_message(uuid, text, text, text, text, text),
  core.set_conversation_status(uuid, text, text),
  core.patient_can_change(uuid)
to authenticated;
-- queue_outbound_message inserts into messages as the caller:
grant insert on core.messages to authenticated;

-- -----------------------------------------------------------------------------
-- 4. service_role — sending, retention and cleanup jobs (Stage 4 schedules them)
-- -----------------------------------------------------------------------------
grant select, insert, update, delete on all tables    in schema core, ops to service_role;
grant execute                        on all functions in schema core, ops to service_role;

-- -----------------------------------------------------------------------------
-- 5. PUBLIC — no function execution
-- -----------------------------------------------------------------------------
revoke execute on all functions in schema core, clinical, ops from public;
