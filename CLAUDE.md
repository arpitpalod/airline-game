# airline-game

Multiplayer airline business game for office colleagues. Read `docs/SPEC.md` before any work; it is the source of truth for rules, numbers and architecture.

- Owner works phone-only (no laptop). Every build, deploy and test step must run from a Claude session or a hosted service.
- Back end: Supabase (own project, Mumbai region). Front end: installable React web app on GitHub Pages.
- The repo is public. Never commit secrets or service keys.
- All game rules run server-side. The app never writes tables directly.
- Numbers marked (G) in the spec are tunable game values; keep them in data tables, not in code.

## Build status

- Stage 1 (spec): done.
- Stage 2a (database, rule functions, reference data): done and live in Supabase project `airline-game` (ref `ptdqbzwxvhkrwoneqptr`, Mumbai). Migrations 0001 to 0003 are applied; live numbers match `tools/calibrate.py` and the local test.
- Stage 2b (player actions, daily engine): done and live. Migrations 0004 (player actions), 0005 (daily engine) and 0006 (scheduler) are applied; every live Stage 2b function matches the repo file byte for byte (the Stage 2a `rebuild_markets` differs only by two comment lines). What was built, and every rule settled along the way, is in spec section 14.2.
- Stage 2c (computer-run airlines, tuning): built and tested locally; what was built and every rule changed is in spec section 14.3, and open items 7 to 13 are settled there. Migration 0007 is only half live. Its data part (live migration `bots_and_tuning_data`: the file from the top through the `bot_network` rows) is applied. Its functions part (live migration `bots_and_tuning_functions`: from `-- ---------- Player actions ----------` to the end of the file) is not: the Supabase tool asks the owner to confirm it. Apply that part next, then compare `md5(prosrc)` with the local test database. Do not start World 1 before then: the old engine would run with the new game values.
- World 1 is still in `setup` and has no airlines. Before starting it, set its `demand_scale` to about (expected players / 50): demand, the computer-run fleets and airport slot caps all scale with it. Start it with `select public.admin_start_world('<world id>')` through the Supabase tools: that fills the lessor pool and starts the clock; the six computer-run airlines are set up on the first game day. The scheduler job `game-tick` already runs every 5 minutes and does nothing until a world is running.

## Working notes

- Apply migrations in `supabase/migrations/` in order through the Supabase tools; there is no direct database connection from a session.
- The Supabase tools ask the owner to confirm SQL that looks destructive. Write migrations that only add and update, and warn the owner before any step that needs a confirmation.
- In practice, a migration whose function bodies contain `delete` or `truncate` is applied without a confirmation; expect one only for statements that remove data or objects directly.
- Applying a migration means sending its whole text through the Supabase tool. Afterwards compare `md5(prosrc)` of every function in `game` and `public` between the live database and the local test database, so a copying slip cannot go unnoticed.
- Live end-to-end check that leaves nothing behind: run the actions and `game.run_day` inside one `do` block that ends with `raise exception` carrying the results. The error returns the numbers and the whole block rolls back.
- Local test: `tools/pgtest/` runs all migrations in an in-memory Postgres, then 115 pass/fail checks (`node run.mjs ../../supabase/migrations`, add `--perf` for the 50-airline load test; about a minute). The engine checks switch the random parts off through `game_params` so results are exact. `tools/calibrate.py` is the reference market model; its numbers must match the database.
- Season simulation: `node season.mjs ../../supabase/migrations` plays a full season (2,366 game days, about 15 minutes) with the computer-run airlines and 18 simulated players using 9 strategies, and prints yearly results, unit costs, slot use and trunk fares. Use it to re-check tuning after changing game values.
- Callers with no user id (service role, the scheduler, the computer-run airlines) may act for any airline; signed-in players only for their own. The computer-run airlines act through the same public action functions, called from the engine.
- Airport coordinates come from OurAirports (`airports.csv`, downloaded per session, not committed).
