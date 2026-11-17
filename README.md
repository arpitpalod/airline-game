# airline-game

A persistent multiplayer airline business game: about 50 airlines per world compete for the same passengers, aircraft and airport slots.

- Game rules and build plan: [docs/SPEC.md](docs/SPEC.md)
- Status: database, engine and computer-run airlines are live (Stages 1 to 2c). The app (Stage 3) is in [app/](app/) and is published to GitHub Pages from `main`.
- App: one React web app that works on phones and laptops and installs to a phone's home screen. Local end-to-end test: `tools/localstack/run_e2e.sh`.
