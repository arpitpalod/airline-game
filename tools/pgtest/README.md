Local migration test. From this folder:

    npm i @electric-sql/pglite
    node run.mjs ../../supabase/migrations          # add --perf for the 50-airline load test

It creates stand-ins for Supabase's roles and auth schema, runs every migration in order, then runs the
checks in `checks_2a.mjs` (reference data), `checks_2b.mjs` (player actions, daily engine) and `checks_2c.mjs`
(computer-run airlines and Stage 2c tuning, in a second, quiet world). It exits with an error if any check fails.
The first run takes about a minute, most of it building the markets.

    node season.mjs ../../supabase/migrations       # --days N, --scale X, --params '{"key": value}'

plays a full season with the computer-run airlines and 18 simulated players (nine strategies, two each), and
prints yearly results by airline, unit costs, slot use and trunk fares. About 15 minutes for 2,366 game days.
