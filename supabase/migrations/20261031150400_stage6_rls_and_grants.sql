-- =============================================================================
-- Stage 6 · Migration 5 of 6 — Row-level security and grants
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 1. kb_entries
--    Assistant: read only, and only approved + active entries.
--    Staff: read and write everything for their clinic (Q14: all may approve).
-- -----------------------------------------------------------------------------
alter table core.kb_entries enable row level security;
alter table core.kb_entries force row level security;

create policy agent_approved_entries on core.kb_entries
  for select to dentpilot_agent
  using (clinic_id = core.current_clinic_id() and active and approved_at is not null);

create policy staff_own_clinics on core.kb_entries
  for all to authenticated
  using      (clinic_id in (select ops.my_clinic_ids()))
  with check (clinic_id in (select ops.my_clinic_ids()));

grant select on core.kb_entries to dentpilot_agent;
grant execute on function core.kb_for_prompt(text) to dentpilot_agent, authenticated;

grant select, insert on core.kb_entries to authenticated;
grant update (language, topic, question, alt_questions, answer, active, sort_order, approved_by, approved_at)
  on core.kb_entries to authenticated;
grant execute on function core.approve_kb_entry(uuid, int) to authenticated;

-- -----------------------------------------------------------------------------
-- 2. calendar_feeds — staff see feeds of their clinic (never the token: only
--    its hash is stored); all changes go through the functions.
-- -----------------------------------------------------------------------------
alter table ops.calendar_feeds enable row level security;

create policy staff_read_feeds on ops.calendar_feeds
  for select to authenticated
  using (clinic_id in (select ops.my_clinic_ids()));

grant select (id, clinic_id, professional_id, created_by, created_at, revoked_at, last_accessed_at)
  on ops.calendar_feeds to authenticated;
grant execute on function
  ops.create_calendar_feed(uuid),
  ops.revoke_calendar_feed(uuid)
to authenticated;

grant execute on function core.calendar_feed_events(text) to dentpilot_agent;

-- -----------------------------------------------------------------------------
-- 3. service_role and PUBLIC
-- -----------------------------------------------------------------------------
grant select, insert, update, delete on all tables    in schema core, ops to service_role;
grant execute                        on all functions in schema core, ops to service_role;

revoke execute on all functions in schema core, clinical, ops from public;
