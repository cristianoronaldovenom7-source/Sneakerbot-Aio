# Effectiveness optimization pass

This pass targets reliability and latency without adding new anti-bot/stealth behavior.

- Shared selector waits now prefer browser-side mutation-driven readiness, reducing repeated Node↔Chrome polling on reactive pages.
- Pokémon Center size/quantity steps no longer use fixed 500ms sleeps; they wait for observable state instead.
- Pokémon Center and Best Buy now use stage-local recovery for transient navigation/selector/session failures before escalating to the outer task retry loop.
- Final order submission is intentionally not retried automatically.
- Terminal outcomes such as OOS, payment decline, 3DS/human-required, queue timeout, sibling win, household cap, and stop-loss are not stage-retried.
- Removed one extra database lookup per retry for proxy host metadata by carrying the host through the run result.
- Existing RAM guardrails, 24/7 monitor persistence, Pokémon Center 8am–6pm ET scheduling, prewarm adoption, and operational telemetry remain unchanged.

## Workflow upgrade

- Hot-stock monitor handoffs now skip the second `start_at`/drop watcher wait; a monitor-triggered task proceeds directly into preflight/browser checkout.
- `startTask()` is now single-flight per task ID. Duplicate dashboard starts, scheduler/manual races, and overlapping monitor triggers join the same promise instead of queueing a second potential purchase.
- Pokémon Center and Best Buy adapters now publish stage-level workflow events (`running` / `completed`) to both task-specific and global SSE feeds and persist `last_status` for the active stage.
- Pokémon Center guest-checkout readiness now uses the shared mutation-aware selector wait instead of a fixed 300 ms polling loop.
- Added regression coverage for hot-stock handoff and duplicate-start protection.

- Added role-separated proxy assignments: monitoring and checkout can now use different sticky endpoints without breaking legacy `proxy_id` tasks.
- Added a provider-neutral residential gateway option via `RESIDENTIAL_PROXY_URL` plus role-specific environment overrides. Credentials remain outside the task DB.
- Checkout transport failover now prefers backups of the same proxy type (e.g. residential → residential), while direct/environment gateways are not automatically rotated by the DB pool.

## Additional runtime optimizations (2026-09-19)
- Added hot-path database indexes for persistent-monitor reconciliation, active-monitor ordering, run-status analytics, and proxy type filtering.
- Added a 2s dashboard aggregate-stat cache to cut repeated count/aggregation queries while the UI is open.
- Reduced monitor SSE fan-out by coalescing duplicate global monitor payloads and dropping writes to backpressured/dead connections.
- Parallelized monitor restoration and 24/7/PC scheduler reconciliation with conservative concurrency and shorter startup staggering.
- Cached the prewarm parked-browser cap setting to avoid one settings-table lookup per monitor prewarm decision.
- Reused a single Eastern Time formatter and a single process.memoryUsage() snapshot per memory check.
- Converted repetitive stock-monitor API/result logging from INFO to DEBUG to reduce console I/O on high-frequency polling paths.
- Avoided rewriting the persisted cookie jar when an incoming Set-Cookie sequence produces no effective change.
- Switched monitor latency metrics to a ring-buffer write path instead of push+shift allocations.
- Added a 1 GiB/month residential bandwidth budget with persistent monthly accounting. In strict mode, new residential sessions are blocked once the budget/headroom is exhausted.
- Changed Auto monitor routing so residential environment gateways are NOT used for monitoring by default; monitoring stays direct unless a residential monitor proxy is explicitly assigned. Checkout retains the residential gateway fallback.
- Added residential response-traffic accounting for HTTP monitor checks and encoded browser traffic accounting for residential checkout sessions.
- Exposed residential bandwidth usage/remaining budget through the proxy metadata API.

- Pokémon Center no-proxy monitoring: stable User-Agent per host, a 2.2s minimum direct poll interval, and a 60s→15m access-denial backoff. The task remains armed instead of spinning or dying when direct monitoring is temporarily denied.
- Dashboard monitor state now exposes `access_limited`, `retryAt`, and the access-denial streak for visibility.
- Residential bandwidth budgets are now role-separated: 1 GiB/month for monitoring and 1 GiB/month for checkout by default.
- Pokémon Center monitoring in Auto mode remains direct until an access denial; when a configured residential monitoring gateway is available and its 1 GiB role budget has headroom, the monitor promotes to that gateway and keeps it sticky for the active monitor session.
- Checkout continues to prefer the configured residential checkout gateway with its separate 1 GiB monthly allowance.
- Dashboard proxy status now shows monitoring and checkout residential usage independently.

## 2026-09-19 resource-efficiency pass
- Added 300 ms cross-task stock-check coalescing for identical URL/site/size/style/network combinations; simultaneous monitors now share one request without slowing unique tasks.
- Added HTTP validator support (ETag / Last-Modified) for monitor API and HTML checks; compliant origins can return 304 instead of resending full product pages.
- Cached the parsed result associated with each validator so a 304 can be resolved without reparsing or launching another request.
- Kept validator/coalescing caches bounded to 500 entries to avoid long-run RAM growth.
- Kept residential fallback policy unchanged: direct monitoring first in Auto mode, residential only when needed/configured; checkout remains independently routed.

## 2026-09-20 CPU high-performance profile
- Added `helpers/cpu-performance.js` for host-aware CPU/RAM sizing and load-aware concurrency.
- `start.sh` now defaults to `CPU_PERFORMANCE_MODE=max` on dedicated deployments, with an adaptive concurrency target of 6-10 tasks subject to available logical CPUs and ~1.5 GB/task browser budget.
- Raised default DB pool from 5 to 8 and Node libuv thread pool from 4 to 8 for better parallel HTTP/TLS/file work on multi-core hosts.
- Run queue now exposes CPU/load telemetry and briefly throttles new work under sustained CPU saturation instead of allowing thermal/load thrash.
- Prewarm can use up to 4 parked browsers in max mode when memory headroom is available; memory pressure still overrides this cap.

- Checkout-wide performance pass: shared mutation-driven selector readiness across Amazon/Demandware/Footsites/GameStop/Nike/Shopify/Supreme/Topps/Walmart.
- Verified fast main-frame form fill added; hosted payment iframes keep the existing compatibility path.
- Fast checkout click path added for quick-mode pages with fallback to the existing click path.
- Non-PC warm-up URL corrected to use site root; Pokémon Center retains /en-ca/.
- Informational request-mode probe removed from the hot path unless explicitly enabled.
- Stale Target site registry entry now fails clearly instead of throwing a dynamic-import module-not-found error.
- Final checkout-speed pass: fast verified native select path in fast UI mode; old click+delay selection remains as fallback.
- Across adapters, legacy selector loops now use mutation-driven readiness waits to reduce Node↔Chrome polling overhead.
- Main-frame form fields use verified direct DOM filling in fast mode; hosted PCI/payment iframes retain the existing compatibility path.
- Quick-mode checkout pages can use direct Puppeteer clicks with automatic fallback to the existing mouse path.

## 2026-09-20 hardware/network performance pass
- Added persistent direct HTTP/HTTPS keep-alive agents for monitor/drop-watcher traffic to reduce TCP/TLS setup on repeated checks.
- Added foreground scheduling flags for Chromium timers/renderers so active checkout pages are less likely to be background-throttled.
- Made Chromium /dev/shm behavior container-aware: normal hosts can use tmpfs, while containers retain the safe fallback.
- Enabled explicit browser HTTP cache reuse for same-session navigations.
- Exposed CPU, memory, concurrency, and network-pool telemetry at /healthz.
- Added host-performance environment knobs for dedicated 8-16 GB systems.

- Elite performance pass: event-loop-p95 aware concurrency governor, 12-task max default on capable CPUs, 12-thread libuv pool on max mode, larger keep-alive socket pools, adaptive 16 GB prewarm capacity up to 6 parked browsers under low memory pressure, and reduced hot-path queue logging.
- Residential-efficiency pass: when multiple tasks watch the same product through a residential fallback, residential results are now shared for a short 1.5s window instead of only 300ms, reducing duplicate residential responses while keeping freshness tight.
- Residential monitoring drops back to direct polling after 2 clean residential polls (configurable with `RESIDENTIAL_MONITOR_CLEAN_POLLS`) rather than spending 5 consecutive residential polls during transient access blocks.
- Direct monitoring remains the default in Auto mode; residential bandwidth is still promoted only after access is blocked and a configured residential gateway has budget headroom.


## Elite whole-program pass — 2026-09-20
- Default runtime performance profile now starts in max mode while remaining load-aware.
- Adaptive heavyweight checkout concurrency can reach 10 on capable hosts; 16 tasks remain armable/queued.
- Direct HTTP agents use keep-alive tuning and a bounded total-socket cap.
- Chromium same-session HTTP cache remains enabled to reduce repeated downloads.
- Removed several fixed site-transition sleeps and replaced them with readiness/state waits across Amazon, GameStop, Nike, Shopify, Supreme, Target, Topps, and Walmart.
- Residential monitoring coalescing and 1.5s fallback-result reuse remain enabled to minimize residential bandwidth.
