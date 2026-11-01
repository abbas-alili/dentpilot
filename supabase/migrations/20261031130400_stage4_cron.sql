-- =============================================================================
-- Stage 4 · Migration 5 of 5 — Scheduled work (pg_cron + pg_net)
--
--   dentpilot-tick     every minute   re-queue unprocessed inbound messages,
--                                     then wake the run-jobs Edge Function
--   dentpilot-nightly  23:00 UTC      (03:00 Baku) retention purge + cleanup
--
-- Secrets live in Supabase Vault, never in this file. Create them once per
-- project (SOP.md §5, "Secrets"):
--   dentpilot_run_jobs_url    https://<ref>.supabase.co/functions/v1/run-jobs
--   dentpilot_cron_secret     random string; run-jobs rejects calls without it
--
-- On databases without pg_cron/pg_net (local plain Postgres) this migration
-- only prints a notice, so the rest of the schema can still be tested.
-- =============================================================================

do $migration$
begin
  if not exists (select 1 from pg_available_extensions where name = 'pg_cron')
     or not exists (select 1 from pg_available_extensions where name = 'pg_net') then
    raise notice 'pg_cron/pg_net not available: schedules not created (expected on local test databases)';
    return;
  end if;

  create extension if not exists pg_cron;
  create extension if not exists pg_net with schema extensions;

  -- cron.schedule(name, …) replaces an existing job of the same name.
  execute $sql$
    select cron.schedule(
      'dentpilot-tick',
      '* * * * *',
      $job$
        select ops.enqueue_stale_messages();
        select net.http_post(
          url     := (select decrypted_secret from vault.decrypted_secrets where name = 'dentpilot_run_jobs_url'),
          headers := jsonb_build_object(
                       'Content-Type',  'application/json',
                       'Authorization', 'Bearer ' || (select decrypted_secret from vault.decrypted_secrets
                                                       where name = 'dentpilot_cron_secret')),
          body    := '{}'::jsonb
        );
      $job$
    )
  $sql$;

  execute $sql$
    select cron.schedule(
      'dentpilot-nightly',
      '0 23 * * *',
      $job$
        select core.purge_message_bodies();
        select core.purge_expired_flow_tokens();
        select ops.cleanup_jobs(30);
        select ops.cleanup_notifications(90);
      $job$
    )
  $sql$;
end
$migration$;
