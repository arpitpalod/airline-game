#!/bin/sh
# Local stack for the app: Postgres 16 with every migration, plus shim.mjs (auth, REST and the join function).
# Usage: sh start.sh [data dir]   (default /tmp/airline-pg). Rebuilds the database from scratch.
set -e
HERE=$(cd "$(dirname "$0")" && pwd)
DATA=${1:-/tmp/airline-pg}
BIN=/usr/lib/postgresql/16/bin
PORT=${PGPORT:-54322}
su postgres -c "$BIN/pg_ctl -D $DATA stop -m fast" >/dev/null 2>&1 || true
rm -rf "$DATA"; mkdir -p "$DATA"; chown postgres "$DATA"
su postgres -c "$BIN/initdb -D $DATA -A trust -U postgres" >/dev/null
su postgres -c "$BIN/pg_ctl -D $DATA -o '-p $PORT -k /tmp' -l $DATA/log.txt start" >/dev/null
sleep 1
PSQL="psql -h /tmp -p $PORT -U postgres -d postgres -v ON_ERROR_STOP=1 -q"
$PSQL -f "$HERE/stub_auth.sql"
for f in "$HERE"/../../supabase/migrations/*.sql; do $PSQL -f "$f" >/dev/null && echo "ok $(basename $f)"; done
