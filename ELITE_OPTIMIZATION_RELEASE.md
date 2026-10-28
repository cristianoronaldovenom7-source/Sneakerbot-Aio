# Elite Optimization Release — 2026-09-20

This revision carries forward the cumulative 16-task, dashboard, proxy-role, residential-budget, RAM, Lightsail, PC/Best Buy, site-specific checkout, self-healing, and performance work.

Key performance changes:
- Max CPU profile by default, with load/event-loop safeguards.
- Up to 1,000 armed monitor tasks globally and 100 per hostname, with adaptive heavyweight checkout concurrency on capable hosts.
- Lightweight mode keeps monitors browserless; explicit prewarm remains available, while checkout browsers use lower-overhead Chromium launch settings.
- Persistent HTTP/S keep-alive tuning.
- Browser same-session cache reuse.
- Readiness-driven transitions replacing avoidable fixed sleeps across multiple retailer adapters.
- Residential monitoring reuse/coalescing remains active; direct-first escalation remains unchanged.

No new anti-bot bypass or stealth behavior was added in this optimization pass.

## Site-specific performance profiles
Each built-in retailer now has an explicit performance profile controlling warm-up strategy/path, warm pause, and site-aware orchestration. Pokémon Center retains its /en-ca/ warm path, Shopify preserves long-lived event channels during checkout, Amazon minimizes unnecessary warm navigation to preserve its authenticated session, and the remaining adapters use retailer-tuned warm/readiness budgets with shared fallback waits.
