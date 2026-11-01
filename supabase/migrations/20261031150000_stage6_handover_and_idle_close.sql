-- =============================================================================
-- Stage 6 · Migration 1 of 6 — Human reply = permanent hand-over (A7 revised)
--
-- Replaces the Stage 3 "echo pause":
--   • A dentist echo (Business App) or a staff reply (web app) moves the
--     conversation to handed_to_staff. The assistant stays silent until staff
--     return it, or until the conversation is closed.
--   • Idle conversations close automatically after
--     clinics.conversation_idle_close_hours (default 24); the patient's next
--     message opens a fresh conversation with the assistant.
--     Escalated conversations never auto-close — staff must act.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 1. Settings: idle close replaces the echo pause
-- -----------------------------------------------------------------------------
alter table core.clinics
  add column conversation_idle_close_hours int not null default 24
    check (conversation_idle_close_hours between 1 and 720);

comment on column core.clinics.conversation_idle_close_hours is
  'Close assistant/handed-over conversations after this many hours without messages. Escalated ones are never auto-closed.';

grant update (conversation_idle_close_hours) on core.clinics to authenticated;   -- admins, via admin_edit_settings

-- assistant_may_reply no longer looks at the pause: replace it first, then drop the column.
create or replace function core.assistant_may_reply(p_conversation_id uuid)
returns boolean
language sql
stable
security invoker
set search_path = core, pg_temp
as $$
  select coalesce((select status = 'assistant' from conversations where id = p_conversation_id), false)
$$;

alter table core.clinics drop column echo_pause_minutes;

-- -----------------------------------------------------------------------------
-- 2. A human reply hands the conversation over
--    Runs as the writer: the assistant role (echo via webhook) may move
--    assistant → handed_to_staff; staff may set any status.
-- -----------------------------------------------------------------------------
create or replace function core.messages_hand_over_on_human_reply()
returns trigger
language plpgsql
as $$
begin
  update core.conversations
     set status        = 'handed_to_staff',
         status_reason = case new.source when 'doctor_echo' then 'doctor_reply' else 'staff_reply' end
   where id = new.conversation_id
     and status = 'assistant';
  return null;
end
$$;

create trigger hand_over_on_human_reply after insert on core.messages
  for each row
  when (new.source in ('doctor_echo', 'staff'))
  execute function core.messages_hand_over_on_human_reply();

-- -----------------------------------------------------------------------------
-- 3. Don't notify staff about a hand-over a human just caused themselves
--    (replaces the Stage 4 version; escalation behaviour is unchanged)
-- -----------------------------------------------------------------------------
create or replace function ops.on_conversation_change()
returns trigger
language plpgsql
security definer
set search_path = ops, core, pg_temp
as $$
begin
  if new.status is not distinct from old.status then
    return null;
  end if;

  if new.status = 'escalated'
     or (new.status = 'handed_to_staff'
         and coalesce(new.status_reason, '') not in ('doctor_reply', 'staff_reply')) then
    perform notify_staff(new.clinic_id,
                         case new.status when 'escalated' then 'escalation' else 'handover' end,
                         new.status || ':' || new.id || ':' || new.version,
                         p_detail          => new.status_reason,
                         p_conversation_id => new.id);
  end if;
  return null;
end
$$;

-- -----------------------------------------------------------------------------
-- 4. Close idle conversations (scheduled hourly in the Stage 6 cron migration)
-- -----------------------------------------------------------------------------
create or replace function ops.close_idle_conversations()
returns int
language sql
volatile
security definer
set search_path = ops, core, pg_temp
as $$
  with closed as (
    update core.conversations cv
       set status = 'closed', status_reason = 'idle'
      from core.clinics c
     where c.id = cv.clinic_id
       and cv.status in ('assistant', 'handed_to_staff')
       and cv.last_message_at < now() - make_interval(hours => c.conversation_idle_close_hours)
    returning 1
  )
  select count(*)::int from closed
$$;
