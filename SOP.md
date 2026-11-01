# DentPilot Database — SOP & Build Log

Standard operating procedure for building and changing the DentPilot database, plus a
running log of every stage. **Update this file in the same change as any migration.**

| | |
|---|---|
| Platform | Supabase (Postgres 15+), migrations via Supabase CLI |
| Current stage | **Staff web app — Step 2 (the app) complete.** Database: 298/298 pgTAP + 2 race tests. Functions: 26 tests (23-step journey). Web app: 35 tests + type-check + production build |
| Next | Deploy and test-drive with the clinic; then Step 3 (staff booking by phone, live updates) |
| Last updated | 2026-10-31 |

---

## 1. Project layout

```
dentpilot-db/
├── SOP.md                         ← this file
├── web/                           ← staff web app (React + TypeScript, Vite) → Cloudflare Pages
│   ├── src/lib/                   ← api.ts (every DB call), i18n.tsx (az/ru/en), format, push, polling
│   ├── src/pages/ src/components/ ← Inbox, Bookings, Conversations, Today, Settings, Login
│   ├── src/test/                  ← contract test (app ↔ SQL), library and screen tests
│   └── public/                    ← sw.js (push), manifest, _redirects, _headers
├── supabase/
│   ├── migrations/                ← one file per change, applied in name order
│   ├── seed.sql                   ← dev data (loaded by `supabase db reset` only)
│   ├── tests/                     ← pgTAP tests, one file per stage
│   ├── flows/                     ← booking Flow JSON (az, ru) to publish in WhatsApp Manager
│   └── functions/
│       ├── _shared/               ← db, crypto, WhatsApp client, pipeline, texts, gate, ICS, push
│       ├── whatsapp-webhook/      ← handler.ts (logic) + index.ts (entry point)
│       ├── flow-endpoint/
│       ├── run-jobs/
│       ├── calendar-feed/
│       ├── process-message/       ← manual re-run endpoint
│       ├── google-oauth/          ← connect a dentist's Google Calendar
│       └── tests/                 ← Deno unit + end-to-end tests, router_eval.ts + evals/ (bake-off)
└── scripts/
    ├── test_local.sh              ← run everything on plain Postgres (no Docker)
    ├── concurrency_test.sh        ← two real sessions racing for one slot
    ├── test_edge.sh               ← Edge Function type-check, lint, unit + end-to-end tests
    └── supabase_stubs.sql         ← fake Supabase roles/auth for local tests ONLY
```

## 2. How to run

**With the Supabase CLI (preferred):**
```bash
supabase start                 # local stack (Docker)
supabase db reset              # apply all migrations + seed.sql
supabase test db               # run supabase/tests/*.sql
```

**Without Docker** (plain Postgres 15+, pgTAP, pg_prove, run as superuser):
```bash
scripts/test_local.sh          # recreates DB "dentpilot_local", migrates, seeds, tests, race test
```
With the Supabase CLI, run the race test against the local stack's database:
`scripts/concurrency_test.sh postgres` (connection settings via the usual `PG*` variables).

**Deploying to the hosted project:**
```bash
supabase link --project-ref <ref>
supabase db push               # applies new migrations only
```
Then do the one-time manual steps in §5 (“Secrets”) if they haven't been done.

## 3. Rules for every change (the SOP)

1. **New migration, never edit an applied one.** `supabase migration new <stageN_short_name>`.
   Fixing a mistake in an applied migration means writing a new migration that corrects it.
2. **Every tenant table gets:** `clinic_id`, a `unique (clinic_id, id)`, composite FKs to
   other tenant tables, `created_at`/`updated_at`, the `set_updated_at` and `audit` triggers,
   RLS enabled + forced, an `agent_own_clinic` policy and a `staff_own_clinics` policy.
3. **Enum-like columns** use `CHECK (col in (...))`. **Time ranges** use `CHECK (end > start)`.
4. **Grants are explicit and minimal.** The grants migration of each stage ends with
   `revoke execute on all functions in schema core, clinical, ops from public;`.
5. **Schema `clinical`:** staff (authenticated) only. Never granted to `dentpilot_agent`
   or `service_role`.
6. **Tests in the same change.** Add pgTAP tests for each new constraint, policy, grant and
   function, including at least one test run as `dentpilot_agent` and one as `authenticated`.
7. **Log it here:** add a stage entry (§6) and a row in the change log (§9).
8. **Clean code:** a header block on every migration saying what and why; one section per
   object; comments explain *why*, not *what*; lowercase SQL; aligned columns.

## 4. Conventions

| Topic | Rule |
|---|---|
| Keys | `uuid` PKs via `gen_random_uuid()`. No sequential ids in anything a patient can see. |
| Time | `timestamptz` everywhere. Clinic local time (`Asia/Baku`, UTC+4, no DST) only at the edges. |
| Names | snake_case; tables plural; policies `agent_own_clinic` / `staff_own_clinics`. |
| Languages | Patient-facing labels as `name_az` / `name_ru` columns. |
| Deletes | Agent never deletes. Business rows are cancelled/deactivated, not removed. |
| Audit | `ops.audit_row()` trigger; actor = `app.actor` → `auth.uid()` → login role. **Never on `core.messages`**, so message text can't survive the retention purge inside the audit trail. |
| Errors | Use standard SQLSTATEs; project-specific ones are listed in §5a. |

## 5. Roles, connections and secrets

| Role | Used by | Sees | Notes |
|---|---|---|---|
| `dentpilot_agent` | `whatsapp-webhook`, `process-message`, `flow-endpoint`, `run-jobs` Edge Functions | `core`, one clinic at a time (RLS); queue only via `ops` functions | Never `service_role`. Must set `app.clinic_id` and `app.actor` per transaction. |
| `authenticated` | Staff web app (Supabase Auth) | `core` for clinics listed in `ops.staff`; `clinical` per role (dentists: read their patients' records, write only their own) | Staff in exactly one clinic needn't set `app.clinic_id`; staff in several must. |
| `service_role` | Onboarding, operator tooling | `core`, `ops`, all rows | No grants on `clinical`. Cron jobs run as `postgres` inside the database. |
| `anon` | — | nothing | |

**Agent transaction pattern** (Edge Function, postgres.js):
```ts
await sql.begin(async (tx) => {
  await tx`select set_config('app.clinic_id', ${clinicId}, true),
                  set_config('app.actor', 'assistant', true)`;
  // … queries / function calls for this clinic only …
});
```

**Secrets — one-time manual steps on the hosted project (not in migrations):**
1. Set the agent's password in the SQL editor:
   `alter role dentpilot_agent password '<generated 32+ chars>';`
2. Store the connection string as an Edge Function secret (`DENTPILOT_AGENT_DB_URL`).
   Use the pooler in transaction mode. With Supavisor, the username has the form
   `dentpilot_agent.<project-ref>`. **Verify** this on the dashboard's Connect panel
   before relying on it.
3. Never commit the password; rotate it by repeating step 1 and updating the secret.
4. Vault secrets for cron (Stage 4), in the SQL editor:
   `select vault.create_secret('https://<ref>.supabase.co/functions/v1/run-jobs', 'dentpilot_run_jobs_url');`
   `select vault.create_secret('<random 32+ chars>', 'dentpilot_cron_secret');`
   Store the same cron secret as the Edge Function secret `DENTPILOT_CRON_SECRET`.
   `run-jobs` must reject any request without it.
5. Web push: generate a VAPID key pair once and store it as Edge Function secrets
   (`VAPID_PUBLIC_KEY`, `VAPID_PRIVATE_KEY`, `VAPID_SUBJECT` = `mailto:` address).
   The public key also goes into the staff web app.
6. Check the schedules exist: `select jobname, schedule from cron.job where jobname like 'dentpilot-%';`
   You should see three: tick, hourly, nightly.
7. Check that `postgres` bypasses RLS. Several `SECURITY DEFINER` functions (tenant
   resolvers, automation triggers, `clinical.is_my_patient`) rely on it:
   `select rolbypassrls from pg_roles where rolname = 'postgres';` must return `true`.
   Supabase sets this by default. Local tests run as a superuser, so this check is
   the only way to confirm it on the real project.

**Known limit:** RLS on the agent stops *mistakes* (forgetting to scope a query). The agent
can still choose any `app.clinic_id`, so it is trusted server code. Resolve the clinic only
from verified inputs (the webhook's `phone_number_id`, a server-stored `flow_token`).

## 5a. Error codes the Edge Functions must handle

| SQLSTATE | Raised by | Meaning → what the bot does |
|---|---|---|
| `DP001` | appointment update by the assistant | Too close to the appointment to cancel/reschedule via the bot → tell the patient to contact the clinic |
| `40001` | `confirm_hold` (reschedule) | Staff changed the appointment meanwhile → re-read and re-offer |
| `23P01` | appointments / holds / schedules | Overlap (should not happen through the functions) → log + staff alert |
| `42501` | many | Role not allowed (e.g. assistant trying to approve) → bug: log + alert |
| `23514` | status guards, CHECKs | Invalid value or status change → bug: log + alert |

## 5b. Webhook and assistant call sequence (all as `dentpilot_agent`)

1. `clinic_for_phone_number(metadata.phone_number_id)`. Null means an unknown number:
   log it and return 200.
2. `set_config('app.clinic_id', …, true)`, `set_config('app.actor', 'assistant', true)`.
3. Per entry: `record_inbound_message(…)` for patient messages, `record_echo_message(…)`
   for `smb_message_echoes`, and `update_delivery_status(…)` for statuses.
4. Return 200. Invoke `process-message` only for rows where `is_duplicate = false`.
5. `process-message`:
   - `assistant_may_reply(conversation)`; if false, stop.
   - Run the emergency gate; on a hit, `set_conversation_status(…, 'escalated', reason)`.
   - Route.
   - `queue_outbound_message(…, p_send_key)` → send only if it returned `pending`.
   - `mark_outbound_sent` or `mark_outbound_failed`.
   - Finish with `mark_message_processed`, or `mark_message_attempt_failed` on error.
6. Before any free-form reply, check `service_window_open(patient)`. Outside the window,
   only approved templates may be sent.
7. Flow endpoint: `clinic_for_flow_token(token)` → set context → `read_flow_token(token)`.

## 5c. Job kinds (what `run-jobs` must do)

`run-jobs` loop: `ops.claim_jobs(...)` → for each job, set `app.clinic_id = job.clinic_id`
and `app.actor = 'assistant'` → handle the job → `ops.complete_job` or
`ops.fail_job(id, error)`.

| Kind | Payload | Handler |
|---|---|---|
| `process_message` | `message_id` | Run the normal `process-message` pipeline for that message. |
| `send_reminder` | `appointment_id`, `offset_minutes` | `core.appointment_message_details(id)`. Skip and complete the job if status isn't `booked`/`confirmed` or the patient has `opted_out`. Otherwise `queue_outbound_message(... p_send_key => 'reminder:' \|\| job.idempotency_key)` → send the approved **template** (with a "confirm" button if `ask_confirmation`) → `mark_outbound_sent`. Reminders go out as templates because they usually fall outside the 24 h window. |
| `notify_patient` | `appointment_id`, `event` (`approved`/`rejected`) | Same details call → queue → send a template, or free text if `window_open`. |
| `approval_reminder` | `appointment_id` | `ops.run_approval_reminder(job.id)`. Database-only work. |
| `push_notification` | `notification_id` | `ops.push_targets(id)` → Web Push to each device. The text is built from `kind`/`detail` in the staff member's language → `ops.record_push_result(sub, ok, gone)`. Complete the job even if some devices failed. |

**Monitoring:** check for dead jobs daily, and alert on any rows:
`select kind, count(*) from ops.background_jobs where status = 'dead' and finished_at > now() - interval '1 day' group by kind;`

## 5d. Edge Functions

**All five connect as `dentpilot_agent`** (pooler, transaction mode, `prepare: false`).
None of them uses `service_role`. Deploy each one with JWT verification **off**: Meta,
iOS calendars and pg_cron can't send a Supabase JWT, so each function authenticates
its caller itself.

| Function | Called by | Authenticates by | Does |
|---|---|---|---|
| `whatsapp-webhook` | Meta | `X-Hub-Signature-256` (app secret) | Records messages/echoes/statuses, answers 200, processes new messages in the background |
| `flow-endpoint` | WhatsApp Flow | Signature + RSA/AES encryption + server-side flow token | INIT / dates / slots / hold for the booking Flow |
| `run-jobs` | pg_cron every minute | `Bearer DENTPILOT_CRON_SECRET` | Works the job queue (§5c) |
| `calendar-feed` | Dentists' iPhones | Unguessable token in the URL | Read-only `.ics` |
| `process-message` | Operator (manual) | Cron secret | Re-process one message |
| `google-oauth` | Staff app (start) / Google (callback) | Staff JWT checked with Supabase Auth / HMAC-signed state | Connect a dentist's Google Calendar |

**Deploy**
```bash
supabase functions deploy whatsapp-webhook --no-verify-jwt
supabase functions deploy flow-endpoint    --no-verify-jwt
supabase functions deploy run-jobs         --no-verify-jwt
supabase functions deploy calendar-feed    --no-verify-jwt
supabase functions deploy process-message  --no-verify-jwt
supabase functions deploy google-oauth     --no-verify-jwt
supabase secrets set DENTPILOT_AGENT_DB_URL=... WA_ACCESS_TOKEN=... WA_APP_SECRET=... \
  WA_VERIFY_TOKEN=... WA_GRAPH_VERSION=v23.0 FLOW_PRIVATE_KEY="$(cat private_pkcs8.pem)" \
  WA_FLOW_ID_AZ=... WA_FLOW_ID_RU=... DENTPILOT_CRON_SECRET=... \
  VAPID_PUBLIC_KEY=... VAPID_PRIVATE_KEY=... VAPID_SUBJECT=mailto:... \
  LLM_PROVIDER=none   # or anthropic | openai | gemini, with LLM_MODEL and LLM_API_KEY (§5f) \
  GOOGLE_CLIENT_ID=... GOOGLE_CLIENT_SECRET=... OAUTH_STATE_SECRET=... STAFF_APP_URL=https://... \
  GOOGLE_REDIRECT_URI=https://<ref>.supabase.co/functions/v1/google-oauth/callback
```
`WA_GRAPH_VERSION` is an example; pin the Graph API version you actually tested with.

**Meta setup (once per clinic number)**
1. Webhook URL `https://<ref>.supabase.co/functions/v1/whatsapp-webhook`, verify token =
   `WA_VERIFY_TOKEN`. Subscribe to `messages` and, for Coexistence, `smb_message_echoes`.
2. Set `core.clinics.wa_phone_number_id` for the clinic. Messages to an unknown number are
   logged and ignored.
3. Flow keys:
   - `openssl genrsa -out private.pem 2048`
   - `openssl rsa -in private.pem -pubout -out public.pem`
   - `openssl pkcs8 -topk8 -nocrypt -in private.pem -out private_pkcs8.pem`
   - Upload `public.pem` to the number's business encryption endpoint, and set
     `FLOW_PRIVATE_KEY` from `private_pkcs8.pem`.
4. Publish `flows/booking-flow.az.json` and `flows/booking-flow.ru.json` with
   endpoint URI `…/functions/v1/flow-endpoint`. Their ids go into `WA_FLOW_ID_AZ` /
   `WA_FLOW_ID_RU`.
5. Create the four message templates below and wait for approval.

**How the deterministic bot behaves (E1)**
- Free text gets the emergency gate first, then the opt-out words
  (`stop`/`dayandır`/`стоп`, `start`/`başla`/`старт`), then language detection. If the
  bot may reply, it sends the menu list: book, reschedule, cancel, hours, address,
  administrator, other language.
- Every menu action, button and Flow completion is deterministic.
- Media goes to staff.
- An emergency gets one safety message, the conversation is escalated, and staff get a
  push. After that the bot stays silent.
- Every reply's send key is `reply:<inbound id>:<n>`, so re-processing never sends a
  reply twice. A message is claimed before processing, so the webhook and the reconciler
  never both answer it.

**Before go-live, verify** (each needs real Meta traffic):
- the `smb_message_echoes` payload shape, in `_shared/webhook_parse.ts`;
- that Meta signs Flow endpoint requests (otherwise set `FLOW_VERIFY_SIGNATURE=false`);
- the Flow error codes 421 / 427 / 432;
- the emergency reply text, which is now the clinic setting `emergency_reply_az` / `emergency_reply_ru` (it says 103).

**Tests:** `scripts/test_edge.sh` builds a fresh database and type-checks and lints all
functions. It then runs the unit tests and the end-to-end journey:
- webhook handshake, signature, menu, duplicate delivery;
- an FAQ answer;
- a full Flow booking (encrypted exactly as Meta does), plus Flow error codes;
- reminder template → confirm-attendance button;
- cancel with confirmation;
- emergency → escalation → staff push → bot silent;
- reconciler pickup;
- cron auth;
- the calendar feed.

## 5f. LLM router (E2)

**Which provider is a setting, not code.** Switching provider means changing secrets and
redeploying nothing.

| Secret | Values |
|---|---|
| `LLM_PROVIDER` | `none` (menu only, E1 behaviour) · `anthropic` · `openai` · `gemini` |
| `LLM_MODEL` | Model id for that provider, chosen by the bake-off below |
| `LLM_API_KEY` | Provider key |
| `LLM_BASE_URL` | Optional. With `openai`, any OpenAI-compatible endpoint (OpenRouter, Mistral, Groq, Together, DeepSeek, self-hosted vLLM/Ollama, …) |
| `LLM_OPENAI_JSON_MODE` | `json_schema` (default) or `json_object` for endpoints without schema support |

**What the router does.** It only *classifies* free text, into one of `book`,
`reschedule`, `cancel`, `confirm_attendance`, `faq` (+ an approved entry id), `opt_out`,
`human_request`, `clinical_question`, `complaint`, `greeting`, `thanks` or `other`. Each
intent runs the same deterministic handler as the matching menu item. **The model never
writes text to a patient**: every reply is a reviewed template, or an approved FAQ answer
sent word for word.

**Safety and fallback:**
- The emergency gate runs before the router; emergencies never reach it.
- The router isn't called while staff are handling a conversation.
- Output is validated strictly: known intent, a FAQ id that was actually offered,
  confidence between 0 and 1. On invalid output there's one retry that includes the
  error; then the patient gets the menu.
- If the provider is down or slow (8 s timeout), the patient gets the menu.
- Below 0.6 confidence, `greeting` and `other` also get the menu (decision E2-3).
- `clinical_question` and `complaint` go to staff ("a dentist will answer"). A clinical
  question is never answered by the bot.

**What the provider receives:** the message, the last six text turns of the conversation,
today's date, the clinic name, service and dentist names, and the approved FAQ questions
(not their answers). It never receives patient names, phone numbers or anything from
`clinical`.

**Prompt caching:** the rules, clinic data and FAQ list form a stable prefix, and the
message comes last. Anthropic gets an explicit `cache_control` marker; OpenAI and Gemini
cache long prefixes automatically.

**Bake-off (decides `LLM_PROVIDER` / `LLM_MODEL`)**
```bash
LLM_PROVIDER=anthropic LLM_MODEL=<model> LLM_API_KEY=<key> \
  deno run -A supabase/functions/tests/router_eval.ts [golden.jsonl]
```
It prints intent accuracy (gate ≥ 92%), per-language accuracy, every miss, failures and
latency. Run it for each candidate and pick the cheapest model that passes in **both**
languages. `tests/evals/router_golden.jsonl` holds **25 draft cases**; replace them with
about 150 real, anonymised clinic messages before deciding. Look up current model names
and prices at bake-off time; they change often.

**Changes vs. the AI skill's router contract.** The contract was simplified on purpose:
- No slot extraction, because the booking Flow collects service, dentist and time.
- `faq_*` topics replaced by one `faq` intent plus an approved entry id, because the
  stored answer is sent verbatim.
- `clinical_question`, `complaint` and `thanks` added.
- `needs_human` dropped; it's expressed by the intent.

## 5g. Google Calendar (one-way, into the dentist's primary calendar)

**Setup (once)**
1. In Google Cloud, create a project, enable the **Google Calendar API**, and configure the
   OAuth consent screen (External).
   - Scopes: `calendar.events`, `openid`, `email`.
2. **Set the publishing status to "In production".** In "Testing", Google expires refresh
   tokens after 7 days, so the calendar would silently disconnect every week.
   - Without Google's verification, users see an "unverified app" warning once when
     connecting. That's acceptable for a handful of dentists.
   - Submit for verification before rolling out to more clinics.
3. Create an OAuth client (Web application) with redirect URI
   `https://<ref>.supabase.co/functions/v1/google-oauth/callback`.
   - Set `GOOGLE_CLIENT_ID`, `GOOGLE_CLIENT_SECRET`, `GOOGLE_REDIRECT_URI` and
     `OAUTH_STATE_SECRET` (random).
4. In the staff app, an admin, or the dentist themself, taps "Connect Google Calendar"
   (`POST google-oauth/start`) and approves in Google.
   - The refresh token is stored in **Supabase Vault**, never in a table.

**Behaviour**
- Every change to a connected dentist's appointment queues a `gcal_sync` job:
  - booked or confirmed → a confirmed event;
  - pending approval → a tentative event;
  - cancelled, rejected, completed or no-show → the event is removed;
  - a change of dentist → the event moves to the new dentist's calendar.
- The event id comes from the appointment id, so retries never duplicate events.
- The title is the same as the feed's: first name — service.
- If Google revokes access (password change, app removed), the link becomes
  `needs_reconnect`, staff get a push, and syncing stops until someone reconnects.
- **One-way.** Editing or deleting the event in Google doesn't change DentPilot; the next
  change in DentPilot overwrites it. Tell the doctors to make changes in DentPilot.
- The iCalendar feed (§5d) stays available as a backup.

## 5e. WhatsApp templates (submit in WhatsApp Manager, category Utility)

DRAFT: needs receptionist review. Variable order must match `META_TEMPLATES` in
`_shared/texts.ts`.

| Name | az | ru | Buttons (quick reply) |
|---|---|---|---|
| `dentpilot_reminder` | Xatırlatma: {{1}} — {{2}}, saat {{3}}, {{4}}. Zəhmət olmasa, gəlişinizi təsdiqləyin. | Напоминание: {{1}} — {{2}}, в {{3}}, {{4}}. Пожалуйста, подтвердите визит. | az: "Gələcəyəm", "Ləğv et" · ru: "Приду", "Отменить" |
| `dentpilot_reminder_plain` | Xatırlatma: {{1}} — {{2}}, saat {{3}}, {{4}}. Sizi gözləyirik! | Напоминание: {{1}} — {{2}}, в {{3}}, {{4}}. Ждём вас! | — |
| `dentpilot_booking_approved` | Həkim randevunuzu təsdiqlədi: {{1}} — {{2}}, saat {{3}}, {{4}}. | Врач подтвердил вашу запись: {{1}} — {{2}}, в {{3}}, {{4}}. | — |
| `dentpilot_booking_rejected` | Təəssüf ki, {{1}}, saat {{2}} üçün randevunu təsdiqləyə bilmədik. Yeni vaxt üçün bizə yazın. | К сожалению, мы не можем подтвердить запись на {{1}}, {{2}}. Напишите нам, чтобы выбрать другое время. | — |

Variables: {{1}} service · {{2}} date ("2 noyabr, bazar ertəsi") · {{3}} time · {{4}} dentist.
The rejected template uses {{1}} date and {{2}} time. Quick-reply payloads are set at send
time (`remind:confirm:<id>`, `remind:cancel:<id>`).

## 5h. Staff web app

**Purpose.** The doctor and staff approve the bot's drafts (shadow mode), approve or reject
bookings, take over conversations, and check the day. Android phones (Chrome) and desktop.

**Screens (minimal version)**
| Screen | What staff do | API |
|---|---|---|
| Inbox (home) | Drafts with the patient message they answer: approve, edit and send, discard | `staff_draft_inbox`, `approve_draft`, `discard_draft` |
| Bookings | Pending requests: approve with a duration (picker capped at time until the next booking), or reject | `staff_pending_bookings`, `approve_appointment`, `reject_appointment` |
| Conversations | "Needs attention" (emergency first) and open threads; read history, reply, hand back to the bot, close | `staff_conversations`, `staff_conversation_messages`, `staff_send_reply`, `set_conversation_status` |
| Today | The day per dentist; mark arrived / done / no-show / cancel | `staff_day_schedule`, `staff_set_appointment_status` |
| Settings | Google Calendar connect, push notifications, clinic settings (admins) | `google-oauth/start`, `register_push_subscription`, `core.clinics` update |
| Badges | Counts on the navigation | `staff_counts`, `my_staff_profile` |

**How the app reaches the data.**
- It uses supabase-js as the signed-in user (role `authenticated`), so RLS applies to
  everything.
- Every screen reads through one `SECURITY INVOKER` function, and writes reuse the
  existing guarded functions.
- **Supabase setting:** under API settings, add `core` and `ops` to the *Exposed
  schemas*. Add `clinical` later, for the treatment log.

**Error codes the app shows in words:**
- `DP002`: outside the 24-hour window, so free text isn't allowed. Templates only.
- `23P01`: that duration overlaps the next booking.
- A version mismatch (the function returns `false`): someone else changed this meanwhile;
  reload.

**Deploy (once)**
1. **Supabase → API settings:** add `core` and `ops` to *Exposed schemas*.
2. **Supabase → Authentication:**
   - **Disable new user signups**, because staff accounts are created by an admin.
   - Site URL = the app's URL; add it to the redirect URLs (used by "forgot password").
   - Use your own SMTP for auth emails before going live. The built-in sender is rate-limited.
3. **Staff accounts.** In Authentication → Users → *Add user* (email + password), then:
   `insert into ops.staff (user_id, clinic_id, role, professional_id) values ('<auth user id>', '<clinic id>', 'dentist', '<professional id>');`
   Use `receptionist` or `admin` without a professional where appropriate.
4. **Cloudflare Pages:** connect the repository.
   - Root directory: `web`; build command: `npm run build`; output: `dist`; Node 20.
   - Environment variables: `VITE_SUPABASE_URL`, `VITE_SUPABASE_ANON_KEY`,
     `VITE_VAPID_PUBLIC_KEY` (the same public key as the Edge Function secret).
   - `_redirects` (SPA routing) and `_headers` (security headers, no cache for `sw.js`)
     are already in `web/public`.
5. **Edge Function secret** `STAFF_APP_URL` = the Pages URL. Google OAuth returns to
   `<app>/settings/calendar`.
6. **On each phone:** open the app in Chrome, use "Add to Home screen", sign in, then
   Settings → turn on notifications. A dentist (or an admin) connects Google Calendar there.

**Local development:** in `web/`, copy `.env.example` to `.env`, then run `npm install`
and `npm run dev`. `npm run check` runs the type-check, tests and build.

**Steps**
1. **API in the database.** ✅ Done (see the stage log).
2. **The app.** Login, Inbox, Bookings, Conversations, Today, Settings, push, PWA. ✅ Done.
3. **Staff booking by phone** (search or create a patient, pick a slot, book), plus
   polish (live updates, treatment log).

## 6. Stage log

### Stage 1 — Foundation ✅ (2026-10-31)

**Migrations**
| File | Contents |
|---|---|
| `20261031100000_stage1_foundation.sql` | Schemas `core`/`clinical`/`ops`; role `dentpilot_agent`; `core.current_clinic_id()`; `core.set_updated_at()`; `ops.audit_events` + `ops.audit_row()` |
| `20261031100100_stage1_core_tables.sql` | `core.clinics`, `core.professionals`, `core.services`, `core.patients`, `ops.staff`, `ops.my_clinic_ids()`, `core.is_valid_timezone()`, triggers |
| `20261031100200_stage1_rls_and_grants.sql` | RLS + policies, grants for agent / staff / service_role, anon and PUBLIC lock-down |

**Tests:** `supabase/tests/01_stage1_foundation.test.sql`, 33 checks, all passing. They cover:
- structure and RLS flags;
- the clinical wall for the agent and for service_role;
- PUBLIC function lock-down;
- constraints: time zone, service duration and code, wa_id format, duplicate patient,
  cross-clinic composite FK, dentist must link to a professional;
- `updated_at`;
- audit before/after images and actor attribution;
- agent isolation: no clinic set → no rows, own clinic only, no cross-clinic insert,
  no deletes, read-only services;
- staff isolation.

**Changes vs. the skill's reference schema (deliberate):**
- Added `clinics.wa_phone_number_id` (unique) and `waba_id`, so inbound webhooks can be
  routed to a clinic. Credentials are not stored in the table.
- Added `sort_order` on professionals and services (controls display order in the Flow).
- Added validation: time zone (`core.is_valid_timezone`), service `code` format,
  `wa_id` digits only, and dentist staff rows must link a professional.
- `service_role` is granted `core` + `ops` and **nothing on `clinical`**. That makes the
  wall hold even for ops code. (In Supabase, `service_role` is not a superuser.)
- RLS on `ops.staff` / `ops.audit_events` is enabled but **not forced**. The
  security-definer functions that read and write them run as the owner, and forcing RLS
  would empty staff lookups and block audit writes.
- Function lock-down is done with explicit `revoke ... from public` at the end of the
  grants migration. A per-schema `alter default privileges` cannot remove PUBLIC's
  default EXECUTE (found during testing).

**Assumptions (low-stakes, proceed unless you object):**
- A1. One patient row per WhatsApp user *per clinic*. The same person at two clinics gets two rows.
- A2. Patient language options are `az`, `ru`, `en` (`en` is allowed but has no templates yet).
- A3. In the pilot, staff accounts are created by an admin through service_role.
  There's no self-signup.
- A4. Seed names, services and durations are placeholders until Avenue Dent confirms them.

### Stage 2 — Scheduling ✅ (2026-10-31)

**Your decisions**
| Q | Decision | How it's built |
|---|---|---|
| Q1 | Per dentist for now | Overlap rules keyed on `professional_id`. Chairs can be added later as a second exclusion constraint without changing these tables. |
| Q2 | Approval for some services | `services.requires_approval`. Those bookings start as `pending_approval` and **still block the slot**. Only staff can approve or reject. |
| Q3 | 45-minute grid, modifiable | `clinics.slot_step_minutes` (default 45, range 5–240), editable by clinic **admins** only. |

**Migrations**
| File | Contents |
|---|---|
| `20261031110000_stage2_settings_and_hours.sql` | Clinic booking settings (grid, min notice, horizon, hold length); `services.requires_approval`; `ops.has_clinic_role()`; staff fallback in `core.current_clinic_id()`; `core.bump_version()`; `core.schedules`; `core.blocks` |
| `20261031110100_stage2_appointments_and_holds.sql` | `core.appointments` (exclusion constraint, status rules, version), `core.slot_holds` |
| `20261031110200_stage2_booking_functions.sql` | `slot_is_free`, `available_slots`, `available_dates`, `hold_slot`, `confirm_hold`, `cancel_appointment`, `approve_appointment`, `reject_appointment` |
| `20261031110300_stage2_rls_and_grants.sql` | RLS on the four new tables, admin-only settings edits, grants per role |

**How booking works**
1. Flow "dates" step: `available_dates(service, dentist|null)`.
2. Flow "slots" step: `available_slots(service, local_date, dentist|null)`.
3. Flow "hold" step: `hold_slot(patient, service, start, dentist|null)` returns a hold id, or
   null if the slot was just taken (show fresh slots).
4. Flow completion: `confirm_hold(hold, patient, name)` returns `(appointment_id, status)`,
   where status is `booked` or `pending_approval`. Replays return the same row. An expired
   hold returns no row: apologise and re-offer.
5. Reschedule: `hold_slot(..., p_replacing_appointment)` then `confirm_hold`. The old
   appointment is cancelled in the same transaction, and only if nobody changed it in the
   meantime (error `40001` otherwise).
6. Cancel: `cancel_appointment(appointment, patient, expected_version, reason)`.

**Rules the database enforces**
- No overlapping active appointments for one dentist. This holds even for direct writes,
  through the exclusion constraint.
- No overlapping live holds. Expired holds are removed under a per-dentist advisory lock,
  so no cron job is needed for correctness.
- Status changes follow one path: `pending_approval → booked/rejected/cancelled`,
  `booked → confirmed/checked_in/cancelled/no_show`, `confirmed → checked_in/cancelled/no_show`,
  `checked_in → completed`. Nothing comes back from a final status.
- Every appointment update bumps `version`.

**Grid behaviour to know:** start times are counted from the start of each working window.
With a 10:00–19:00 day and a 45-minute grid, they are 10:00, 10:45, 11:30, and so on. A
30-minute service therefore leaves a 15-minute gap, and a 60-minute service ends off-grid.
That is expected. Change the grid, the window or the service duration to tune it.

**Tests:** `02_stage2_scheduling.test.sql` (42 checks) plus `concurrency_test.sh`
(20 rounds of two sessions racing, exactly one winner every round).

**Changes vs. the skill's reference schema (deliberate)**
- Appointments and holds store three times: `start_at`, `end_at` (chair time) and
  `blocked_until` (end + buffer). The reference stored only an end that included the
  buffer, which would have shown wrong end times in the iPhone calendar.
- Reschedule is built into `hold_slot` / `confirm_hold` with a version check, instead of
  being a separate function.
- Patient ownership is checked in `confirm_hold` and `cancel_appointment` (`p_patient_id`).
- Clinic-wide blocks (`professional_id` null) handle public holidays.
- Schedules have `valid_from` / `valid_to`, and overlapping hours are rejected.
- A status-transition trigger was added, plus `available_dates()` for the Flow's date screen.

**Found during testing:** CHECK constraints run with the caller's rights. Staff updates
to `core.clinics` failed until `authenticated` was granted EXECUTE on
`core.is_valid_timezone`.

**Assumptions (low-stakes):**
- A5. A patient holds at most one slot at a time; a new hold replaces the old one.
- A6. Seed: both dentists work Mon–Sat 10:00–19:00, and fillings require approval. These are placeholders.

### Stage 3 — Messaging ✅ (2026-10-31)

**Your decisions**
| Q | Decision | How it's built |
|---|---|---|
| Q4 | Erase message text after 180 days | `clinics.message_retention_days` (default 180, admin-editable). `core.purge_message_bodies()` erases `body` and `media_id`, sets `body_purged_at`, and keeps metadata. Cron scheduling comes in Stage 4. |
| Q7 | Bot cutoff 4 h before the appointment, modifiable | `clinics.patient_change_cutoff_minutes` (default 240, admin-editable). Enforced by a trigger on every assistant cancel or reschedule (error `DP001`); staff are not limited. `core.patient_can_change()` lets the bot hide the options in advance. |

**Migrations**
| File | Contents |
|---|---|
| `20261031120000_stage3_settings_and_change_rules.sql` | Retention / cutoff / echo-pause settings; `patients.last_inbound_at`; assistant appointment rules trigger; `patient_can_change()` |
| `20261031120100_stage3_conversations_and_messages.sql` | `core.conversations` (one open per patient, status rules), `core.messages` (dedup, outbound queue shape), `core.flow_tokens` |
| `20261031120200_stage3_messaging_functions.sql` | Tenant resolvers; inbound/echo recording; `assistant_may_reply`; `service_window_open`; outbound queue + delivery status; processing bookkeeping; conversation control; Flow tokens; retention + token cleanup |
| `20261031120300_stage3_rls_and_grants.sql` | RLS, narrow staff rights on messages, grants per role |

**Rules the database enforces**
- One stored row per WhatsApp message id. Redelivered webhooks come back flagged
  `is_duplicate` and must not be processed again.
- Outbound messages are written before sending. The same `send_key` always returns the
  same row, so a retried job never sends twice.
- Delivery status only moves forward (sent → delivered → read), because status webhooks
  arrive out of order.
- The assistant can escalate at any time, and can hand over a conversation it owns.
  It can never take a conversation back or de-escalate it. A closed conversation is final;
  the next message opens a new one.
- The assistant can only *confirm* or *cancel* appointments, and only outside the cutoff.
- Staff can read history and queue their own replies, but cannot edit messages or forge
  inbound ones.
- Webhook ingress runs as `dentpilot_agent`, not `service_role`. The clinic is resolved by
  two tiny security-definer lookups that return only a clinic id. This narrows
  `service_role` to cron, onboarding and retention.

**Tests:** `03_stage3_messaging.test.sql` (47 checks).

**A7 (superseded in Stage 6):** this stage built a 30-minute "echo pause". You chose a
permanent hand-over instead; see Stage 6.

**Changes vs. the skill's reference schema:** these are additions, nothing was removed.
- Message delivery tracking and the outbound idempotency key.
- `last_human_reply_at` and the echo pause.
- The 24-hour window helper.
- Flow-token purpose (`book` / `reschedule`).
- Webhook ingress moved from `service_role` to the agent role.

### Stage 4 — Jobs, reminders, notifications ✅ (2026-10-31)

**Your decisions**
| Q | Decision | How it's built |
|---|---|---|
| Q8 | Staff alerts by web-app push | `ops.staff_notifications` (per-staff inbox), `ops.push_subscriptions` (one per device), a `push_notification` job per notification. Notifications store a kind and a reason code, **never message text**. |
| Q9 | Reminders as a clinic setting | `clinics.reminder_offsets_minutes` (default `{1440}` = 24 h; up to 3 values, 30 min–7 days) and `reminder_ask_confirmation` (default on). All admin-editable. |
| Q6 | Remind staff after 2 h; pending never expires | `clinics.approval_reminder_minutes` (default 120, 0 = off). One reminder to all staff. The booking stays `pending_approval` until staff approve or reject it. |

**Migrations**
| File | Contents |
|---|---|
| `20261031130000_stage4_settings_and_jobs.sql` | Reminder/approval settings; `ops.background_jobs`; enqueue / claim (SKIP LOCKED + lease) / complete / fail (backoff → dead) / cancel / cleanup |
| `20261031130100_stage4_staff_notifications.sql` | Notification inbox, push subscriptions, `notify_staff`, push worker helpers, register device, mark read |
| `20261031130200_stage4_automation.sql` | Triggers turning appointment and conversation events into jobs and notifications; approval reminder handler; reconciler; `appointment_message_details`, `confirm_attendance`, `set_reminder_opt_out` |
| `20261031130300_stage4_rls_and_grants.sql` | RLS on ops tables; the agent gets queue *functions* only, never the job table |
| `20261031130400_stage4_cron.sql` | `dentpilot-tick` (every minute) and `dentpilot-nightly` (03:00 Baku). Skips itself where pg_cron/pg_net don't exist |

**What happens automatically**
| Event | Result |
|---|---|
| Appointment booked or confirmed | One reminder job per configured time; a time already in the past is skipped |
| Appointment moved | Old reminders cancelled, new ones created |
| Appointment cancelled / no-show / etc. | Its reminders cancelled |
| Booking needs approval | Every staff member notified (inbox + push); staff reminder job at +2 h |
| Staff approve | Staff reminder cancelled, patient told "approved", patient reminders start |
| Staff reject | Staff reminder cancelled, patient told "rejected" |
| Conversation escalated / handed over | Every staff member notified, with the reason code |
| Inbound message unprocessed > 1 min | Re-queued by the minute tick (once per message) |
| Nightly | Message text past retention erased; expired Flow tokens, finished jobs (30 d) and read notifications (90 d) removed |

**Tests:** `04_stage4_jobs_and_notifications.test.sql` (41 checks). `concurrency_test.sh`
now also has two workers claiming 50 jobs at once; none is handed out twice.
The cron job SQL was run against stubbed pg_net/Vault locally. The schedules themselves
can only be checked on Supabase (§5, step 6).

**Know before go-live:** web push on iPhone works only when the staff web app has been
added to the Home Screen (iOS 16.4 or later) and the user allows notifications there. In
a normal Safari tab it won't push. The in-app inbox works either way.

**Assumptions (low-stakes):**
- A8. Every staff member of the clinic receives every notification (small clinic). This
  can be narrowed to "the booked dentist + receptionists" later.
- A9. A reminder that would already be in the past when the booking is made isn't sent.
- A10. If a pending booking's start time passes without a decision, it stays pending
  (per Q6). Staff still see it in their inbox.

### Stage 5 — Clinical ✅ (2026-10-31)

**Your decisions**
| Q | Decision | How it's built |
|---|---|---|
| Q10 | All staff edit the price list | One staff policy on `clinical.price_list`. No DELETE grant: deactivate (`active = false`) instead, so history stays intact. |
| Q11 | Dentists see only their own records | `clinical.can_access_treatments()`: admin/receptionist see the whole clinic; a dentist sees records where `professional_id` is their own. Line items and totals follow their record. |
| Q12 | Override needs a reason | CHECK `treatment_override_needs_reason`: a manual total and a non-blank reason go together. Every override is audited with who made it. |

**Migrations**
| File | Contents |
|---|---|
| `20261031140000_stage5_price_list_and_treatments.sql` | `price_list`, `treatment_records`, `treatment_line_items`, `treatment_totals` view, price snapshot trigger, appointment-consistency check, version/audit triggers |
| `20261031140100_stage5_rls_and_grants.sql` | Role-based RLS, column-level update grants, the wall restated |

**Rules the database enforces**
- **Price snapshot.** A line's `unit_price` is copied from the active price list on
  insert. Any value the client sends is ignored, and nobody can update it afterwards.
  Price changes never alter past treatments.
- **Totals.** Total = sum of lines, or the manual total when one is set (with its reason).
  The computed total is always shown next to it.
- **Linked appointments.** A record linked to an appointment must match that
  appointment's patient and dentist. Walk-ins and paper-diary visits can have no link.
- **No deletes.** Records can't be deleted, only corrected, and every change is audited.
  Line items can be removed by whoever may edit the record.
- **`created_by`** comes from the signed-in user, never from the client.
- **Version bump.** Adding, editing or removing a line bumps the record's `version`, so
  someone editing a stale copy of the record is stopped.
- **The wall.** The assistant and `service_role` have no access to `clinical`; tested in
  stages 1 and 5.

**Tests:** `05_stage5_clinical.test.sql` (30 checks), covering every role (two dentists,
receptionist, admin, another clinic's staff).

**Found during testing:** the line-item "touch" needed `updated_at` in staff's column
grant on records. Without it, adding a line failed with "permission denied".

**Assumptions (please confirm):**
- A11. "Own records" means records where the dentist is the **treating** dentist. If a
  patient sees both dentists, each sees only their own treatments of that patient.
- A12. Receptionists see and write the whole clinic's treatment log, because they
  transcribe the paper diary.
- A13. Payments and balances are not tracked yet. Totals are what was charged, not what
  was paid.

### Stage 6 — FAQ knowledge base, calendar feed, revisions ✅ (2026-10-31)

**Your decisions**
| Q | Decision | How it's built |
|---|---|---|
| A7 (revised) | A human reply hands the conversation over permanently | A trigger on `core.messages`: a dentist echo or staff reply moves `assistant → handed_to_staff` (reason `doctor_reply` / `staff_reply`). No staff notification is sent, because a human is already there. `echo_pause_minutes` is removed. |
| A14 (new; follows from A7) | Idle conversations auto-close | `clinics.conversation_idle_close_hours` (default **24**, admin-editable). Hourly cron closes `assistant` / `handed_to_staff` conversations with no messages for that long; the patient's next message starts fresh with the bot. **Escalated conversations never auto-close.** |
| A11 (revised) | Dentists read all records of shared patients | READ: a dentist sees every record of patients they've treated or have an appointment with (not cancelled/rejected), including other dentists' work. WRITE: unchanged, own records only. |
| Q13 | Calendar shows first name + service | The event title is the patient's first name and the Azerbaijani service name, e.g. "Leyla — Müayinə" (service only if no name is known). |
| Q14 | All staff approve FAQ answers | Any staff member can approve. Approval records who and when. **Editing an approved answer withdraws the approval automatically.** |

**Migrations**
| File | Contents |
|---|---|
| `20261031150000_stage6_handover_and_idle_close.sql` | Idle-close setting; new `assistant_may_reply`; drop echo pause; hand-over trigger; quieter notifications; `ops.close_idle_conversations()` |
| `20261031150100_stage6_treatment_visibility.sql` | `clinical.is_my_patient`, `clinical.can_read_treatments`; separate read/write policies on records and line items |
| `20261031150200_stage6_faq_knowledge_base.sql` | `core.kb_entries` (+ trigram index), approval reset trigger, `approve_kb_entry`, `kb_for_prompt` |
| `20261031150300_stage6_calendar_feed.sql` | `ops.calendar_feeds` (hashed tokens), create/revoke, `core.calendar_feed_events` |
| `20261031150400_stage6_rls_and_grants.sql` | Assistant sees approved + active FAQ only; staff rights; feed functions |
| `20261031150500_stage6_cron.sql` | `dentpilot-hourly` (idle close); skips itself without pg_cron |

**Calendar feed: what the `calendar-feed` Edge Function must do** (as `dentpilot_agent`)
- `GET /calendar-feed/<token>.ics` → `core.calendar_feed_events(token)`.
- Render a `VCALENDAR` with one `VEVENT` per row: `UID` = uid,
  `SEQUENCE` = sequence, `DTSTART` / `DTEND` in UTC, `SUMMARY` = summary,
  `STATUS:TENTATIVE` when tentative (otherwise `CONFIRMED`), `LAST-MODIFIED`.
- An unknown or revoked token still returns HTTP 200 with an empty calendar, so nobody
  can probe which tokens exist.
- The window is 7 days back to 60 days ahead. iOS refreshes on its own schedule, so the
  feed isn't real-time.
- A dentist creates their own feed in the web app; an admin can create one for any
  dentist. The token is shown **once**; only its SHA-256 is stored. Revoke and re-create
  if a phone is lost.

**FAQ: how the assistant uses it.** `core.kb_for_prompt(language)` returns all approved,
active entries for the patient's language, to go in the cached prompt. The selector picks
an entry id and the stored answer is sent word for word. **Embeddings aren't added yet.**
The vector size depends on which embedding model wins the Azerbaijani eval, so that column
comes in a later migration, when retrieval is actually needed (around 150+ entries).

**Changes to earlier tests:** the Stage 3 echo tests now check the permanent hand-over
(on a separate patient), since the echo pause no longer exists. Tests describe current
behaviour; migrations are never edited.

**Found during testing:** a `STABLE` function can't see rows inserted earlier in the
same SQL statement. This doesn't affect the product, but Edge Functions should call
`record_inbound_message` and `assistant_may_reply` as **separate statements**, which is
the natural order anyway.

**Tests:** `06_stage6_kb_feed_handover.test.sql` (35 checks).

### Edge support migration ✅ (2026-11-01)
`20261101100000_edge_support.sql` adds two things:
- `messages.processing_started_at` and `core.claim_message_for_processing()`: a 2-minute
  lease, so the webhook and the reconciler never both answer one message.
- `mark_outbound_sent` now also accepts `failed`, so a send Meta rejected can be retried.

`enqueue_stale_messages` now skips messages under a fresh lease. Tests:
`07_edge_support.test.sql` (9 checks).

### Edge Functions E1 — deterministic bot ✅ (2026-11-01)
The five functions, the shared library, and the AZ/RU Flow JSON (an error caption was
added to the slot screen) are covered in §5d and §5e. All patient-facing texts are in
`_shared/texts.ts` as DRAFTS for receptionist review.

**Design decisions (low-stakes, already built):**
- Without an LLM, unrecognised free text gets the menu. E2 puts the router at exactly
  that point.
- Buttons and Flow completions are handled even after a hand-over, because they're the
  patient acting on something we offered. Free text after a hand-over gets no reply.
- Reminders show buttons only while the appointment is `booked`; an already-confirmed
  appointment gets the plain template.
- Staff push texts are Azerbaijani-only, since the staff language is assumed to be
  Azerbaijani.
- No `.ics` attachment to patients yet. It needs media upload; revisit after the pilot.

### Edge Functions E2 — LLM router ✅ (2026-11-01)

**Your decisions**
| Q | Decision | How it's built |
|---|---|---|
| E2-1 | Provider-agnostic | Adapters for Anthropic (forced tool call), OpenAI and any OpenAI-compatible endpoint (strict JSON schema, or JSON mode), and Gemini (JSON mode). Selected by `LLM_PROVIDER`; `none` keeps the E1 menu. |
| E2-2 | Router only | The model picks an action or an approved FAQ entry; it never writes patient text. |
| E2-3 | Unplaceable → menu | Low confidence, `greeting`, `other`, invalid output and provider errors all get the menu. |

**Safety default added (please confirm, A15):** `clinical_question` and `complaint` go to
staff, not the menu.

**Files:** `_shared/llm/providers.ts`, `_shared/router.ts`, router wiring in
`_shared/pipeline.ts`, two new texts (`clinical_to_staff`, `you_are_welcome`), and
`tests/router_test.ts` with 10 tests that check each adapter's exact request and response
format without network. The end-to-end journey has 5 new router steps:
- free text → Flow;
- FAQ → approved answer;
- clinical → staff, then silent;
- unsure or down → menu, and thanks → a short reply;
- an emergency never reaches the router.

`tests/router_eval.ts` and its draft golden set support the bake-off. The full eval was
smoke-tested against a local OpenAI-compatible stand-in.

### Clinic answers applied ✅ (2026-11-02)

Source: `AvenueDent_Replies_EN.docx` (Dr. Ayten).

**Facts that changed the build:**
- The number is the doctor's personal number, on the Business App for about 10 years.
- The doctors use Android phones and agreed to use Google Calendar.
- Visit durations run 15–240 minutes, and buffers 10–60.
- 70–80% of visits are follow-ups in multi-stage treatment.
- The doctor confirms every booking herself.
- Each patient is booked with a specific doctor; there are 2 chairs and both doctors work
  at the same time.
- About half of all messages are voice notes.
- They agreed to shadow mode and to keeping the paper diary in parallel.

**Your decisions**
| Decision | How it's built |
|---|---|
| Shadow mode for everyone | `clinics.shadow_mode` (**default ON for every new clinic**). Assistant and system messages are stored as drafts with their exact WhatsApp payload. Staff approve (optionally editing text or interactive bodies; template wording is fixed) or discard. Approval queues a `send_message` job. Staff's own replies send directly. Staff get a `draft_waiting` push (at most once per conversation per minute). Edited drafts are flagged `edited`, which makes them labelled examples for evaluation. |
| Any service, all need approval | `clinics.all_bookings_need_approval` (Avenue Dent: on). The doctor approves with the **real duration** (`approve_appointment(id, version, minutes)`). End and blocked-until follow it, plus the service buffer. A duration that would overlap the next booking is refused (23P01). |
| Google Calendar + feed | §5g. The primary calendar, one-way. |
| Grid 45 min, cutoff 4 h | Unchanged. |
| Specific doctor | `clinics.offer_any_dentist` (Avenue Dent: off). The Flow JSON no longer pre-selects "any". |
| Booking horizon | Avenue Dent: 30 days (B7). |

**Migrations:**
- `20261102100000_shadow_mode_and_approval.sql`
- `20261102100100_google_calendar.sql`
- `20261102100200_shadow_mode_grants.sql`
- `20261102100300_google_oauth_support.sql`

**Tests:**
- `08_shadow_mode_gcal.test.sql` (27 checks);
- `gcal_test.ts` (Google client and OAuth state, against a fake Google);
- six new end-to-end steps: draft → approve → send, no "any dentist", OAuth connect
  (including role checks and a tampered state), sync create/move/delete, revoked access.

Tests 03 and 07 now set `shadow_mode = false` because they test the live send path.

**Found while applying:** before this change, a staff reply was queued but nothing sent
it. Staff-written messages now get a `send_message` job too.

**At go-live with the clinic:**
- Switch off the WhatsApp Business **automatic reply** (A7), or the patient gets two answers.
- Check with Meta whether Coexistence supports **disappearing messages** (A8, used with
  some patients).
- With Android phones, staff push works in Chrome without installing anything. The iPhone
  Home Screen note doesn't apply.

### Emergency reply bypasses shadow mode ✅ (2026-11-03)

**Decision S1:** the fixed emergency reply ("…call 103") is the **only** message sent without
the doctor's approval in shadow mode. The patient calls 103 themselves; DentPilot never calls
anyone. The doctor is pushed at once either way.

**How it's guaranteed:**
- The text lives in the database as clinic settings `emergency_reply_az` /
  `emergency_reply_ru`. They're admin-editable and checked to be 10–1000 characters, and
  their defaults are the reviewed draft texts.
- `core.queue_emergency_reply(patient, send_key)` is the only path that queues a bot
  message as `pending` in shadow mode. It takes **no text argument**, so neither the
  pipeline nor the LLM can push anything else past the doctor.
- The reply is sent once per inbound emergency (idempotent on the send key).

The `escalation` text was removed from `_shared/texts.ts`, so the clinic setting is the only
source. **Receptionist review:** these two texts are now part of the clinic settings review.

**Files:**
- migration `20261103100000_emergency_reply_bypass.sql`;
- `09_emergency_reply.test.sql` (7 checks, including "every other bot message is still a
  draft" and "the assistant can't change the text");
- `_shared/pipeline.ts`;
- one new end-to-end step.

### Staff web app — Step 1: API ✅ (2026-11-04)

Migration `20261104100000_staff_app_api.sql` adds nine functions:
- `ops.my_staff_profile`
- `core.staff_counts`
- `core.staff_draft_inbox`
- `core.staff_pending_bookings`, whose `max_duration_minutes` is the time until the
  dentist's next booking or block, minus the buffer, capped at 480
- `core.staff_conversations` (filters: attention, open, all)
- `core.staff_conversation_messages`
- `core.staff_send_reply`, which trims the text, enforces the 24-hour window (`DP002`),
  sends directly and hands the conversation to staff
- `core.staff_day_schedule`, in clinic local time
- `core.staff_set_appointment_status`, with a version check and the status rules

**Tests:** `10_staff_api.test.sql`, 26 checks run as a dentist and as another clinic's
receptionist. That covers profile, badges, inbox, the pending-booking duration cap,
conversation lists and threads, reply rules, schedule, status changes and isolation.

**Found during testing:** a patient's message and the bot's draft can share a timestamp.
Threads now break the tie with the patient's message first.

### Staff web app — Step 2: the app ✅ (2026-11-04)

**Your decisions:**
- W1: email + password, with "forgot password".
- W2: Azerbaijani, Russian and English, switchable, Azerbaijani by default.
- W3: Cloudflare Pages.

**Built**
- **Stack:** React 18 + TypeScript + Vite and supabase-js, with exact versions pinned.
  It's an installable PWA with a service worker for push; the bottom tab bar has badges.
- **Screens** as designed in §5h:
  - **Inbox:** edit only if the draft is text or interactive; send is blocked for free
    text outside the 24-hour window; templates are shown as such.
  - **Bookings:** the duration picker is capped at the time until the next booking, and an
    overlap is explained in words.
  - **Conversations:** emergencies first, drafts marked in the thread, the reply box only
    shown inside the window, hand back to bot, close.
  - **Today:** clinic time zone; a dentist sees her own day first; status-specific actions.
  - **Settings:** language, push, Google Calendar (own, or any for admins), shadow mode
    and the approval rule for admins.
- **Push:** notifications open the right screen. Emergencies stay on screen until tapped.
- **Data refresh:** polling every 15–30 s and whenever the app regains focus. Live
  updates come in Step 3.
- **Database addition:** `core.staff_conversation_info` (the thread header, including the
  24-hour window), added to the Step 1 migration before it was ever applied.

**Tests**, run with `npm run check`. 35 tests, plus the type-check and build:
- a **contract test** that reads the SQL migrations and fails if any function or parameter
  the app calls doesn't exist;
- translations: every key in all three languages, with matching placeholders;
- formatting, including "today" in the clinic's time zone rather than the browser's;
- error mapping;
- screen tests for Inbox (edit/send/discard, window rules, templates), Bookings (duration
  cap, overlap message, reject reason), Conversation (thread, reply, window closed, hand
  back), Today (actions per status) and the navigation badges.

**Found during testing:** in English and Russian, the "Arrived" button and the "Arrived"
status label used the same word. The status labels now differ ("In the clinic",
"В клинике").

**Known limits (Step 3 or later):**
- Staff in several clinics see their first clinic only. A clinic switcher comes later.
- Push titles are in Azerbaijani only, because the server sends them.
- No staff booking by phone yet.
- No treatment log screen yet.
- App texts in Azerbaijani and Russian are drafts for receptionist review.

## 7. Open questions (must be answered before the stage that needs them)

| # | Question | Needed for | Status |
|---|---|---|---|
| Q1 | Is availability limited per **dentist** or per **chair**? | Stage 2 | Decided: per dentist for now |
| Q2 | Do bot bookings confirm instantly, or wait for staff approval? | Stage 2 | Decided: per-service flag |
| Q3 | Booking grid | Stage 2 | Decided: 45 min, admin-editable |
| Q4 | How many days to keep message text before purging? | Stage 3 | Decided: 180, admin-editable |
| Q5 | Real dentist names, service list, durations, buffers, which services need approval | Seed / go-live | Open (clinic) |
| Q6 | If staff never act on a `pending_approval` booking? | Stage 4 | Decided: remind after 2 h, never expires |
| Q7 | Can patients cancel or reschedule via the bot up to the last minute? | Stage 3 | Decided: 4 h cutoff, admin-editable |
| Q8 | How are staff alerted? | Stage 4 | Decided: web-app push + inbox |
| Q9 | Reminder timing | Stage 4 | Decided: clinic setting, default 24 h + confirm button |
| A7 | Echo pause vs permanent hand-over | Stage 3 | Decided: permanent hand-over (Stage 6) |
| Q10 | Who may edit the price list? | Stage 5 | Decided: all staff |
| Q11 | What dentists see in the treatment log | Stage 5 | Decided: read all records of their patients, write own (Stage 6) |
| Q12 | Reason for a manual total? | Stage 5 | Decided: required |
| Q13 | Calendar event content | Stage 6 | Decided: first name + service |
| Q14 | Who approves FAQ answers | Stage 6 | Decided: all staff |
| A12 | Receptionists see/write the whole treatment log | Stage 5 | Confirmed 2026-10-31 |
| A13 | Payments/balances not tracked yet | Stage 5 | Confirmed 2026-10-31 (revisit after pilot) |
| A14 | Idle conversations close after 24 h (setting) | Stage 6 | Confirmed 2026-10-31 |
| E2-1 | LLM provider | E2 | Decided: provider-agnostic; model chosen by the bake-off (§5f) |
| E2-2 | E2 scope | E2 | Decided: router only |
| E2-3 | Unplaceable free text | E2 | Decided: menu |
| A15 | Clinical questions and complaints go to the doctor (not the menu) | E2 | Confirmed 2026-11-03 (as built) |
| S1 | Emergency reply in shadow mode | Shadow mode | Decided 2026-11-03: sent immediately; the patient calls 103 themselves |
| C1 | Clinic still to send: doctors' names, real weekly hours (B1 "flexible, half day"), holidays/vacations (B2 unanswered), prices or price ranges, FAQ answers, champion, success criteria, questionnaire section D | Go-live | Open (clinic) |
| C2 | Voice notes are about half of all messages: add transcription for routing? (Azerbaijani speech recognition needs testing) | After pilot | Open |
| W1 | Staff app login method | Web app Step 2 | Decided: email + password |
| W2 | Staff app language(s) | Web app Step 2 | Decided: az + ru + en |
| W3 | Where to host the staff app | Web app Step 2 | Decided: Cloudflare Pages |

## 8. Roadmap

| Stage | Scope |
|---|---|
| 1 | Foundation: schemas, roles, tenancy, reference tables, audit ✅ |
| 2 | Scheduling: working hours, blocks, appointments, holds, availability, booking functions ✅ |
| 3 | Messaging: conversations, messages (dedup), flow tokens, ingress + reconciler support ✅ |
| 4 | Jobs & reminders: background_jobs, claim function, pg_cron/pg_net, opt-out, retention purge, staff push ✅ |
| 5 | Clinical: price list, treatment records and line items, totals view (staff only) ✅ |
| 6 | FAQ knowledge base + calendar feed tokens; hand-over and visibility revisions ✅ |

**Before go-live (outside this database build)**
1. Clinic data: real dentists, services, durations, buffers, approval flags, working hours,
   prices, FAQ answers (Q5).
2. Edge Functions: E1 and E2 built and tested (§5d, §5f). Run the router bake-off with real messages, then set `LLM_PROVIDER` / `LLM_MODEL`.
3. Deploy checks §5, steps 1–7, on the hosted project.
4. Approved WhatsApp templates: drafts in §5e, to submit after receptionist review.
5. Staff onboarding: allow notifications for the staff web app in Chrome (Android), and
   connect each dentist's Google Calendar.

## 9. Change log

| Date | Stage | Change | Files |
|---|---|---|---|
| 2026-10-31 | 1 | Initial foundation: schemas, agent role, tenancy, reference tables, audit, RLS, grants, tests, SOP | 3 migrations, seed, 1 test file, scripts |
| 2026-10-31 | 2 | Scheduling: settings (45-min grid), approval flag, schedules, blocks, appointments, holds, booking functions, staff fallback for clinic context, race test | 4 migrations, seed (schedules, approval flag), `02_stage2_scheduling.test.sql`, `concurrency_test.sh`, `test_local.sh`, `supabase_stubs.sql` (extensions schema) |
| 2026-10-31 | 3 | Messaging: retention (180 d) and bot cutoff (4 h) settings, assistant appointment rules, conversations, messages, Flow tokens, ingress/outbound/delivery functions, retention purge | 4 migrations, `03_stage3_messaging.test.sql` |
| 2026-10-31 | 4 | Jobs & notifications: reminder/approval settings, job queue, staff inbox + web push, automation triggers, reconciler, cron schedules, job-claim race test | 5 migrations, `04_stage4_jobs_and_notifications.test.sql`, `concurrency_test.sh` |
| 2026-10-31 | 5 | Clinical: price list (all staff), treatment log with per-role visibility, price snapshots, totals with mandatory override reason, seed prices | 2 migrations, seed, `05_stage5_clinical.test.sql` |
| 2026-10-31 | 6 | FAQ knowledge base (all-staff approval, auto-withdraw on edit), iPhone calendar feed (hashed tokens), permanent hand-over + idle close (A7 revised), shared-patient read access (A11 revised), hourly cron; Stage 3 echo tests updated | 6 migrations, seed (FAQ examples), `06_stage6_kb_feed_handover.test.sql`, `03_stage3_messaging.test.sql` |
| 2026-10-31 | — | Assumptions A12, A13, A14 confirmed as built; no schema change | `SOP.md` |
| 2026-11-01 | E1 | Edge support migration (processing lease, resend after failure); five Edge Functions + shared library; AZ/RU Flow JSON; template drafts; Deno unit + end-to-end tests | 1 migration, `07_edge_support.test.sql`, `supabase/functions/**`, `supabase/flows/*`, `scripts/test_edge.sh` |
| 2026-11-01 | E2 | Provider-agnostic LLM router (Anthropic / OpenAI-compatible / Gemini), strict validation + retry + menu fallback, router wired into the pipeline, two texts, router unit tests, 5 end-to-end steps, bake-off eval script + draft golden set | `_shared/llm/*`, `_shared/router.ts`, `_shared/pipeline.ts`, `_shared/texts.ts`, entry points, `tests/router_test.ts`, `tests/router_eval.ts`, `tests/evals/*` |
| 2026-11-02 | Clinic | Shadow mode (drafts, approve/edit/discard, send job), clinic-wide approval + approve with duration, offer_any_dentist, Google Calendar one-way sync + OAuth connect (Vault), staff replies now actually sent, seed per clinic answers | 4 migrations, `08_shadow_mode_gcal.test.sql`, `_shared/outbound.ts`, `_shared/gcal.ts`, `run-jobs`, `google-oauth/*`, `flow-endpoint`, flows JSON, tests 03/07 fixtures, Deno tests |
| 2026-11-03 | S1 | Emergency reply sent immediately even in shadow mode (fixed clinic text, dedicated function, no free text); A15 confirmed | 1 migration, `09_emergency_reply.test.sql`, `_shared/pipeline.ts`, `_shared/texts.ts`, integration test |
| 2026-11-04 | App-1 | Staff web app API: 9 screen functions (profile, badges, inbox, pending bookings with duration cap, conversations, thread, reply with 24-h rule, day schedule, status changes) | `20261104100000_staff_app_api.sql`, `10_staff_api.test.sql` |
| 2026-11-04 | App-2 | Staff web app: React/TS PWA (Inbox, Bookings, Conversations, Today, Settings, Login), az/ru/en, push service worker, Cloudflare Pages files; `staff_conversation_info`; contract + screen tests | `web/**`, `20261104100000_staff_app_api.sql`, `10_staff_api.test.sql` |
