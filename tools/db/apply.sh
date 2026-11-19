#!/bin/sh
# Applies to the live database every file in supabase/migrations it has not had yet, in name order. Each file runs in
# one transaction together with its row in game.applied_files, so a file is applied completely or not at all, and never
# twice. Files applied by hand before this script existed are listed in supabase/applied_before_workflow.txt.
# Usage: DATABASE_URL=... sh tools/db/apply.sh [migrations dir] [baseline file]. Run by .github/workflows/db.yml.
# Never prints DATABASE_URL.
set -eu
: "${DATABASE_URL:?DATABASE_URL is not set}"
DIR=${1:-supabase/migrations}
BASELINE=${2:-supabase/applied_before_workflow.txt}
TMP=$(mktemp)
trap 'rm -f "$TMP"' EXIT
run() { psql "$DATABASE_URL" -X -q -v ON_ERROR_STOP=1 "$@"; }

run -c "create table if not exists game.applied_files (
  file text primary key, md5 text not null, how text not null, applied_at timestamptz not null default now())"

while read -r f; do
  case "$f" in ''|'#'*) continue ;; esac
  [ -f "$DIR/$f" ] || { echo "Baseline lists $f, which is not in $DIR"; exit 1; }
  run -c "insert into game.applied_files (file, md5, how) values ('$f', '$(md5sum "$DIR/$f" | cut -d' ' -f1)', 'before workflow') on conflict (file) do nothing"
done < "$BASELINE"

done_list=$(run -At -c "select file from game.applied_files")
n=0
for path in $(ls "$DIR"/*.sql | sort); do
  f=$(basename "$path")
  if printf '%s\n' "$done_list" | grep -qxF "$f"; then continue; fi
  sum=$(md5sum "$path" | cut -d' ' -f1)
  echo "Applying $f ($sum)"
  { echo 'begin;'; cat "$path"; printf "\ninsert into game.applied_files (file, md5, how) values ('%s', '%s', 'workflow');\ncommit;\n" "$f" "$sum"; } > "$TMP"
  run -f "$TMP"
  echo "Applied $f"
  n=$((n + 1))
done
echo "$n file(s) applied. Database is up to date with $DIR."

# Fingerprints of every rule function, to compare with the local test database.
run -At -c "select n.nspname || '.' || p.proname || ' ' || md5(p.prosrc) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
             where n.nspname in ('game', 'public') and p.prokind = 'f' order by 1"
