-- =============================================================================
-- Grants for the 2026-11-02 changes (shadow mode, approval, Google Calendar)
-- =============================================================================

-- queue_outbound_message has a new signature (payload added).
grant execute on function core.queue_outbound_message(uuid, text, text, text, text, text, jsonb)
  to dentpilot_agent, authenticated;

-- Staff review drafts; approve bookings with a real duration.
grant execute on function
  core.approve_draft(uuid, text),
  core.discard_draft(uuid),
  core.approve_appointment(uuid, int, int)
to authenticated;

grant select, insert, update, delete on all tables    in schema core, ops to service_role;
grant execute                        on all functions in schema core, ops to service_role;

revoke execute on all functions in schema core, clinical, ops from public;
