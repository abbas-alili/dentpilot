#!/usr/bin/env bash
# Edge Function tests: unit tests, then end-to-end tests against a fresh local
# database (migrations + seed) with WhatsApp and push replaced by recorders.
#
# Usage:  scripts/test_edge.sh
# Needs:  Deno 2, local Postgres 15+ (superuser access via `sudo -u postgres` or as postgres),
#         the extensions used by the migrations.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DB=dentpilot_edge
# Run a command as the postgres OS user (directly, via sudo, or via su).
as_pg() {
  if [[ "$(id -un)" == "postgres" ]]; then "$@"
  elif command -v sudo >/dev/null; then sudo -u postgres "$@"
  else su postgres -c "$(printf '%q ' "$@")"
  fi
}
psql_db() { as_pg psql -X -q -v ON_ERROR_STOP=1 -d "$DB" "$@"; }

echo "→ fresh database $DB"
as_pg dropdb --if-exists "$DB"
as_pg createdb "$DB"
psql_db -f "$ROOT/scripts/supabase_stubs.sql"
for f in "$ROOT"/supabase/migrations/*.sql; do psql_db -f "$f" 2>&1 | { grep -v NOTICE || true; }; done
psql_db -f "$ROOT/supabase/seed.sql"
psql_db -c "alter role dentpilot_agent password 'agent-test'" -c "alter role postgres password 'postgres-test'"

cd "$ROOT/supabase/functions"
export DENO_TLS_CA_STORE=system
export TEST_AGENT_DB_URL="postgres://dentpilot_agent:agent-test@127.0.0.1:5432/$DB"
export TEST_ADMIN_DB_URL="postgres://postgres:postgres-test@127.0.0.1:5432/$DB"

echo "→ type check + lint"
deno check */index.ts */handler.ts tests/*.ts
deno lint

echo "→ tests"
deno test -A tests/
