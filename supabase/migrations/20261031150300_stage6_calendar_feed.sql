-- =============================================================================
-- Stage 6 · Migration 4 of 6 — iPhone calendar feed (webcal)
--
-- Each dentist subscribes once to   webcal://<host>/functions/v1/calendar-feed/<token>.ics
-- The calendar-feed Edge Function (as dentpilot_agent) calls
-- core.calendar_feed_events(token) and renders iCalendar.
--
--   • Token: 64 random hex chars, shown ONCE at creation; only its SHA-256 is
--     stored. Revocable. One dentist per feed.
--   • Events: that dentist's active appointments, 7 days back to 60 ahead.
--     Title = patient first name + service (decision Q13). pending_approval
--     is returned as tentative. End = chair time (buffer not shown).
--   • UID = appointment id, SEQUENCE = version, so edits update the event.
--   • iOS refreshes subscribed calendars on its own schedule; it is not a
--     real-time view.
-- =============================================================================

create table ops.calendar_feeds (
  id                uuid        primary key default gen_random_uuid(),
  clinic_id         uuid        not null references core.clinics (id),
  professional_id   uuid        not null,
  token_sha256      text        not null unique check (token_sha256 ~ '^[0-9a-f]{64}$'),
  created_by        uuid        references auth.users (id),
  created_at        timestamptz not null default now(),
  revoked_at        timestamptz,
  last_accessed_at  timestamptz,

  foreign key (clinic_id, professional_id) references core.professionals (clinic_id, id)
);

create index calendar_feeds_professional_idx on ops.calendar_feeds (professional_id) where revoked_at is null;

create trigger audit after insert or update or delete on ops.calendar_feeds
  for each row execute function ops.audit_row();

create or replace function ops.sha256_hex(p_text text)
returns text
language sql
immutable
as $$
  select encode(sha256(convert_to(p_text, 'UTF8')), 'hex')
$$;

-- -----------------------------------------------------------------------------
-- Create a feed. A dentist may create one for themself; an admin for any
-- dentist of the clinic. Returns the token — the only time it is visible.
-- -----------------------------------------------------------------------------
create or replace function ops.create_calendar_feed(p_professional_id uuid)
returns text
language plpgsql
volatile
security definer
set search_path = ops, core, pg_temp
as $$
declare
  v_clinic_id uuid;
  v_token     text := replace(gen_random_uuid()::text, '-', '') || replace(gen_random_uuid()::text, '-', '');
begin
  select clinic_id into v_clinic_id from core.professionals where id = p_professional_id;

  if v_clinic_id is null
     or not (has_clinic_role(v_clinic_id, array['admin'])
             or my_professional_id(v_clinic_id) = p_professional_id) then
    raise exception 'not allowed to create a calendar feed for this dentist'
      using errcode = 'insufficient_privilege';
  end if;

  insert into calendar_feeds (clinic_id, professional_id, token_sha256, created_by)
  values (v_clinic_id, p_professional_id, sha256_hex(v_token), auth.uid());

  return v_token;
end
$$;

create or replace function ops.revoke_calendar_feed(p_feed_id uuid)
returns boolean
language plpgsql
volatile
security definer
set search_path = ops, pg_temp
as $$
begin
  update calendar_feeds f
     set revoked_at = now()
   where f.id = p_feed_id
     and f.revoked_at is null
     and (has_clinic_role(f.clinic_id, array['admin'])
          or my_professional_id(f.clinic_id) = f.professional_id);
  return found;
end
$$;

-- -----------------------------------------------------------------------------
-- The feed itself. SECURITY DEFINER: the token alone identifies clinic and
-- dentist (like the other tenant resolvers). Unknown or revoked → no rows.
-- -----------------------------------------------------------------------------
create or replace function core.calendar_feed_events(p_token text)
returns table (
  uid            uuid,
  sequence       int,
  starts_at      timestamptz,
  ends_at        timestamptz,
  summary        text,
  tentative      boolean,
  last_modified  timestamptz,
  timezone       text
)
language plpgsql
volatile
security definer
set search_path = core, ops, pg_temp
as $$
declare
  v_feed ops.calendar_feeds%rowtype;
begin
  select * into v_feed
    from ops.calendar_feeds
   where token_sha256 = ops.sha256_hex(p_token) and revoked_at is null;
  if not found then
    return;
  end if;

  update ops.calendar_feeds set last_accessed_at = now() where id = v_feed.id;

  return query
    select a.id,
           a.version,
           a.start_at,
           a.end_at,
           coalesce(nullif(split_part(btrim(p.display_name), ' ', 1), '') || ' — ', '') || s.name_az,
           a.status = 'pending_approval',
           a.updated_at,
           c.timezone
      from core.appointments a
      join core.patients p on p.id = a.patient_id
      join core.services s on s.id = a.service_id
      join core.clinics  c on c.id = a.clinic_id
     where a.professional_id = v_feed.professional_id
       and is_active_status(a.status)
       and a.start_at >= now() - interval '7 days'
       and a.start_at <  now() + interval '60 days'
     order by a.start_at;
end
$$;
