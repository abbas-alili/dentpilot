-- =============================================================================
-- Stage 6 · Migration 6 of 6 — Hourly schedule
--   dentpilot-hourly  at :05 every hour   close idle conversations
-- Skips itself where pg_cron is not available (local test databases).
-- =============================================================================

do $migration$
begin
  if not exists (select 1 from pg_extension where extname = 'pg_cron') then
    raise notice 'pg_cron not installed: hourly schedule not created (expected on local test databases)';
    return;
  end if;

  execute $sql$
    select cron.schedule('dentpilot-hourly', '5 * * * *', $job$ select ops.close_idle_conversations(); $job$)
  $sql$;
end
$migration$;
