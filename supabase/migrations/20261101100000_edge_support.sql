-- =============================================================================
-- Edge support — small database additions the Edge Functions need
--
-- 1. Processing claim. The webhook processes a message right away and the
--    minute reconciler re-queues anything unfinished. Without a claim, both
--    could handle the same message and the patient would get two replies.
--    claim_message_for_processing() takes a short lease; a second caller
--    gets false and stops. A crashed worker's lease expires (2 min) and the
--    reconciler picks the message up again.
--
-- 2. Resend after a definite failure. An outbound row marked 'failed' (Meta
--    rejected it) may be sent again by a retried job; mark_outbound_sent now
--    accepts 'failed' as well as 'pending'.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 1. Processing claim
-- -----------------------------------------------------------------------------
alter table core.messages
  add column processing_started_at timestamptz;

comment on column core.messages.processing_started_at is
  'Lease taken by claim_message_for_processing; expires after 2 minutes.';

create or replace function core.claim_message_for_processing(
  p_message_id     uuid,
  p_lease_seconds  int default 120
)
returns boolean
language plpgsql
volatile
security invoker
set search_path = core, pg_temp
as $$
begin
  update messages
     set processing_started_at = now(),
         process_attempts      = process_attempts + 1
   where id = p_message_id
     and direction = 'in'
     and processed_at is null
     and (processing_started_at is null
          or processing_started_at < now() - make_interval(secs => p_lease_seconds));
  return found;
end
$$;

-- Finish: the claim already counted the attempt.
create or replace function core.mark_message_processed(p_message_id uuid)
returns boolean
language plpgsql
volatile
security invoker
set search_path = core, pg_temp
as $$
begin
  update messages
     set processed_at = now(), processing_started_at = null
   where id = p_message_id and direction = 'in' and processed_at is null;
  return found;
end
$$;

-- Give up this attempt: release the lease so a retry can claim at once.
create or replace function core.mark_message_attempt_failed(p_message_id uuid)
returns int
language sql
volatile
security invoker
set search_path = core, pg_temp
as $$
  update messages
     set processing_started_at = null
   where id = p_message_id and direction = 'in' and processed_at is null
  returning process_attempts
$$;

-- Reconciler: also skip messages someone is processing right now.
create or replace function ops.enqueue_stale_messages(
  p_min_age       interval default '1 minute',
  p_max_attempts  int      default 5
)
returns int
language plpgsql
volatile
security definer
set search_path = ops, core, pg_temp
as $$
declare
  v_message record;
  v_count   int := 0;
begin
  for v_message in
    select m.id, m.clinic_id
      from core.messages m
     where m.direction = 'in'
       and m.processed_at is null
       and m.process_attempts < p_max_attempts
       and m.created_at < now() - p_min_age
       and (m.processing_started_at is null or m.processing_started_at < now() - interval '2 minutes')
       and not exists (select 1 from background_jobs j where j.idempotency_key = 'process:' || m.id)
     order by m.created_at
     limit 200
  loop
    perform enqueue_job('process_message', v_message.clinic_id,
                        jsonb_build_object('message_id', v_message.id),
                        'process:' || v_message.id);
    v_count := v_count + 1;
  end loop;
  return v_count;
end
$$;

-- -----------------------------------------------------------------------------
-- 2. Resend after a definite failure
-- -----------------------------------------------------------------------------
create or replace function core.mark_outbound_sent(p_message_id uuid, p_wa_message_id text)
returns boolean
language plpgsql
volatile
security invoker
set search_path = core, pg_temp
as $$
begin
  update messages
     set wa_message_id = p_wa_message_id, delivery_status = 'sent', sent_at = now(), delivery_error = null
   where id = p_message_id and direction = 'out' and delivery_status in ('pending', 'failed');
  return found;
end
$$;

-- -----------------------------------------------------------------------------
-- 3. Grants
-- -----------------------------------------------------------------------------
grant update (processing_started_at) on core.messages to dentpilot_agent;
grant execute on function core.claim_message_for_processing(uuid, int) to dentpilot_agent;

grant execute on all functions in schema core, ops to service_role;
revoke execute on all functions in schema core, clinical, ops from public;
