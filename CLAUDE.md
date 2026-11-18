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
- Stage 2c (computer-run airlines, tuning): done and live. Migration 0007 is applied in two live migrations, `bots_and_tuning_data` (the file through the `bot_network` rows) and `bots_and_tuning_functions` (the rest). Every live function matches the local test database (only `rebuild_markets` differs, by the two Stage 2a comment lines). A rolled-back live run seeded the six computer-run airlines with 126 aircraft at demand_scale 0.5 and ran a day in 89 ms. What was built and every rule changed is in spec section 14.3; open items 7 to 13 are settled there.
- Migration 0010 (`admin_set_speed`, the game clock on the Admin screen) is live 19 Nov 2026 and matches the local test database.
- Migration 0011 (bulk orders and leases, extras): `order_aircraft_bulk`, `lease_aircraft_bulk`, `set_extras`, `game.anc_terms`, tables `ancillary_products` and `airline_extras`, and a redefined `game.day_ops` (extras replace the flat 8% ancillary share). Spec section 14.6. Plan for cargo, loyalty and route studies: spec section 18.
- Migration 0012 (route studies) is live 19 Nov 2026: `route_study`, `game.season_mix`, table `route_studies` (read-own); both functions match the local test database (md5). Spec section 14.7.
- Owner's rule: aircraft must never become plentiful (spec principle 6). No trading of aircraft or delivery slots between players, ever; check every new feature against it. Pilots (spec 18.4) are under discussion, not built.
- Computer-run airlines contest player routes: migration 0009 (`bot_entry`), live 19 Nov 2026; `bot_enter`, `bot_exit`, `bot_entered` and the redefined `bot_quarter` match the local test database (md5). Rules and season results in spec section 14.5.
- Stage 3 (app) and most of Stage 4 (hosting, sign-in, admin): live at https://arpitpalod.github.io/airline-game/ since 18 Nov 2026; the owner joined through the live `join` function and founded an airline. Built and tested locally first; what was built is in spec section 14.4. Live: migration 0008 (`admin_world_invite`) and the `join` edge function (JWT checks off). The app goes to GitHub Pages through `.github/workflows/pages.yml` once merged to `main`; Pages must be set to build from GitHub Actions. To make a player an admin: `update public.profiles set is_admin = true where user_id = (select id from auth.users where email = '<email>')`.
- Test World (id `348657cb-6c36-49fb-a015-2533f0163328`): the owner's playtest world, same settings as World 1 (demand_scale 0.5, bot_scale 1) but 15 minutes a game day (96x, set 19 Nov 2026 with `admin_set_speed`; World 1 is set to 60 minutes, 24x). Started 18 Nov 2026 18:04 UTC. Keep it separate from World 1; its invite code is in `world_secrets` (never commit invite codes: the repo is public). The owner (`profiles.is_admin = true`) has an airline in World 1 and will found one here.
- World 1 is still in `setup`; its only airline is the owner's. Its clock is 60 minutes a game day (24x, owner's choice for now, to revisit). Its `demand_scale` is 0.5, for about 25 players (expected players / 50): demand, the computer-run fleets and airport slot caps all scale with it. Change it only before the world starts, since the computer-run airlines are set up on the first game day. Start it with `select public.admin_start_world('<world id>')` through the Supabase tools: that fills the lessor pool and starts the clock. The scheduler job `game-tick` already runs every 5 minutes and does nothing until a world is running.

## Working notes

- Apply migrations in `supabase/migrations/` in order through the Supabase tools; there is no direct database connection from a session.
- The Supabase tools ask the owner to confirm SQL that looks destructive. Write migrations that only add and update, and warn the owner before any step that needs a confirmation.
- In practice, a migration whose function bodies contain `delete` or `truncate` is applied without a confirmation; expect one only for statements that remove data or objects directly.
- Applying a migration means sending its whole text through the Supabase tool. Afterwards compare `md5(prosrc)` of every function in `game` and `public` between the live database and the local test database, so a copying slip cannot go unnoticed.
- Live end-to-end check that leaves nothing behind: run the actions and `game.run_day` inside one `do` block that ends with `raise exception` carrying the results. The error returns the numbers and the whole block rolls back.
- Local test: `tools/pgtest/` runs all migrations in an in-memory Postgres, then 150 pass/fail checks (`node run.mjs ../../supabase/migrations`, add `--perf` for the 50-airline load test; about a minute). The engine checks switch the random parts off through `game_params` so results are exact. `tools/calibrate.py` is the reference market model; its numbers must match the database.
- Season simulation: `node season.mjs ../../supabase/migrations` plays a full season (2,366 game days, about 15 minutes) with the computer-run airlines and 18 simulated players using 9 strategies, and prints yearly results, unit costs, slot use and trunk fares. Use it to re-check tuning after changing game values.
- Callers with no user id (service role, the scheduler, the computer-run airlines) may act for any airline; signed-in players only for their own. The computer-run airlines act through the same public action functions, called from the engine.
- App: `app/` (React, TypeScript, Vite; HashRouter, so links look like `.../#/route/<id>`). The Supabase URL and publishable key in `app/.env.production` are public by design. Reads go straight to tables under row-level security; every change goes through a public function.
- App test: `sh tools/localstack/run_e2e.sh` (needs `npm install` in `tools/localstack` and `app`; about 2 minutes). It uses the local Postgres 16 in `/usr/lib/postgresql/16` and the Playwright browsers in the session. The shim supports only the PostgREST features the app uses (plain column lists, eq/neq/gt/gte/lt/lte/in/is, order, limit): keep app queries within them, or extend the shim.
- Airport coordinates come from OurAirports (`airports.csv`, downloaded per session, not committed).
