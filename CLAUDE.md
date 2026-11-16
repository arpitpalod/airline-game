# airline-game

Multiplayer airline business game for office colleagues. Read `docs/SPEC.md` before any work; it is the source of truth for rules, numbers and architecture.

- Owner works phone-only (no laptop). Every build, deploy and test step must run from a Claude session or a hosted service.
- Back end: Supabase (own project, Mumbai region). Front end: installable React web app on GitHub Pages.
- The repo is public. Never commit secrets or service keys.
- All game rules run server-side. The app never writes tables directly.
- Numbers marked (G) in the spec are tunable game values; keep them in data tables, not in code.

## Build status

- Stage 1 (spec): done.
- Stage 2a (database, rule functions, reference data): schema is live in Supabase project `airline-game` (ref `ptdqbzwxvhkrwoneqptr`). Migrations 0002 and 0003 are written and pass the local test, but are not applied yet.
- Stage 2b (player actions, daily engine) and 2c (bots, tuning): not started.

## Working notes

- Apply migrations in `supabase/migrations/` in order through the Supabase tools; there is no direct database connection from a session.
- The Supabase tools ask the owner to confirm SQL that looks destructive. Write migrations that only add and update, and warn the owner before any step that needs a confirmation.
- Local test: `tools/pgtest/` runs all migrations in an in-memory Postgres and prints the checks. `tools/calibrate.py` is the reference market model; its numbers must match the database.
- Airport coordinates come from OurAirports (`airports.csv`, downloaded per session, not committed).
