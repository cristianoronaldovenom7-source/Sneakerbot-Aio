# Dashboard update — 2026-09-19

- Added a first-class Live Feed navigation tab.
- Dashboard now hydrates active monitor state from the server after reload and reconnects per-task SSE streams.
- Task cards show the persisted 24/7 setting and current checkout/monitor stage when available.
- Added server health + RSS memory indicators to Live Feed.
- Added Monitor Poll Interval control (300–10,000 ms) to Settings; backend remains responsible for adaptive jitter/backoff.
- Updated browser cache-busting for dashboard JS/CSS so stale assets do not persist after deployment.
- Fixed duplicate initial global SSE snapshot emission.
- Corrected the Pokémon Center scheduler comment to 8 AM–6 PM ET.
- Corrected stale setup-guide wording about the monitor cadence and proxy behavior.
- Fixed a malformed nested address-form row in the dashboard HTML.
- Added static regression checks for the new dashboard surface and stream behavior.
