#!/usr/bin/env bash
# Apply all migrations + seed to a scratch database on plain Postgres and run
# the pgTAP tests. Use this when the Supabase CLI / Docker isn't available.
# With the Supabase CLI, use instead:  supabase db reset && supabase test db
#
# Usage:  scripts/test_local.sh [database_name]
# Needs:  Postgres 15+, pgTAP, pg_prove; run as a database superuser.
set -euo pipefail

DB="${1:-dentpilot_local}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PSQL=(psql -X -q -v ON_ERROR_STOP=1 -d "$DB")

echo "→ recreating database $DB"
dropdb --if-exists "$DB"
createdb "$DB"

echo "→ Supabase stubs (local only)"
"${PSQL[@]}" -f "$ROOT/scripts/supabase_stubs.sql"

for f in "$ROOT"/supabase/migrations/*.sql; do
  echo "→ migration $(basename "$f")"
  "${PSQL[@]}" -f "$f"
done

echo "→ seed"
"${PSQL[@]}" -f "$ROOT/supabase/seed.sql"

echo "→ tests"
pg_prove -d "$DB" "$ROOT"/supabase/tests/*.test.sql

echo "→ concurrency"
"$ROOT/scripts/concurrency_test.sh" "$DB" 20
