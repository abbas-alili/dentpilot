-- =============================================================================
-- Google Calendar (clinic answers E5/E8: doctors use Android + Google Calendar)
--
-- One-way sync DentPilot → the dentist's PRIMARY Google Calendar (decision).
-- The iCalendar feed stays as a backup.
--
--   google-oauth Edge Function   staff connect a dentist's Google account;
--                                the refresh token goes to Supabase Vault,
--                                never into a table.
--   appointment change ──trigger──▶ gcal_sync job ──run-jobs──▶ Google Calendar API
--
-- Event ids are derived from the appointment id, so every write is an
-- idempotent upsert. ops.gcal_events remembers where each appointment was
-- written, so a change of dentist removes the event from the old calendar.
-- =============================================================================

create table ops.google_calendar_links (
  professional_id    uuid        primary key,
  clinic_id          uuid        not null references core.clinics (id),
  google_email       text,
  calendar_id        text        not null default 'primary',
  refresh_secret_id  uuid        not null,                          -- vault.secrets id
  status             text        not null default 'active' check (status in ('active', 'needs_reconnect')),
  last_error         text,
  connected_by       uuid        references auth.users (id),
  connected_at       timestamptz not null default now(),

  foreign key (clinic_id, professional_id) references core.professionals (clinic_id, id)
);

create table ops.gcal_events (
  appointment_id   uuid        primary key references core.appointments (id),
  professional_id  uuid        not null,
  event_id         text        not null,
  synced_version   int         not null,
  synced_at        timestamptz not null default now()
);

create trigger audit after insert or update or delete on ops.google_calendar_links
  for each row execute function ops.audit_row();

-- -----------------------------------------------------------------------------
-- Link management (SECURITY DEFINER; called by the google-oauth function)
-- -----------------------------------------------------------------------------
create or replace function ops.save_google_link(
  p_professional_id  uuid,
  p_google_email     text,
  p_refresh_token    text,
  p_connected_by     uuid
)
returns void
language plpgsql
volatile
security definer
set search_path = ops, core, pg_temp
as $$
declare
  v_clinic_id uuid;
  v_secret_id uuid;
begin
  select clinic_id into v_clinic_id from core.professionals where id = p_professional_id;
  if v_clinic_id is null then
    raise exception 'unknown professional %', p_professional_id using errcode = 'no_data_found';
  end if;

  select refresh_secret_id into v_secret_id from google_calendar_links where professional_id = p_professional_id;
  if v_secret_id is null then
    v_secret_id := vault.create_secret(p_refresh_token, 'gcal_refresh_' || p_professional_id);
  else
    perform vault.update_secret(v_secret_id, p_refresh_token);
  end if;

  insert into google_calendar_links (professional_id, clinic_id, google_email, refresh_secret_id, connected_by)
  values (p_professional_id, v_clinic_id, p_google_email, v_secret_id, p_connected_by)
  on conflict (professional_id) do update
     set google_email = excluded.google_email, status = 'active', last_error = null,
         connected_by = excluded.connected_by, connected_at = now();
end
$$;

-- For the sync worker only: the link with its decrypted refresh token.
create or replace function ops.google_link_for(p_professional_id uuid)
returns table (calendar_id text, refresh_token text, status text)
language sql
stable
security definer
set search_path = ops, pg_temp
as $$
  select l.calendar_id, s.decrypted_secret, l.status
    from google_calendar_links l
    join vault.decrypted_secrets s on s.id = l.refresh_secret_id
   where l.professional_id = p_professional_id
$$;

-- Google revoked access (password change, removed app…): stop syncing, tell staff.
create or replace function ops.mark_google_link_broken(p_professional_id uuid, p_error text)
returns void
language plpgsql
volatile
security definer
set search_path = ops, pg_temp
as $$
declare
  v_clinic_id uuid;
begin
  update google_calendar_links
     set status = 'needs_reconnect', last_error = left(p_error, 500)
   where professional_id = p_professional_id and status = 'active'
  returning clinic_id into v_clinic_id;

  if v_clinic_id is not null then
    perform notify_staff(v_clinic_id, 'calendar_disconnected',
                         'gcal_broken:' || p_professional_id || ':' || now()::date, p_detail => 'google_calendar');
  end if;
end
$$;

-- -----------------------------------------------------------------------------
-- Sync bookkeeping (where each appointment was written)
-- -----------------------------------------------------------------------------
create or replace function ops.gcal_event_for(p_appointment_id uuid)
returns table (professional_id uuid, event_id text, synced_version int)
language sql
stable
security definer
set search_path = ops, pg_temp
as $$
  select professional_id, event_id, synced_version from gcal_events where appointment_id = p_appointment_id
$$;

create or replace function ops.record_gcal_event(
  p_appointment_id uuid, p_professional_id uuid, p_event_id text, p_version int
)
returns void
language sql
volatile
security definer
set search_path = ops, pg_temp
as $$
  insert into gcal_events (appointment_id, professional_id, event_id, synced_version)
  values (p_appointment_id, p_professional_id, p_event_id, p_version)
  on conflict (appointment_id) do update
     set professional_id = excluded.professional_id, event_id = excluded.event_id,
         synced_version = excluded.synced_version, synced_at = now()
$$;

create or replace function ops.forget_gcal_event(p_appointment_id uuid)
returns void
language sql
volatile
security definer
set search_path = ops, pg_temp
as $$
  delete from gcal_events where appointment_id = p_appointment_id
$$;

-- -----------------------------------------------------------------------------
-- What to write: one appointment as a calendar event (assistant role, RLS).
-- Same title rule as the iCalendar feed: first name — service (Azerbaijani).
-- -----------------------------------------------------------------------------
create or replace function core.calendar_event_for(p_appointment_id uuid)
returns table (
  appointment_id   uuid,
  professional_id  uuid,
  version          int,
  active           boolean,
  tentative        boolean,
  starts_at        timestamptz,
  ends_at          timestamptz,
  summary          text,
  timezone         text
)
language sql
stable
security invoker
set search_path = core, pg_temp
as $$
  select a.id, a.professional_id, a.version,
         is_active_status(a.status),
         a.status = 'pending_approval',
         a.start_at, a.end_at,
         coalesce(nullif(split_part(btrim(p.display_name), ' ', 1), '') || ' — ', '') || s.name_az,
         c.timezone
    from appointments a
    join patients p on p.id = a.patient_id
    join services s on s.id = a.service_id
    join clinics  c on c.id = a.clinic_id
   where a.id = p_appointment_id
$$;

-- -----------------------------------------------------------------------------
-- Trigger: any change that affects the calendar queues a sync — only when the
-- dentist has a Google link or the appointment was synced before.
-- One job per appointment version (the worker always writes the latest state).
-- -----------------------------------------------------------------------------
create or replace function ops.on_appointment_calendar_change()
returns trigger
language plpgsql
security definer
set search_path = ops, core, pg_temp
as $$
begin
  if exists (select 1 from google_calendar_links where professional_id = new.professional_id)
     or exists (select 1 from gcal_events where appointment_id = new.id) then
    perform enqueue_job('gcal_sync', new.clinic_id,
                        jsonb_build_object('appointment_id', new.id),
                        'gcal:' || new.id || ':' || new.version);
  end if;
  return null;
end
$$;

create trigger calendar_sync after insert or update of status, start_at, end_at, professional_id
  on core.appointments
  for each row execute function ops.on_appointment_calendar_change();

-- -----------------------------------------------------------------------------
-- RLS and grants
-- -----------------------------------------------------------------------------
alter table ops.google_calendar_links enable row level security;
alter table ops.gcal_events           enable row level security;   -- functions only

create policy staff_read_links on ops.google_calendar_links
  for select to authenticated
  using (clinic_id in (select ops.my_clinic_ids()));

-- Staff see link status, never the secret id.
grant select (professional_id, clinic_id, google_email, calendar_id, status, last_error, connected_at)
  on ops.google_calendar_links to authenticated;

grant execute on function
  ops.save_google_link(uuid, text, text, uuid),
  ops.google_link_for(uuid),
  ops.mark_google_link_broken(uuid, text),
  ops.gcal_event_for(uuid),
  ops.record_gcal_event(uuid, uuid, text, int),
  ops.forget_gcal_event(uuid),
  core.calendar_event_for(uuid)
to dentpilot_agent;
