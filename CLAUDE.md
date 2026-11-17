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
- Stage 2b (player actions, daily engine): done and live. Migrations 0004 (player actions), 0005 (daily engine) and 0006 (scheduler) are applied; every live function matches the repo file. What was built, and every rule settled along the way, is in spec section 14.2.
- World 1 is still in `setup` and has no airlines. Start it with `select public.admin_start_world('<world id>')` through the Supabase tools: that fills the lessor pool and starts the clock. The scheduler job `game-tick` already runs every 5 minutes and does nothing until a world is running.
- Stage 2c (bots, tuning): not started. Known tuning items are in spec section 17 (items 7 to 13 came out of Stage 2b).

## Working notes

- Apply migrations in `supabase/migrations/` in order through the Supabase tools; there is no direct database connection from a session.
- The Supabase tools ask the owner to confirm SQL that looks destructive. Write migrations that only add and update, and warn the owner before any step that needs a confirmation.
- In practice, a migration whose function bodies contain `delete` or `truncate` is applied without a confirmation; expect one only for statements that remove data or objects directly.
- Applying a migration means sending its whole text through the Supabase tool. Afterwards compare `md5(prosrc)` of every function in `game` and `public` between the live database and the local test database, so a copying slip cannot go unnoticed.
- Live end-to-end check that leaves nothing behind: run the actions and `game.run_day` inside one `do` block that ends with `raise exception` carrying the results. The error returns the numbers and the whole block rolls back.
- Local test: `tools/pgtest/` runs all migrations in an in-memory Postgres, then about 80 pass/fail checks (`node run.mjs ../../supabase/migrations`, add `--perf` for the 50-airline load test; about a minute). The engine checks switch the random parts off through `game_params` so results are exact. `tools/calibrate.py` is the reference market model; its numbers must match the database.
- Callers with no user id (service role, the scheduler, future bots) may act for any airline; signed-in players only for their own. Bots in Stage 2c should call the same public action functions.
- Airport coordinates come from OurAirports (`airports.csv`, downloaded per session, not committed).
