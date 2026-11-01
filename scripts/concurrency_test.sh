#!/usr/bin/env bash
# Race tests with real concurrent sessions (pgTAP runs in one session, so it
# can't cover these):
#   1. Two patients hold the same dentist + time at once — exactly one wins.
#   2. Two job workers claim from the queue at once — no job is handed out twice.
# pgTAP can't do this (it runs in one session), so it lives here.
#
# Usage:  scripts/concurrency_test.sh [database_name] [rounds]
# Needs:  a database already migrated and seeded (scripts/test_local.sh does that).
set -euo pipefail

DB="${1:-dentpilot_local}"
ROUNDS="${2:-20}"
PSQL=(psql -X -q -At -v ON_ERROR_STOP=1 -d "$DB")

CLINIC=00000000-0000-0000-0000-00000000000a
DENTIST=00000000-0000-0000-0000-0000000000d1
SERVICE=00000000-0000-0000-0000-0000000000e1          # exam, 30 min
PATIENTS=(00000000-0000-0000-0000-0000000000f1 00000000-0000-0000-0000-0000000000f2)

# First Monday at least 3 days ahead; seed hours are Mon–Sat 10:00–19:00.
DAY=$("${PSQL[@]}" -c "select d::date from generate_series(current_date + 3, current_date + 9, interval '1 day') d
                       where extract(isodow from d) = 1 limit 1")

hold() {   # $1 = patient, $2 = local start time
  "${PSQL[@]}" <<SQL | tail -n 1
set role dentpilot_agent;
select set_config('app.clinic_id', '$CLINIC', false);
select coalesce(core.hold_slot('$1', '$SERVICE', (date '$DAY' + time '$2') at time zone 'Asia/Baku', '$DENTIST')::text, 'none');
SQL
}

failures=0
for ((i = 0; i < ROUNDS; i++)); do
  "${PSQL[@]}" -c "delete from core.slot_holds"
  start=$(( (i % 2) == 0 ? 10 : 13 )):00        # alternate two grid times
  hold "${PATIENTS[0]}" "$start" > /tmp/race_a &
  hold "${PATIENTS[1]}" "$start" > /tmp/race_b &
  wait
  winners=$(grep -vc '^none$' /tmp/race_a /tmp/race_b | awk -F: '{s += $2} END {print s}')
  if [[ "$winners" != "1" ]]; then
    echo "round $i: $winners winners (expected 1)"; failures=$((failures + 1))
  fi
done

"${PSQL[@]}" -c "delete from core.slot_holds"
if (( failures == 0 )); then
  echo "ok - $ROUNDS concurrent rounds, exactly one hold won each time"
else
  echo "not ok - $failures of $ROUNDS rounds failed"; exit 1
fi

# --- Job queue: two workers claim at once; no job may be handed out twice. ---
"${PSQL[@]}" -c "select ops.enqueue_job('process_message', null, '{}', 'race:' || g) from generate_series(1, 50) g" > /dev/null

claim() {   # $1 = worker name
  "${PSQL[@]}" <<SQL | grep -E '^[0-9a-f-]{36}$'
set role dentpilot_agent;
select id from ops.claim_jobs(array['process_message'], 30, '$1');
SQL
}
claim w1 > /tmp/claim_a &
claim w2 > /tmp/claim_b &
wait

total=$(cat /tmp/claim_a /tmp/claim_b | wc -l)
unique=$(cat /tmp/claim_a /tmp/claim_b | sort -u | wc -l)
"${PSQL[@]}" -c "delete from ops.background_jobs where idempotency_key like 'race:%'"
if [[ "$total" == "50" && "$unique" == "50" ]]; then
  echo "ok - two workers claimed 50 jobs with no job handed out twice"
else
  echo "not ok - claimed $total rows, $unique distinct (expected 50/50)"; exit 1
fi
