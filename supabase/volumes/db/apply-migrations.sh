#!/bin/bash
# 未適用マイグレーションを冪等に適用する
# デプロイ毎に ExecStartPost から実行される（initdb.d と異なり毎回走る）

set -e

PGUSER="${POSTGRES_USER:-supabase_admin}"
PGDB="${POSTGRES_DB:-postgres}"
# `_migration_tracking` was introduced after migrations 001-032 had already
# shipped. A legacy DB without the tracker may safely baseline only that fixed
# history; every later migration must still execute.
LEGACY_MIGRATION_BASELINE=32

psql_cmd() {
  psql -v ON_ERROR_STOP=1 --username "$PGUSER" --dbname "$PGDB" "$@"
}

# tracking table の存在チェック（作成前に記録）
table_existed=$(psql_cmd -t -A -c "
  SELECT EXISTS (
    SELECT 1 FROM information_schema.tables
    WHERE table_schema = 'public' AND table_name = '_migration_tracking'
  )
")

# tracking table 作成（冪等）
psql_cmd -c "
  CREATE TABLE IF NOT EXISTS _migration_tracking (
    filename TEXT PRIMARY KEY,
    applied_at TIMESTAMPTZ NOT NULL DEFAULT now()
  )
"

# Bootstrap/recovery: public.sessions distinguishes the app schema from
# Supabase Auth's auth.sessions table. If the tracker was created but no app
# table exists, discard only the tracker rows and replay the full app history.
app_table_count=$(psql_cmd -t -A -c "
  SELECT count(*)
  FROM pg_catalog.pg_tables
  WHERE schemaname = 'public' AND tablename <> '_migration_tracking'
")

if [ "$app_table_count" -eq 0 ]; then
  psql_cmd -c "TRUNCATE TABLE _migration_tracking"
  echo "=== No Sonar tables detected: migration tracking reset ==="
fi

# Bootstrap: 既存 DB に初めて tracking を導入する場合
# → shipped legacy historyだけを適用済みとして記録し、新規migrationは通常パスで実行する
if [ "$table_existed" = "f" ]; then
  has_data=$(psql_cmd -t -A -c "
    SELECT to_regclass('public.sessions') IS NOT NULL
  ")

  if [ "$has_data" = "t" ]; then
    echo "=== Bootstrapping migration tracking (existing DB detected) ==="
    for f in /app-migrations/*.sql; do
      [ -f "$f" ] || continue
      filename=$(basename "$f")
      migration_number="${filename%%_*}"
      if [[ "$migration_number" =~ ^[0-9]{3}$ ]] && \
          [ "$((10#$migration_number))" -le "$LEGACY_MIGRATION_BASELINE" ]; then
        psql_cmd -c "INSERT INTO _migration_tracking (filename) VALUES ('$filename') ON CONFLICT DO NOTHING"
      fi
    done
    echo "=== Bootstrap complete: legacy migrations marked as applied ==="
  fi
fi

# 通常パス: 未適用マイグレーションのみ適用
echo "=== Checking for pending migrations ==="
pending=0

for f in /app-migrations/*.sql; do
  [ -f "$f" ] || continue
  filename=$(basename "$f")

  already=$(psql_cmd -t -A -c "SELECT 1 FROM _migration_tracking WHERE filename = '$filename'")

  if [ -z "$already" ]; then
    echo "Applying: $filename"
    # Keep schema changes and their tracking record atomic. A failed migration
    # must leave neither a partial schema nor a false applied marker behind.
    psql_cmd --single-transaction -f "$f" -c \
      "INSERT INTO _migration_tracking (filename) VALUES ('$filename') ON CONFLICT DO NOTHING"
    echo "Applied: $filename"
    pending=$((pending + 1))
  fi
done

if [ "$pending" -eq 0 ]; then
  echo "=== No pending migrations ==="
else
  # PostgREST caches functions and would otherwise serve the previous schema
  # after a successful migration until an unspecified future reload.
  psql_cmd -c "NOTIFY pgrst, 'reload schema'"
  echo "=== Applied $pending migration(s) ==="
fi
