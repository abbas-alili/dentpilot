-- =============================================================================
-- Stage 1 · Migration 1 of 3 — Foundation
-- Schemas, the assistant's database role, privilege defaults, and the shared
-- helper functions every later table uses (tenant context, updated_at, audit).
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 1. Schemas
--    core      operational data the assistant may see (scoped by RLS)
--    clinical  treatment log + internal prices — the assistant can NEVER see it
--    ops       staff membership, background jobs, audit trail
-- -----------------------------------------------------------------------------
create schema if not exists core;
create schema if not exists clinical;
create schema if not exists ops;

comment on schema core     is 'Operational data. Readable by dentpilot_agent, scoped by RLS to one clinic.';
comment on schema clinical is 'Treatment log and internal prices. Staff only. dentpilot_agent has no access.';
comment on schema ops      is 'Staff membership, background jobs, audit trail.';

-- -----------------------------------------------------------------------------
-- 2. The assistant's role
--    Edge Functions that run the assistant connect as this role, never as
--    service_role (which bypasses RLS and can read every schema).
--    The password is set outside migrations — see SOP.md, "Secrets".
-- -----------------------------------------------------------------------------
do $$
begin
  if not exists (select 1 from pg_roles where rolname = 'dentpilot_agent') then
    create role dentpilot_agent login noinherit nosuperuser nobypassrls nocreatedb nocreaterole;
  end if;
end
$$;

comment on role dentpilot_agent is 'DentPilot assistant (process-message, flow-endpoint). No access to schema clinical.';

-- -----------------------------------------------------------------------------
-- 3. Privilege baseline
--    Nobody gets anything on these schemas unless a migration grants it.
--    Note: Postgres lets PUBLIC execute every new function by default, and a
--    per-schema ALTER DEFAULT PRIVILEGES cannot remove that. So every stage's
--    grants migration ends with an explicit REVOKE ... FROM PUBLIC on all
--    functions in our schemas, and a test checks it.
-- -----------------------------------------------------------------------------
revoke all on schema core, clinical, ops from public;

-- -----------------------------------------------------------------------------
-- 4. Tenant context
--    The assistant sets the clinic it is working for at the start of every
--    transaction:   select set_config('app.clinic_id', '<uuid>', true);
--    RLS policies for dentpilot_agent compare rows against this value.
--    Not set  →  null  →  every policy evaluates false  →  no rows.
-- -----------------------------------------------------------------------------
create or replace function core.current_clinic_id()
returns uuid
language sql
stable
as $$
  select nullif(current_setting('app.clinic_id', true), '')::uuid
$$;

comment on function core.current_clinic_id() is
  'Clinic the current transaction acts for (app.clinic_id). Null when unset.';

-- -----------------------------------------------------------------------------
-- 5. updated_at maintenance
-- -----------------------------------------------------------------------------
create or replace function core.set_updated_at()
returns trigger
language plpgsql
as $$
begin
  new.updated_at := now();
  return new;
end
$$;

-- -----------------------------------------------------------------------------
-- 6. Audit trail (append-only)
--    Every audited table gets the ops.audit_row() trigger. Each insert, update
--    and delete writes one row with the full before/after images.
--    Actor, in order of preference:
--      app.actor setting  ('assistant' or 'system', set by server code)
--      auth.uid()         (a signed-in staff member, via Supabase Auth)
--      current_user       (anything else, e.g. a migration or the SQL editor)
-- -----------------------------------------------------------------------------
create table ops.audit_events (
  id          bigint generated always as identity primary key,  -- internal, never exposed
  clinic_id   uuid,
  actor       text        not null,
  action      text        not null check (action in ('INSERT', 'UPDATE', 'DELETE')),
  entity      text        not null,                              -- 'schema.table'
  entity_id   uuid,
  before      jsonb,
  after       jsonb,
  created_at  timestamptz not null default now()
);

create index audit_events_entity_idx on ops.audit_events (entity, entity_id, created_at desc);
create index audit_events_clinic_idx on ops.audit_events (clinic_id, created_at desc);

comment on table ops.audit_events is 'Append-only change log. No role is granted update or delete.';

create or replace function ops.audit_row()
returns trigger
language plpgsql
security definer                      -- writes to ops.audit_events on behalf of any role
set search_path = ops, pg_temp
as $$
declare
  v_row       jsonb := to_jsonb(coalesce(new, old));
  v_clinic_id uuid;
  v_actor     text;
begin
  -- core.clinics is the tenant itself: its own id is the clinic id.
  if tg_table_schema = 'core' and tg_table_name = 'clinics' then
    v_clinic_id := (v_row ->> 'id')::uuid;
  else
    v_clinic_id := (v_row ->> 'clinic_id')::uuid;
  end if;

  v_actor := coalesce(
    nullif(current_setting('app.actor', true), ''),
    auth.uid()::text,
    session_user::text   -- the login role; unaffected by SECURITY DEFINER
  );

  insert into ops.audit_events (clinic_id, actor, action, entity, entity_id, before, after)
  values (
    v_clinic_id,
    v_actor,
    tg_op,
    tg_table_schema || '.' || tg_table_name,
    (v_row ->> 'id')::uuid,
    case when tg_op in ('UPDATE', 'DELETE') then to_jsonb(old) end,
    case when tg_op in ('INSERT', 'UPDATE') then to_jsonb(new) end
  );

  return null;   -- AFTER trigger: return value is ignored
end
$$;

comment on function ops.audit_row() is
  'AFTER row trigger. Writes before/after images to ops.audit_events.';
