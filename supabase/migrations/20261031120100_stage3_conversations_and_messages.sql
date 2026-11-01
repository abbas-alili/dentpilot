-- =============================================================================
-- Stage 3 · Migration 2 of 4 — Conversations, messages, Flow tokens
--
-- Privacy rule: message text never enters the audit trail. core.messages is
-- NOT audited (it is append-mostly and is itself the record), so purging
-- message text after the retention period leaves no copy behind.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 1. conversations — at most one open conversation per patient
--    status
--      assistant        the bot answers
--      handed_to_staff  a human is handling it; the bot stays silent
--      escalated        urgent (emergency gate or patient asked); staff alerted
--      closed           finished; the next inbound message opens a new one
-- -----------------------------------------------------------------------------
create table core.conversations (
  id                    uuid        primary key default gen_random_uuid(),
  clinic_id             uuid        not null references core.clinics (id),
  patient_id            uuid        not null,
  status                text        not null default 'assistant'
                          check (status in ('assistant', 'handed_to_staff', 'escalated', 'closed')),
  status_reason         text,                           -- e.g. 'emergency:bleeding', 'patient_asked'
  assigned_to           uuid        references auth.users (id),
  last_message_at       timestamptz not null default now(),
  last_human_reply_at   timestamptz,                    -- dentist echo or staff reply
  status_changed_at     timestamptz not null default now(),
  version               int         not null default 1,
  created_at            timestamptz not null default now(),
  updated_at            timestamptz not null default now(),

  unique (clinic_id, id),
  foreign key (clinic_id, patient_id) references core.patients (clinic_id, id)
);

create unique index conversations_one_open_idx on core.conversations (patient_id) where status <> 'closed';
create index conversations_inbox_idx on core.conversations (clinic_id, status, last_message_at desc);

-- Allowed status changes. Staff may set any status; closed is final.
create or replace function core.conversations_guard_status()
returns trigger
language plpgsql
as $$
begin
  if new.status is not distinct from old.status then
    return new;
  end if;

  if old.status = 'closed' then
    raise exception 'a closed conversation cannot be reopened' using errcode = 'check_violation';
  end if;

  -- The assistant may escalate from anywhere, or hand over a conversation it
  -- owns. It can never take a conversation back or de-escalate it.
  if current_user = 'dentpilot_agent'
     and not (new.status = 'escalated'
              or (old.status = 'assistant' and new.status = 'handed_to_staff')) then
    raise exception 'the assistant cannot move a conversation from % to %', old.status, new.status
      using errcode = 'insufficient_privilege';
  end if;

  new.status_changed_at := now();
  return new;
end
$$;

create trigger guard_status   before update on core.conversations for each row execute function core.conversations_guard_status();
create trigger bump_version   before update on core.conversations for each row execute function core.bump_version();
create trigger set_updated_at before update on core.conversations for each row execute function core.set_updated_at();
create trigger audit after insert or update or delete on core.conversations for each row execute function ops.audit_row();

-- -----------------------------------------------------------------------------
-- 2. messages — every inbound and outbound WhatsApp message
--    Inbound:  wa_message_id is Meta's id (dedup key); processed_at marks
--              that the assistant pipeline has handled it.
--    Outbound: a row is written BEFORE sending (delivery_status 'pending',
--              optional send_key for idempotency), then gets Meta's id.
-- -----------------------------------------------------------------------------
create table core.messages (
  id                      uuid        primary key default gen_random_uuid(),
  clinic_id               uuid        not null references core.clinics (id),
  patient_id              uuid        not null,
  conversation_id         uuid        not null,
  direction               text        not null check (direction in ('in', 'out')),
  source                  text        not null check (source in ('patient', 'assistant', 'doctor_echo', 'staff', 'system')),
  kind                    text        not null check (kind in (
                            'text', 'image', 'audio', 'video', 'document', 'sticker', 'location',
                            'interactive', 'flow_reply', 'template', 'reaction', 'unsupported')),
  body                    text,
  media_id                text,                         -- Meta media id (download later if needed)
  media_mime              text,
  template_name           text,                         -- outbound templates
  reply_to_wa_message_id  text,                         -- WhatsApp "context" (quoted message)
  wa_message_id           text        unique,           -- null only while an outbound is pending
  send_key                text,                         -- outbound idempotency, e.g. 'confirm:<appointment id>'
  delivery_status         text        check (delivery_status in ('pending', 'sent', 'delivered', 'read', 'failed')),
  delivery_error          text,
  sent_at                 timestamptz,                  -- Meta timestamp (in) / send time (out)
  processed_at            timestamptz,                  -- inbound: handled by the pipeline
  process_attempts        int         not null default 0,
  body_purged_at          timestamptz,                  -- retention purge ran
  created_at              timestamptz not null default now(),

  unique (clinic_id, send_key),
  foreign key (clinic_id, patient_id)      references core.patients      (clinic_id, id),
  foreign key (clinic_id, conversation_id) references core.conversations (clinic_id, id),

  constraint messages_inbound_shape check (
    direction <> 'in'
    or (source = 'patient' and wa_message_id is not null and delivery_status is null and send_key is null)),
  constraint messages_outbound_shape check (
    direction <> 'out'
    or (source <> 'patient' and delivery_status is not null))
);

create index messages_conversation_idx on core.messages (conversation_id, created_at);
create index messages_unprocessed_idx  on core.messages (created_at) where direction = 'in' and processed_at is null;
create index messages_purge_idx        on core.messages (clinic_id, created_at) where body_purged_at is null;

-- -----------------------------------------------------------------------------
-- 3. flow_tokens — opaque token sent with a WhatsApp Flow button.
--    The Flow endpoint receives only this token; it identifies clinic,
--    patient, language and purpose. 64 random hex characters, expires.
-- -----------------------------------------------------------------------------
create table core.flow_tokens (
  token           text        primary key
                    default replace(gen_random_uuid()::text, '-', '') || replace(gen_random_uuid()::text, '-', ''),
  clinic_id       uuid        not null references core.clinics (id),
  patient_id      uuid        not null,
  language        text        not null check (language in ('az', 'ru')),
  purpose         text        not null check (purpose in ('book', 'reschedule')),
  appointment_id  uuid,                                  -- the one being rescheduled
  expires_at      timestamptz not null default now() + interval '24 hours',
  created_at      timestamptz not null default now(),

  foreign key (clinic_id, patient_id)     references core.patients     (clinic_id, id),
  foreign key (clinic_id, appointment_id) references core.appointments (clinic_id, id),
  constraint flow_tokens_purpose_shape check ((purpose = 'reschedule') = (appointment_id is not null))
);

create index flow_tokens_expiry_idx on core.flow_tokens (expires_at);
