#!/bin/sh
# Full local check of the app: fresh database, shim, a local build of the app, then e2e.py at phone and laptop sizes.
# Usage: sh run_e2e.sh [screenshot dir]   (default /tmp/shots). Needs: npm install here and in ../../app.
set -e
HERE=$(cd "$(dirname "$0")" && pwd)
OUT=${1:-/tmp/shots}
pkill -f "node shim.mjs" 2>/dev/null || true
pkill -f "vite preview" 2>/dev/null || true
sh "$HERE/start.sh"
psql -h /tmp -p 54322 -U postgres -qAtc "update worlds set demand_scale = 0.5, max_airlines = 25"
cd "$HERE" && node shim.mjs > /tmp/shim.log 2>&1 &
sleep 1
ANON=$(sed -n 's/anon key: //p' /tmp/shim.log)
cd "$HERE/../../app"
VITE_SUPABASE_URL=http://localhost:54321 VITE_SUPABASE_ANON_KEY=$ANON npx vite build --outDir /tmp/dist-local --emptyOutDir >/dev/null
npx vite preview --outDir /tmp/dist-local --port 4173 --strictPort > /tmp/preview.log 2>&1 &
sleep 2
rm -rf "$OUT"
python3 "$HERE/e2e.py" http://localhost:4173/airline-game/ "$OUT"
