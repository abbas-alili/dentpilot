-- =============================================================================
-- Stage 4 · Migration 1 of 5 — Reminder/approval settings and the job queue
--
-- Decisions (SOP.md, Stage 4):
--   Q9  Reminder times are a clinic setting (default: 24 h before, with a
--       "please confirm" button).
--   Q6  Pending approvals never expire. Staff get one reminder after 2 h
--       (setting); the booking waits until staff approve or reject it.
--
-- The queue: a job is a row. Workers claim due rows with SKIP LOCKED, so two
-- workers never take the same job. Every job has an idempotency key built
-- from business identity (e.g. 'reminder:<appointment>:<offset>:<start>'),
-- so creating the same job twice is harmless.
--
--   pending ──claim──▶ running ──complete──▶ done
--      ▲                  │
--      └──fail (backoff)──┤──fail, attempts used up──▶ dead
--   pending ──cancel──▶ cancelled      (e.g. appointment cancelled)
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 1. Settings (admin-editable)
-- -----------------------------------------------------------------------------
alter table core.clinics
  add column reminder_offsets_minutes   int[]   not null default '{1440}',
  add column reminder_ask_confirmation  boolean not null default true,
  add column approval_reminder_minutes  int     not null default 120
    check (approval_reminder_minutes between 0 and 10080),
  add constraint clinics_reminder_offsets_valid check (
        cardinality(reminder_offsets_minutes) <= 3
    and 30    <= all (reminder_offsets_minutes)
    and 10080 >= all (reminder_offsets_minutes));

comment on column core.clinics.reminder_offsets_minutes  is 'When to remind patients, in minutes before the appointment. Up to 3 values, 30–10080. Empty = no reminders.';
comment on column core.clinics.reminder_ask_confirmation is 'Reminders carry a "confirm attendance" button.';
comment on column core.clinics.approval_reminder_minutes is 'Remind staff about a still-pending booking after this long. 0 = no reminder. Pending bookings never expire.';

grant update (reminder_offsets_minutes, reminder_ask_confirmation, approval_reminder_minutes)
  on core.clinics to authenticated;      -- admin_edit_settings policy limits this to admins

-- -----------------------------------------------------------------------------
-- 2. ops.background_jobs
-- -----------------------------------------------------------------------------
create table ops.background_jobs (
  id               uuid        primary key default gen_random_uuid(),
  clinic_id        uuid        references core.clinics (id),
  kind             text        not null check (kind in (
                     'process_message',     -- reconciler: inbound message never processed
                     'send_reminder',       -- WhatsApp reminder to a patient
                     'notify_patient',      -- tell patient a pending booking was approved/rejected
                     'approval_reminder',   -- nudge staff about a still-pending booking
                     'push_notification')), -- web push to one staff notification
  payload          jsonb       not null default '{}',
  idempotency_key  text        not null unique,
  status           text        not null default 'pending'
                     check (status in ('pending', 'running', 'done', 'dead', 'cancelled')),
  attempts         int         not null default 0,
  max_attempts     int         not null default 5 check (max_attempts between 1 and 20),
  run_after        timestamptz not null default now(),
  locked_at        timestamptz,
  locked_by        text,
  last_error       text,
  finished_at      timestamptz,
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now()
);

create index background_jobs_due_idx         on ops.background_jobs (run_after) where status = 'pending';
create index background_jobs_running_idx     on ops.background_jobs (locked_at) where status = 'running';
create index background_jobs_appointment_idx on ops.background_jobs ((payload ->> 'appointment_id'))
  where kind in ('send_reminder', 'approval_reminder', 'notify_patient');

create trigger set_updated_at before update on ops.background_jobs
  for each row execute function core.set_updated_at();

-- -----------------------------------------------------------------------------
-- 3. Queue functions — SECURITY DEFINER: callers get these operations, never
--    direct access to the table.
-- -----------------------------------------------------------------------------

-- Create a job. Same key = same job (returns its id). A cancelled job with the
-- same key is revived, so an appointment moved away and back gets reminders again.
create or replace function ops.enqueue_job(
  p_kind          text,
  p_clinic_id     uuid,
  p_payload       jsonb,
  p_key           text,
  p_run_after     timestamptz default now(),
  p_max_attempts  int         default 5
)
returns uuid
language plpgsql
volatile
security definer
set search_path = ops, pg_temp
as $$
declare
  v_job_id uuid;
begin
  insert into background_jobs (kind, clinic_id, payload, idempotency_key, run_after, max_attempts)
  values (p_kind, p_clinic_id, p_payload, p_key, p_run_after, p_max_attempts)
  on conflict (idempotency_key) do update
     set status = 'pending', run_after = excluded.run_after, attempts = 0,
         last_error = null, finished_at = null
   where background_jobs.status = 'cancelled'
  returning id into v_job_id;

  if v_job_id is null then
    select id into v_job_id from background_jobs where idempotency_key = p_key;
  end if;
  return v_job_id;
end
$$;

-- Claim up to p_limit due jobs. A 'running' job whose lease expired (worker
-- crashed) is claimed again, or marked dead if it has used all its attempts.
create or replace function ops.claim_jobs(
  p_kinds          text[] default null,
  p_limit          int    default 10,
  p_worker         text   default null,
  p_lease_minutes  int    default 10
)
returns setof ops.background_jobs
language plpgsql
volatile
security definer
set search_path = ops, pg_temp
as $$
begin
  update background_jobs
     set status = 'dead', finished_at = now(),
         last_error = coalesce(last_error, 'lease expired after final attempt')
   where status = 'running'
     and locked_at < now() - make_interval(mins => p_lease_minutes)
     and attempts >= max_attempts;

  return query
    update background_jobs j
       set status = 'running', locked_at = now(), locked_by = p_worker, attempts = j.attempts + 1
     where j.id in (
             select b.id
               from background_jobs b
              where (p_kinds is null or b.kind = any (p_kinds))
                and (   (b.status = 'pending' and b.run_after <= now())
                     or (b.status = 'running' and b.locked_at < now() - make_interval(mins => p_lease_minutes)))
              order by b.run_after
              limit p_limit
                for update skip locked)
    returning j.*;
end
$$;

create or replace function ops.complete_job(p_job_id uuid)
returns boolean
language plpgsql
volatile
security definer
set search_path = ops, pg_temp
as $$
begin
  update background_jobs
     set status = 'done', finished_at = now(), locked_at = null, locked_by = null
   where id = p_job_id and status = 'running';
  return found;
end
$$;

-- Retry with exponential backoff (2, 4, 8 … minutes, capped at 60), or dead.
-- Returns the job's new status.
create or replace function ops.fail_job(p_job_id uuid, p_error text)
returns text
language plpgsql
volatile
security definer
set search_path = ops, pg_temp
as $$
declare
  v_status text;
begin
  update background_jobs
     set status      = case when attempts >= max_attempts then 'dead' else 'pending' end,
         run_after   = now() + make_interval(mins => least(power(2, attempts)::int, 60)),
         finished_at = case when attempts >= max_attempts then now() end,
         last_error  = left(p_error, 2000),
         locked_at   = null,
         locked_by   = null
   where id = p_job_id and status = 'running'
  returning status into v_status;
  return v_status;
end
$$;

-- Cancel pending jobs of the given kinds for one appointment, except one key.
create or replace function ops.cancel_appointment_jobs(
  p_appointment_id  uuid,
  p_kinds           text[],
  p_keep_key_like   text default null
)
returns int
language sql
volatile
security definer
set search_path = ops, pg_temp
as $$
  with cancelled as (
    update background_jobs
       set status = 'cancelled', finished_at = now()
     where status = 'pending'
       and kind = any (p_kinds)
       and payload ->> 'appointment_id' = p_appointment_id::text
       and (p_keep_key_like is null or idempotency_key not like p_keep_key_like)
    returning 1
  )
  select count(*)::int from cancelled
$$;

-- Housekeeping: drop finished jobs after p_days.
create or replace function ops.cleanup_jobs(p_days int default 30)
returns int
language sql
volatile
security definer
set search_path = ops, pg_temp
as $$
  with gone as (
    delete from background_jobs
     where status in ('done', 'cancelled', 'dead')
       and finished_at < now() - make_interval(days => p_days)
    returning 1
  )
  select count(*)::int from gone
$$;
