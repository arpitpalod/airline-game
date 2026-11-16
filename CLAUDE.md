# airline-game

Multiplayer airline business game for office colleagues. Read `docs/SPEC.md` before any work; it is the source of truth for rules, numbers and architecture.

- Owner works phone-only (no laptop). Every build, deploy and test step must run from a Claude session or a hosted service.
- Back end: Supabase (own project, Mumbai region). Front end: installable React web app on GitHub Pages.
- The repo is public. Never commit secrets or service keys.
- All game rules run server-side. The app never writes tables directly.
- Numbers marked (G) in the spec are tunable game values; keep them in data tables, not in code.

## Build status

- Stage 1 (spec): written 17 Nov 2026, awaiting review.
- Stage 2 (database, seed data, engine): not started.
