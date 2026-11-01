-- =============================================================================
-- Staff web app — Step 1: the API the app calls (one function per screen)
--
-- The app talks to Supabase directly as the signed-in staff member (role
-- authenticated), so every function here is SECURITY INVOKER and row-level
-- security limits it to the staff member's clinic(s). Writes reuse the
-- existing functions, so version checks, the 24-hour window and status rules
-- apply exactly as everywhere else.
--
--   ops.my_staff_profile()                    who am I, which clinic, which role
--   core.staff_counts()                       badges: drafts, pending, attention, unread
--   core.staff_draft_inbox()                  Inbox screen
--   core.staff_pending_bookings()             Bookings screen (incl. max duration)
--   core.staff_conversations(filter)          Conversations list
--   core.staff_conversation_info(id)          thread header (status, 24-h window)
--   core.staff_conversation_messages(id)      one thread
--   core.staff_send_reply(conversation, text) reply as staff (24-h window enforced)
--   core.staff_day_schedule(date, dentist)    Today screen
--   core.staff_set_appointment_status(...)    arrived / done / no-show / cancel
-- =============================================================================

-- -----------------------------------------------------------------------------
-- Who am I
-- -----------------------------------------------------------------------------
create or replace function ops.my_staff_profile()
returns table (
  clinic_id          uuid,
  clinic_name        text,
  timezone           text,
  role               text,
  professional_id    uuid,
  professional_name  text,
  shadow_mode        boolean
)
language sql
stable
security definer
set search_path = ops, core, pg_temp
as $$
  select c.id, c.name, c.timezone, s.role, s.professional_id, p.display_name, c.shadow_mode
    from staff s
    join core.clinics c on c.id = s.clinic_id
    left join core.professionals p on p.id = s.professional_id
   where s.user_id = auth.uid()
   order by c.name
$$;

-- -----------------------------------------------------------------------------
-- Badges
-- -----------------------------------------------------------------------------
create or replace function core.staff_counts()
returns table (drafts int, pending_bookings int, attention int, unread_notifications int)
language sql
stable
security invoker
set search_path = core, pg_temp
as $$
  select
    (select count(*)::int from messages where delivery_status = 'draft'),
    (select count(*)::int from appointments where status = 'pending_approval'),
    (select count(*)::int from conversations where status in ('escalated', 'handed_to_staff')),
    (select count(*)::int from ops.staff_notifications where read_at is null)
$$;

-- -----------------------------------------------------------------------------
-- Inbox: drafts waiting for approval, oldest first, with the message they answer
-- -----------------------------------------------------------------------------
create or replace function core.staff_draft_inbox()
returns table (
  message_id           uuid,
  conversation_id      uuid,
  patient_id           uuid,
  patient_name         text,
  wa_id                text,
  language             text,
  kind                 text,
  body                 text,
  template_name        text,
  editable             boolean,
  created_at           timestamptz,
  replying_to          text,
  conversation_status  text,
  window_open          boolean
)
language sql
stable
security invoker
set search_path = core, pg_temp
as $$
  select m.id, m.conversation_id, p.id, p.display_name, p.wa_id, p.preferred_language,
         m.kind, m.body, m.template_name,
         coalesce(m.outbound_payload ->> 'type', '') in ('text', 'interactive'),
         m.created_at,
         (select case when i.kind = 'text' then i.body else '[' || i.kind || ']' end
            from messages i
           where i.conversation_id = m.conversation_id and i.direction = 'in' and i.created_at <= m.created_at
           order by i.created_at desc limit 1),
         cv.status,
         service_window_open(p.id)
    from messages m
    join patients p       on p.id  = m.patient_id
    join conversations cv on cv.id = m.conversation_id
   where m.delivery_status = 'draft'
   order by m.created_at
$$;

-- -----------------------------------------------------------------------------
-- Bookings: pending requests, soonest first.
-- max_duration_minutes = time until the dentist's next booking or block
-- (minus the service buffer), capped at 480 — the duration picker's upper limit.
-- -----------------------------------------------------------------------------
create or replace function core.staff_pending_bookings()
returns table (
  appointment_id        uuid,
  version               int,
  patient_id            uuid,
  patient_name          text,
  wa_id                 text,
  service_name          text,
  service_minutes       int,
  buffer_minutes        int,
  professional_id       uuid,
  professional_name     text,
  start_at              timestamptz,
  local_start           text,
  held_minutes          int,
  max_duration_minutes  int,
  requested_at          timestamptz,
  booked_by             text
)
language sql
stable
security invoker
set search_path = core, pg_temp
as $$
  select a.id, a.version, p.id, p.display_name, p.wa_id,
         s.name_az, s.duration_minutes, s.buffer_minutes,
         pr.id, pr.display_name,
         a.start_at,
         to_char(a.start_at at time zone c.timezone, 'YYYY-MM-DD"T"HH24:MI'),
         (extract(epoch from a.end_at - a.start_at) / 60)::int,
         greatest(5, least(480,
           (extract(epoch from coalesce(nxt.start_at, a.start_at + interval '8 hours') - a.start_at) / 60)::int
           - s.buffer_minutes)),
         a.created_at,
         a.booked_by
    from appointments a
    join patients p       on p.id  = a.patient_id
    join services s       on s.id  = a.service_id
    join professionals pr on pr.id = a.professional_id
    join clinics c        on c.id  = a.clinic_id
    left join lateral (
      select min(x.start_at) as start_at
        from (select o.start_at from appointments o
               where o.professional_id = a.professional_id and o.id <> a.id
                 and is_active_status(o.status) and o.start_at > a.start_at
              union all
              select b.start_at from blocks b
               where b.clinic_id = a.clinic_id
                 and (b.professional_id = a.professional_id or b.professional_id is null)
                 and b.start_at > a.start_at) x
    ) nxt on true
   where a.status = 'pending_approval'
   order by a.start_at
$$;

-- -----------------------------------------------------------------------------
-- Conversations list
--   filter: 'attention' (escalated or with staff) | 'open' (not closed) | 'all'
-- -----------------------------------------------------------------------------
create or replace function core.staff_conversations(p_filter text default 'attention', p_limit int default 50)
returns table (
  conversation_id   uuid,
  patient_id        uuid,
  patient_name      text,
  wa_id             text,
  status            text,
  status_reason     text,
  last_message_at   timestamptz,
  last_preview      text,
  last_direction    text,
  drafts            int,
  version           int
)
language sql
stable
security invoker
set search_path = core, pg_temp
as $$
  select cv.id, p.id, p.display_name, p.wa_id, cv.status, cv.status_reason, cv.last_message_at,
         left(case when lm.kind in ('text', 'template') or lm.direction = 'out' then coalesce(lm.body, '[' || lm.kind || ']')
                   else '[' || lm.kind || ']' end, 80),
         lm.direction,
         (select count(*)::int from messages d where d.conversation_id = cv.id and d.delivery_status = 'draft'),
         cv.version
    from conversations cv
    join patients p on p.id = cv.patient_id
    left join lateral (
      select m.kind, m.body, m.direction from messages m
       where m.conversation_id = cv.id and m.delivery_status is distinct from 'discarded'
       order by m.created_at desc, (m.direction = 'out') desc limit 1
    ) lm on true
   where case p_filter
           when 'attention' then cv.status in ('escalated', 'handed_to_staff')
           when 'open'      then cv.status <> 'closed'
           else true
         end
   order by (cv.status = 'escalated') desc, cv.last_message_at desc
   limit least(p_limit, 200)
$$;

-- Header of one thread: who, status, whether free text is allowed now.
create or replace function core.staff_conversation_info(p_conversation_id uuid)
returns table (
  conversation_id  uuid,
  patient_id       uuid,
  patient_name     text,
  wa_id            text,
  language         text,
  status           text,
  status_reason    text,
  version          int,
  window_open      boolean
)
language sql
stable
security invoker
set search_path = core, pg_temp
as $$
  select cv.id, p.id, p.display_name, p.wa_id, p.preferred_language, cv.status, cv.status_reason, cv.version,
         service_window_open(p.id)
    from conversations cv
    join patients p on p.id = cv.patient_id
   where cv.id = p_conversation_id
$$;

-- One thread, oldest first (the latest p_limit messages).
create or replace function core.staff_conversation_messages(p_conversation_id uuid, p_limit int default 200)
returns table (
  message_id       uuid,
  direction        text,
  source           text,
  kind             text,
  body             text,
  template_name    text,
  delivery_status  text,
  edited           boolean,
  created_at       timestamptz
)
language sql
stable
security invoker
set search_path = core, pg_temp
as $$
  select * from (
    select m.id, m.direction, m.source, m.kind, m.body, m.template_name, m.delivery_status, m.edited, m.created_at
      from messages m
     where m.conversation_id = p_conversation_id
     order by m.created_at desc, (m.direction = 'out') desc
     limit least(p_limit, 500)
  ) last_n
  order by created_at, (direction = 'out')   -- same instant: the patient's message first
$$;

-- -----------------------------------------------------------------------------
-- Reply as staff. Free text is only allowed within WhatsApp's 24-hour window
-- (error DP002 otherwise — the app says so). The send itself is queued by the
-- existing trigger; the reply also hands the conversation to staff.
-- -----------------------------------------------------------------------------
create or replace function core.staff_send_reply(p_conversation_id uuid, p_text text)
returns uuid
language plpgsql
volatile
security invoker
set search_path = core, pg_temp
as $$
declare
  v_clinic_id   uuid;
  v_patient_id  uuid;
  v_text        text := btrim(p_text);
  v_message_id  uuid;
begin
  if v_text is null or length(v_text) not between 1 and 4096 then
    raise exception 'reply must be 1–4096 characters' using errcode = 'check_violation';
  end if;

  select clinic_id, patient_id into v_clinic_id, v_patient_id
    from conversations where id = p_conversation_id;          -- RLS: own clinic only
  if not found then
    raise exception 'conversation not found' using errcode = 'no_data_found';
  end if;

  if not service_window_open(v_patient_id) then
    raise exception 'the patient has not written in the last 24 hours; WhatsApp allows only templates'
      using errcode = 'DP002';
  end if;

  perform set_config('app.clinic_id', v_clinic_id::text, true);   -- for queue_outbound_message
  select q.message_id into v_message_id
    from queue_outbound_message(v_patient_id, 'staff', 'text', v_text, null, null,
           jsonb_build_object('type', 'text', 'text', jsonb_build_object('body', v_text, 'preview_url', false))) q;
  return v_message_id;
end
$$;

-- -----------------------------------------------------------------------------
-- Today: one local day's appointments (all dentists, or one)
-- -----------------------------------------------------------------------------
create or replace function core.staff_day_schedule(p_local_date date, p_professional_id uuid default null)
returns table (
  appointment_id     uuid,
  version            int,
  local_start        text,
  local_end          text,
  patient_id         uuid,
  patient_name       text,
  wa_id              text,
  service_name       text,
  professional_id    uuid,
  professional_name  text,
  status             text,
  booked_by          text
)
language sql
stable
security invoker
set search_path = core, pg_temp
as $$
  select a.id, a.version,
         to_char(a.start_at at time zone c.timezone, 'HH24:MI'),
         to_char(a.end_at   at time zone c.timezone, 'HH24:MI'),
         p.id, p.display_name, p.wa_id, s.name_az, pr.id, pr.display_name, a.status, a.booked_by
    from appointments a
    join clinics c        on c.id  = a.clinic_id
    join patients p       on p.id  = a.patient_id
    join services s       on s.id  = a.service_id
    join professionals pr on pr.id = a.professional_id
   where c.id = current_clinic_id()
     and a.start_at >= (p_local_date::timestamp at time zone c.timezone)
     and a.start_at <  ((p_local_date + 1)::timestamp at time zone c.timezone)
     and a.status not in ('cancelled', 'rejected')
     and (p_professional_id is null or a.professional_id = p_professional_id)
   order by a.start_at, pr.display_name
$$;

-- -----------------------------------------------------------------------------
-- Arrived / done / no-show / confirmed / cancelled — with the version check.
-- The status-transition trigger still decides what is allowed.
-- -----------------------------------------------------------------------------
create or replace function core.staff_set_appointment_status(
  p_appointment_id    uuid,
  p_expected_version  int,
  p_status            text
)
returns boolean
language plpgsql
volatile
security invoker
set search_path = core, pg_temp
as $$
begin
  if p_status not in ('confirmed', 'checked_in', 'completed', 'no_show', 'cancelled') then
    raise exception 'staff cannot set status %', p_status using errcode = 'check_violation';
  end if;
  update appointments
     set status = p_status,
         cancel_reason = case when p_status = 'cancelled' then 'staff' else cancel_reason end
   where id = p_appointment_id and version = p_expected_version;
  return found;
end
$$;

-- -----------------------------------------------------------------------------
-- Grants
-- -----------------------------------------------------------------------------
grant execute on function
  ops.my_staff_profile(),
  core.staff_counts(),
  core.staff_draft_inbox(),
  core.staff_pending_bookings(),
  core.staff_conversations(text, int),
  core.staff_conversation_info(uuid),
  core.staff_conversation_messages(uuid, int),
  core.staff_send_reply(uuid, text),
  core.staff_day_schedule(date, uuid),
  core.staff_set_appointment_status(uuid, int, text),
  core.is_active_status(text)
to authenticated;

grant execute on all functions in schema core, ops to service_role;
revoke execute on all functions in schema core, clinical, ops from public;
