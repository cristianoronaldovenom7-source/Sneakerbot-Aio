# Optimization Pass

This build focuses on ordinary software performance, reliability, and maintainability. CAPTCHA, queue, and anti-bot bypass behavior was not strengthened.

## Runtime optimizations
- Cached frequently-read monitor/business-hours/feature-gate settings for a short TTL.
- Parallelized monitor restore proxy/settings queries.
- Batch-loaded restore proxies instead of querying one proxy per task.
- Replaced O(n²) restore staggering lookup with an indexed loop.
- Batched checkout relation loading with `Promise.all`.
- Added keep-alive connections to the local TLS sidecar client.
- Debounced expensive in-memory cookie-jar snapshots.
- Cached URL-based stock-checker auto-detection.
- Parallelized dashboard tasks/addresses/payment-profile loading.
- Cached run-queue limits and fetched the two limits in parallel.

## Database optimizations
- Added a composite index for active site/task scheduler queries.
- Added log indexes for level/time filtering and activity sorting.

## Verification
- 136 JavaScript files pass `node --check`.
- `npm test` passes the dependency-free smoke/audit suite.
- The full Jest suite remains available when the project's dev dependencies are installed.

- Best Buy: replaced the largest fixed PDP/cart sleeps with readiness-driven waits and a shorter post-cart handoff, reducing avoidable latency on fast responses without changing checkout semantics.
- Added a persisted per-task `monitor_24_7` flag exposed in the dashboard; enabled monitors are reconciled every 60s and restored after process/container restarts.
- A successful checkout automatically disables that task's 24/7 monitor flag to prevent duplicate re-checkouts.
- Added a lightweight start.sh supervisor so an ordinary Node process crash is restarted automatically; container/VM termination and platform-level restarts still depend on the hosting provider.


### Best Buy v2 checkout hardening
- Reworked Best Buy into the same staged pipeline used by Pokémon Center: `monitorAndAtc → navigateToCheckout → fillShipping → fillPayment → placeOrder`.
- Added bounded retry/readiness checks around Add to Cart and checkout transitions instead of long fixed post-click sleeps.
- Added explicit 3DS detection before Place Order so an ambiguous bank challenge cannot cause a blind submit.
- Preserved field-level verification/reporting and tightened card-expiry fallback bookkeeping.
- Corrected Best Buy stock semantics so **online availability** is the only inventory signal that can launch online checkout; store-only inventory no longer trips the monitor.
- Updated the Best Buy drop hot-poll fallback to prefer `isAvailableOnline` before generic Add-to-Cart HTML heuristics.
- Added smoke-test coverage for Best Buy stage order, fixed-sleep regressions, online-vs-store stock semantics, and persisted 24/7 monitoring.


## Whole-program reliability pass
- Proxy failover is now transport-focused: dead/refused/timed-out proxies are quarantined with exponential cooldown, while HTTP 403/429/challenge responses are not used as proxy-health signals.
- Proxy pool DB reads are cached briefly and candidate selection excludes currently cooling-down proxies.
- Proxy-health probes use neutral connectivity targets rather than retailer/WAF responses.
- PostgreSQL pool sizing is configurable via `DB_POOL_MAX`; SQLite enables WAL + busy timeout for better 24/7 resilience.
- Added `/healthz` and changed fatal process handling to exit cleanly so the supervisor can restart a known-good Node process instead of keeping a corrupted process alive.
- Task page cache now uses `Map` and exposes explicit cleanup/size helpers.
- `start.sh` sets production defaults and restarts cleanly after both clean and fatal exits.
- RAM optimization: added cgroup-aware memory budgeting for prewarm browsers, automatically reducing/pausing parked Chromium instances under memory pressure while preserving prewarm when headroom is healthy.
- RAM optimization: completed checkout runs now release the task's cached Page reference before closing Chromium, preventing closed Page objects from accumulating in-process.
- RAM optimization: monitor status payloads are bounded (size/error/text fields) so repeated polling cannot grow dashboard state unexpectedly.
- RAM optimization: proxy-intelligence and circuit-breaker maps now self-prune at bounded sizes to prevent long-running 24/7 processes from accumulating unbounded host/proxy history.

- Pokemon Center schedule is now fixed to 8:00 AM–6:00 PM ET every day, with DST-safe New York timezone handling. The scheduler remains enabled by default and self-reconciles every 60 seconds.


## Pokémon Center / Best Buy adapter pass
- Shared browser-side readiness primitives now reduce repeated Node↔CDP selector polling.
- Pokémon Center: queue-aware checkout, DOM-based product readiness, readiness-driven variant/size transitions, and removal of fixed post-submit delays.
- Best Buy: same low-overhead selector/runtime primitives, queue-aware checkout, and bounded stage-specific recovery classification for OOS/session/queue/human-required failures.
- These changes target the same broad product qualities publicly advertised by Stellar AIO—live monitoring and an improved automation flow—without copying proprietary code or behavior. 

## Site-wide fast-path revision
- Added `helpers/site-checkout-fastpath.js` and wired it into every built-in retailer adapter.
- Retailers now avoid redundant cart navigation when the browser has already transitioned to `/cart`, `/basket`, `/bag`, or `/checkout`.
- Amazon, Demandware, and Footsites receive the same navigation-time tuning hook without changing their dedicated checkout semantics.
- Shopify retains the existing public request-first cart/checkout path; no undocumented private checkout endpoints were introduced for other retailers.
- All non-Shopify checkout adapters now attempt a conservative same-session request-first Add-to-Cart bridge from the retailer's currently rendered DOM form. The bridge is same-origin, POST-only, action-validated, and falls back immediately to the adapter's normal click flow when unsupported. Final checkout/payment/order submission remains site-specific browser logic unless a verified public request contract exists.
