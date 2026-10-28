# Strong Architecture Release

- Up to 1,000 active/armed monitor tasks are supported by default, with a per-host armed-task limit of 100.
- Monitoring remains browserless by default; Chromium is launched only after a positive stock hit.
- Lightweight mode reduces Chromium overhead without changing the checkout workflow; browserless armed monitors remain cheap, and explicit prewarm is still honored. Actual Chromium RSS varies by site.
- Checkout concurrency remains adaptive to CPU, event-loop latency, and RAM instead of launching one browser per armed task.
- Stock-triggered checkouts enter a priority lane so a live inventory hit is served ahead of ordinary manual starts waiting for a checkout slot.
- Per-host active checkout concurrency is configurable up to 100, while the global checkout governor still protects CPU/RAM.
- Existing request coalescing, RAM-aware prewarm safeguards, SSD-backed browser profiles/cache, queue-resilient waiting, request-first cart paths, and site-specific adapters remain unchanged.
