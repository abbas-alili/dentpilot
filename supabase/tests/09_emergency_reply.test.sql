-- =============================================================================
-- Emergency reply bypasses shadow mode — and nothing else does.
-- =============================================================================
begin;
create extension if not exists pgtap;

select plan(7);

create schema t;
create function t.id(p_key text) returns uuid language sql stable as
  $$ select nullif(current_setting('t.' || p_key, true), '')::uuid $$;
grant usage on schema t to dentpilot_agent;
grant execute on all functions in schema t to dentpilot_agent;

insert into core.clinics (id, name) values ('11111111-0000-0000-0000-00000000000a', 'Clinic A');   -- shadow mode on (default)
insert into core.patients (id, clinic_id, wa_id, preferred_language) values
  ('11111111-0000-0000-0000-0000000000f1', '11111111-0000-0000-0000-00000000000a', '994500000001', 'az'),
  ('11111111-0000-0000-0000-0000000000f2', '11111111-0000-0000-0000-00000000000a', '994500000002', 'ru');

set local role dentpilot_agent;
select set_config('app.clinic_id', '11111111-0000-0000-0000-00000000000a', true);

select set_config('t.e1', (select message_id::text from core.queue_emergency_reply('11111111-0000-0000-0000-0000000000f1', 'reply:x:emergency')), true);
select is((select delivery_status from core.messages where id = t.id('e1')), 'pending',
  'in shadow mode the emergency reply is queued to send at once, not as a draft');
select ok((select body like '%103%' and outbound_payload #>> '{text,body}' = body from core.messages where id = t.id('e1')),
  'it is the fixed clinic text, payload included');
select is((select message_id from core.queue_emergency_reply('11111111-0000-0000-0000-0000000000f1', 'reply:x:emergency')),
  t.id('e1'), 'same inbound emergency → same reply (never twice)');
select set_config('t.e2', (select message_id::text from core.queue_emergency_reply('11111111-0000-0000-0000-0000000000f2', 'reply:y:emergency')), true);
select ok((select body like '%звоните 103%' from core.messages where id = t.id('e2')),
  'Russian-speaking patient gets the Russian text');
select is((select delivery_status from core.queue_outbound_message('11111111-0000-0000-0000-0000000000f1', 'assistant', 'text',
           'Salam', null, 'k-normal', '{"type":"text","text":{"body":"Salam"}}')), 'draft',
  'every other bot message is still a draft');
select throws_ok($$ update core.clinics set emergency_reply_az = 'x' $$, '42501', null,
  'the assistant cannot change the emergency text');
reset role;

select throws_ok($$ update core.clinics set emergency_reply_az = 'short' $$, '23514', null,
  'an empty or too-short emergency text is rejected');

select * from finish();
rollback;
