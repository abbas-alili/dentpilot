-- =============================================================================
-- Stage 6 · Migration 3 of 6 — FAQ knowledge base
--
-- Approved answers the assistant may send WORD FOR WORD (hours, address,
-- price ranges, preparation, payment…). Decision Q14: any staff member may
-- approve. Rules:
--   • The assistant sees only entries that are approved AND active.
--   • Changing the question or answer of an approved entry withdraws the
--     approval automatically — unreviewed text can never reach a patient.
--   • Approval records who approved and when (and is audited).
--
-- At pilot scale the assistant puts all approved entries of the patient's
-- language in its prompt (core.kb_for_prompt). Embeddings are added in a
-- later migration once the embedding model is chosen on the Azerbaijani
-- eval set — the vector size depends on that choice.
-- =============================================================================

create extension if not exists pg_trgm with schema extensions;

create table core.kb_entries (
  id             uuid        primary key default gen_random_uuid(),
  clinic_id      uuid        not null references core.clinics (id),
  language       text        not null check (language in ('az', 'ru')),
  topic          text        not null check (topic in (
                   'hours', 'location', 'contact', 'services', 'price_range',
                   'preparation', 'payment', 'policy', 'other')),
  question       text        not null check (btrim(question) <> ''),
  alt_questions  text[]      not null default '{}',     -- other ways patients ask it
  answer         text        not null check (btrim(answer) <> ''),
  approved_by    uuid        references auth.users (id),
  approved_at    timestamptz,
  active         boolean     not null default true,
  sort_order     int         not null default 0,
  version        int         not null default 1,
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now(),

  constraint kb_entries_approval_pair check ((approved_by is null) = (approved_at is null))
);

create index kb_entries_prompt_idx on core.kb_entries (clinic_id, language, sort_order)
  where active and approved_at is not null;
create index kb_entries_question_trgm on core.kb_entries using gin (question extensions.gin_trgm_ops);

-- Editing the text of an approved entry withdraws its approval.
create or replace function core.kb_entries_reset_approval()
returns trigger
language plpgsql
as $$
begin
  if (new.question, new.answer, new.alt_questions, new.language)
       is distinct from (old.question, old.answer, old.alt_questions, old.language)
     and new.approved_at is not distinct from old.approved_at then
    new.approved_by := null;
    new.approved_at := null;
  end if;
  return new;
end
$$;

create trigger reset_approval before update on core.kb_entries for each row execute function core.kb_entries_reset_approval();
create trigger bump_version   before update on core.kb_entries for each row execute function core.bump_version();
create trigger set_updated_at before update on core.kb_entries for each row execute function core.set_updated_at();
create trigger audit after insert or update or delete on core.kb_entries for each row execute function ops.audit_row();

-- -----------------------------------------------------------------------------
-- Staff: approve an entry as the signed-in user (optimistic version check, so
-- you approve exactly the text you reviewed).
-- -----------------------------------------------------------------------------
create or replace function core.approve_kb_entry(p_entry_id uuid, p_expected_version int)
returns boolean
language plpgsql
volatile
security invoker
set search_path = core, pg_temp
as $$
begin
  update kb_entries
     set approved_by = auth.uid(), approved_at = now()
   where id = p_entry_id and version = p_expected_version;
  return found;
end
$$;

-- -----------------------------------------------------------------------------
-- Assistant: every approved, active entry for one language, for the prompt.
-- -----------------------------------------------------------------------------
create or replace function core.kb_for_prompt(p_language text)
returns table (id uuid, topic text, question text, alt_questions text[], answer text)
language sql
stable
security invoker
set search_path = core, pg_temp
as $$
  select e.id, e.topic, e.question, e.alt_questions, e.answer
    from kb_entries e
   where e.language = p_language and e.active and e.approved_at is not null
   order by e.sort_order, e.topic, e.question
$$;
