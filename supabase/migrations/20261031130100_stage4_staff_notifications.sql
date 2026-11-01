-- =============================================================================
-- Stage 4 · Migration 2 of 5 — Staff notifications and web push
--
-- Decision Q8: staff are alerted by web push from the staff web app.
--   • ops.staff_notifications — one row per recipient; it is also the in-app
--     inbox (works even if push fails or is not allowed on a device).
--   • ops.push_subscriptions  — browser push endpoints, one per staff device.
--   • Each notification enqueues a 'push_notification' job; the run-jobs
--     Edge Function sends it with the VAPID keys (Edge Function secrets).
--
-- Privacy: notifications store a kind and references, never message text.
-- The app renders the wording in the staff member's language.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 1. Notifications (inbox)
-- -----------------------------------------------------------------------------
create table ops.staff_notifications (
  id               uuid        primary key default gen_random_uuid(),
  user_id          uuid        not null references auth.users (id) on delete cascade,
  clinic_id        uuid        not null references core.clinics (id),
  kind             text        not null check (kind in ('escalation', 'handover', 'pending_approval', 'approval_reminder')),
  detail           text,                                  -- short code, e.g. 'emergency:bleeding'
  conversation_id  uuid        references core.conversations (id),
  appointment_id   uuid        references core.appointments (id),
  dedupe_key       text        not null,                  -- same event never notifies a user twice
  read_at          timestamptz,
  created_at       timestamptz not null default now(),

  unique (user_id, dedupe_key)
);

create index staff_notifications_inbox_idx on ops.staff_notifications (user_id, created_at desc);
create index staff_notifications_unread_idx on ops.staff_notifications (user_id) where read_at is null;

-- -----------------------------------------------------------------------------
-- 2. Push subscriptions (Web Push API: endpoint + p256dh + auth)
-- -----------------------------------------------------------------------------
create table ops.push_subscriptions (
  id               uuid        primary key default gen_random_uuid(),
  user_id          uuid        not null references auth.users (id) on delete cascade,
  endpoint         text        not null unique check (endpoint like 'https://%'),
  p256dh           text        not null,
  auth             text        not null,
  user_agent       text,
  failure_count    int         not null default 0,
  last_success_at  timestamptz,
  disabled_at      timestamptz,                           -- set when the browser says it's gone
  created_at       timestamptz not null default now()
);

create index push_subscriptions_user_idx on ops.push_subscriptions (user_id) where disabled_at is null;

-- -----------------------------------------------------------------------------
-- 3. Notify every staff member of a clinic (small clinics: everyone sees
--    everything). Returns the number of notifications created.
-- -----------------------------------------------------------------------------
create or replace function ops.notify_staff(
  p_clinic_id        uuid,
  p_kind             text,
  p_dedupe_key       text,
  p_detail           text default null,
  p_conversation_id  uuid default null,
  p_appointment_id   uuid default null
)
returns int
language plpgsql
volatile
security definer
set search_path = ops, pg_temp
as $$
declare
  v_notification_id uuid;
  v_count           int := 0;
begin
  for v_notification_id in
    insert into staff_notifications (user_id, clinic_id, kind, detail, conversation_id, appointment_id, dedupe_key)
    select s.user_id, p_clinic_id, p_kind, p_detail, p_conversation_id, p_appointment_id, p_dedupe_key
      from staff s
     where s.clinic_id = p_clinic_id
    on conflict (user_id, dedupe_key) do nothing
    returning id
  loop
    perform enqueue_job('push_notification', p_clinic_id,
                        jsonb_build_object('notification_id', v_notification_id),
                        'push:' || v_notification_id);
    v_count := v_count + 1;
  end loop;
  return v_count;
end
$$;

-- -----------------------------------------------------------------------------
-- 4. For the push worker: what to send, and to which devices
-- -----------------------------------------------------------------------------
create or replace function ops.push_targets(p_notification_id uuid)
returns table (
  subscription_id  uuid,
  endpoint         text,
  p256dh           text,
  auth             text,
  kind             text,
  detail           text,
  conversation_id  uuid,
  appointment_id   uuid
)
language sql
stable
security definer
set search_path = ops, pg_temp
as $$
  select ps.id, ps.endpoint, ps.p256dh, ps.auth,
         n.kind, n.detail, n.conversation_id, n.appointment_id
    from staff_notifications n
    join push_subscriptions ps on ps.user_id = n.user_id and ps.disabled_at is null
   where n.id = p_notification_id
$$;

-- Record the push service's answer. gone = HTTP 404/410: the browser
-- unsubscribed, so stop using this endpoint.
create or replace function ops.record_push_result(
  p_subscription_id  uuid,
  p_success          boolean,
  p_gone             boolean default false
)
returns void
language sql
volatile
security definer
set search_path = ops, pg_temp
as $$
  update push_subscriptions
     set last_success_at = case when p_success then now() else last_success_at end,
         failure_count   = case when p_success then 0 else failure_count + 1 end,
         disabled_at     = case when p_gone or (not p_success and failure_count + 1 >= 10) then now() else disabled_at end
   where id = p_subscription_id
$$;

-- -----------------------------------------------------------------------------
-- 5. Staff-side helpers
-- -----------------------------------------------------------------------------
-- Register (or refresh) this browser for push. Re-subscribing re-enables it.
create or replace function ops.register_push_subscription(
  p_endpoint    text,
  p_p256dh      text,
  p_auth        text,
  p_user_agent  text default null
)
returns uuid
language sql
volatile
security definer
set search_path = ops, pg_temp
as $$
  insert into push_subscriptions (user_id, endpoint, p256dh, auth, user_agent)
  values (auth.uid(), p_endpoint, p_p256dh, p_auth, p_user_agent)
  on conflict (endpoint) do update
     set user_id = auth.uid(), p256dh = excluded.p256dh, auth = excluded.auth,
         user_agent = excluded.user_agent, disabled_at = null, failure_count = 0
  returning id
$$;

create or replace function ops.mark_notifications_read(p_notification_ids uuid[])
returns int
language sql
volatile
security definer
set search_path = ops, pg_temp
as $$
  with marked as (
    update staff_notifications
       set read_at = now()
     where id = any (p_notification_ids) and user_id = auth.uid() and read_at is null
    returning 1
  )
  select count(*)::int from marked
$$;

-- Housekeeping: drop read notifications after p_days.
create or replace function ops.cleanup_notifications(p_days int default 90)
returns int
language sql
volatile
security definer
set search_path = ops, pg_temp
as $$
  with gone as (
    delete from staff_notifications where read_at < now() - make_interval(days => p_days) returning 1
  )
  select count(*)::int from gone
$$;
