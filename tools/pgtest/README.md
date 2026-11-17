Local migration test. From this folder:

    npm i @electric-sql/pglite
    node run.mjs ../../supabase/migrations          # add --perf for the 50-airline load test

It creates stand-ins for Supabase's roles and auth schema, runs every migration in order, then runs the
checks in `checks_2a.mjs` (reference data) and `checks_2b.mjs` (player actions, daily engine). It exits
with an error if any check fails. The first run takes about a minute, most of it building the markets.
