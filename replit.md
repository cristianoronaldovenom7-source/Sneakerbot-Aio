# SneakerBot

SneakerBot is a Node.js/Express API that automates checkout on various sneaker websites using Puppeteer. The bot supports Footsites, Shopify, Demandware, Nike.com, and Supreme. It exposes REST endpoints for managing addresses, proxies, and tasks.

## Tech Stack

- **Framework:** Express 4
- **Database:** PostgreSQL via Knex.js
- **Browser automation:** Puppeteer / puppeteer-extra (with stealth)
- **Validation:** Joi + express-validation
- **Notifications:** Nodemailer (email) and HTTP webhooks
- **Logging:** Winston

## Project Structure

- `app.js` — Express entry point
- `routes/index.js` — Top-level router mounted at `/v1`
- `api/` — Route handlers (Addresses, Proxies, Tasks, Logs, Settings)
- `db/` — Knex setup, migrations, seeds
- `helpers/` — Shared utilities (logger, cluster, captcha, email, webhook, states, task-cache, validation-handler, stock-monitor, session-warmer, cookie-store, datadome, akamai, human-type, monitor-store, fingerprint-store, cf-clearance, geo-consistency, order-capture, run-queue, rebrowser-bootstrap, drop-watcher, identity-rotator, resource-blocker, decline-detector, cookie-pool, notifier, prewarm-engine)
- `helpers/captcha.js` cascades 2Captcha → CapMonster → AntiCaptcha with a 90s global solve budget (configurable via `captcha_total_budget_ms` setting), optionally adding a manual harvester provider (settings: `harvester_enabled`, `harvester_position` first/last, `harvester_mode` in_page/tab, `harvester_max_wait_ms`)
- `helpers/captcha-harvester.js` + `/v1/harvester/*` API + `public/harvester.html` — manual captcha solving. `in_page` mode (default) pauses the bot's puppeteer page so the human solves on the real target domain (tokens always accepted). `tab` mode pushes to a separate browser tab UI but tokens may be rejected by hostname-bound sitekeys.
- `tls-sidecar/` (Go) + `helpers/tls-client.js` — Chrome 131 TLS/JA3 fingerprint forging via bogdanfinn/tls-client. Runs as a separate workflow on `0.0.0.0:8099` (Replit auto-maps the port externally; **HARDENED** against the resulting exposure). All "stealth" HTTP probes (drop-watcher) go through it so the JA3 hash matches Chrome instead of Node/OpenSSL. Graceful fallback to got-scraping if sidecar is down.
  - **Auth**: random 64-hex token generated at startup (or `TLS_SIDECAR_TOKEN` env), written atomically with `O_EXCL` mode 0600 to `/tmp/tls-sidecar.token`. `/request` requires `Authorization: Bearer <token>` (constant-time compare). `/health` stays public for Replit's port probe. Node bridge auto-reads the token file and refreshes on 401.
  - **SSRF guard**: scheme must be http/https; hostname IP-resolved and rejected if loopback/private (RFC1918)/link-local/unspecified/cloud-metadata (169.254.169.254 + AWS IPv6); user-supplied `proxy` rejected unless `TLS_SIDECAR_ALLOW_PROXY=true`. Auto-redirects disabled at the client level — sidecar manually loops up to 5 hops, re-running validation on every `Location` (closes 30x-to-private bypass).
  - **Strict mode** (recommended for prod): set `TLS_SIDECAR_ALLOW_HOSTS=pokemoncenter.ca,topps.com` to enforce a name-based allowlist (suffix match). This eliminates DNS-rebinding TOCTOU because rebinding requires controlling the target domain's DNS, which an attacker doesn't for retailer hostnames.
- `orders/task-<id>/` — Order success captures: full-page screenshot + JSON receipt per successful checkout
- `sites/` — Per-site checkout automation (footsites, shopify, demandware, nike, supremenewyork, pokemoncenter, topps, walmart, bestbuy, target, gamestop, amazon). All 12 adapters have complete form-fill checkout flows with humanType, FillReport, findFirst selector arrays, iframe-aware card entry, retry logic, and order confirmation detection.
- `scripts/start-task.js` — CLI and programmatic task runner
- `__tests__/` — Integration tests (Jest + supertest + knex-mock-client)

## API Endpoints

### Addresses `/v1/addresses`
- `GET /` — List all addresses
- `GET /:id` — Get one address
- `POST /` — Create address
- `PATCH /:id` — Update address
- `DELETE /:id` — Soft-delete address
- `POST /:id/jig?count=N` — Create N jigged variants (email +tags, name initials, street/apt micro-changes) to bypass per-address purchase limits

### Proxies `/v1/proxies`
- `GET /` — List all proxies
- `GET /:id` — Get one proxy
- `POST /` — Create proxy
- `PATCH /:id` — Update proxy
- `DELETE /:id` — Soft-delete proxy
- `POST /:id/health` — Test proxy latency + reachability (Pokemon Center, Topps); SSRF-guarded against private IPs
- `POST /health/all` — Test every proxy (concurrency 4)

### Tasks `/v1/tasks`
- `GET /` — List all tasks
- `GET /:id` — Get one task
- `POST /` — Create task
- `PATCH /:id` — Update task
- `DELETE /:id` — Soft-delete task
- `POST /:id/start` — Start task (launches Puppeteer)
- `POST /:id/stop` — Stop task (closes Puppeteer page)
- `GET /:id/preflight` — Run preflight (luhn / expiry / address sanity / proxy warning)
- `POST /:id/clone` — Bulk-clone task with optional round-robin over `shipping_address_ids`, `payment_profile_ids`, `proxy_ids`
- `POST /start-group` — Fire up to 50 tasks simultaneously (accepts `task_ids` array, `tag`, or `site_id`)

### Runs `/v1/runs`
- `GET /` — Paginated run history (`?task_id=&status=&limit=&offset=`)
- `GET /stats` — Aggregate success rate + avg duration per site
- `GET /speed` — Per-site average stage timings (speed telemetry: cold browser launch / page / blocker / cookies / warm / adapter + monitor→checkout handoff). Powered by `helpers/stage-timer.js` (`StageTimer` + `aggregateStageTimings`); persisted in `task_runs.timings` (jsonb). Instruments runOnce-level phases only (not adapter internals, to avoid regressing the unverifiable checkout path).
- `GET /export.csv` — Download all runs as CSV
- `DELETE /` — Wipe run history

### Logs `/v1/logs`
- `GET /` — List all logs
- `GET /:id` — Get one log
- `GET /task/:taskId` — Get logs for a task
- `DELETE /:id` — Delete log

### Payment Profiles `/v1/payment-profiles`
- `GET /` — List all payment profiles
- `GET /:id` — Get one payment profile
- `POST /` — Create payment profile (Joi credit card validation)
- `PATCH /:id` — Update payment profile
- `DELETE /:id` — Soft-delete payment profile

### Settings `/v1/settings`
- `GET /` — List all settings
- `GET /:key` — Get one setting
- `PUT /:key` — Upsert a setting

## Supported Sites (site_id)
| site_id | Site                           |
|---------|--------------------------------|
| 1       | Footsites                      |
| 2       | Shopify                        |
| 3       | Demandware                     |
| 4       | Nike                           |
| 5       | Supreme NY                     |
| 6       | Pokemon Center Canada (en-ca)  |
| 7       | Topps                          |
| 8       | Walmart Canada                 |
| 9       | Best Buy Canada                |
| 10      | Target                         |
| 11      | GameStop Canada                |
| 12      | Amazon Canada                  |

## Task Fields — Quantity & Household Cap

- `quantity` (integer, default 1, max 10): number of units to add to cart. Every site adapter sets the quantity selector before clicking ATC.
- `household_limit` (integer, nullable): max successful orders allowed per shipping address. Checked before each run by counting `task_runs` with `status='success'` for the same `shipping_address_id`. When the cap is reached the task is auto-disabled with `last_status='household_cap'`.

## Database

- The Replit-managed PostgreSQL database is used. `knexfile.js` reads `DATABASE_URL` (with `PG*` fallbacks), so no manual `.env` is required for the database.

## Settings Keys

| Key                   | Description               |
|-----------------------|---------------------------|
| `webhook_url`         | HTTP webhook for alerts   |
| `captcha_api_key`     | 2Captcha API key          |
| `discord_webhook_url` | Discord webhook URL       |
| `prewarm_enabled`     | Prewarm speed engine (empty=off, `true`/`1`=on) |
| `prewarm_max_parked`  | Max concurrent parked browsers (1–10, default 3) |
| `monitor_poll_ms`     | Stock monitor poll interval in ms (300–10000, default 1000). Set lower to react faster to restocks; set higher to reduce request rate on hard-to-reach sites. |
| `pc_business_hours_enabled` | Pokemon Center (site_id 6) auto start/stop scheduler. Default ON; set `false`/`0`/`off`/`no` to disable (then PC behaves like any other site). |

## Pokemon Center Business Hours (site_id 6 only)

Pokemon Center tasks auto-run **only 8am–6pm ET** (8am inclusive, 6pm exclusive). No other site is affected.

- `helpers/business-hours.js` — DST-safe ET hour via `Intl.DateTimeFormat('America/New_York')` (no manual offset math). Exports `PC_SITE_ID`, `isWithinBusinessHours`, `businessHoursEnabled`.
- **Scheduler** (`api/Tasks/monitor.js` `startPcBusinessHoursScheduler`, wired in `app.js` boot): a 60s reconciliation sweep auto-starts every eligible PC task at 8am ET and auto-stops it at 6pm ET. Level-triggered, so it self-heals across restarts and DST changes.
- **No-resurrect guard:** the sweep skips tasks whose `last_status` is `success`/`needs_human`/`household_cap` (never re-fires checkout on a won task or loops a 3DS task) and skips tasks the user manually stopped mid-window (`pcUserStopped`, cleared at the 8am open).
- **Boundary buys complete:** a monitor-triggered checkout (`task._instockAt` set) is allowed to finish even after 6pm — a detected drop is never dropped. Manual starts outside hours no-op with `last_status='outside_hours'`; `startMonitor` returns HTTP 409 outside hours.
- **Defense in depth:** `makeTick` self-pauses a PC monitor if it ever drifts past 6pm before the sweep fires.
- Tested in `__tests__/integration/business-hours.test.js` (EST + EDT boundary cases).

## Reliability Engine (Stock Monitoring)

Professional-grade reliability layer wrapping every `checkStock()` call. The raw
check lives in `runStockCheck()`; `checkStock()` wraps it with three guards plus
a last-resort try/catch so a monitor can never die from an unhandled throw.

| Layer | File | Purpose |
|---|---|---|
| Per-host circuit breaker | `helpers/circuit-breaker.js` | CLOSED→OPEN→HALF_OPEN per hostname. Opens after 5 consecutive failures, exponential cooldown (30s→5min cap), single probe in HALF_OPEN. When OPEN, `checkStock` short-circuits without hitting the network — protects the proxy pool and lets a blocked site recover instead of being beaten into a permanent ban. |
| Result validation | `validateStockResult()` in `helpers/site-stock-apis.js` | A false-positive "in stock" fires a real checkout (burns session/proxy/captcha, risks a wrong order). So `inStock` must be a **strict boolean true** — never a truthy accident. An in-stock claim with no name/price/sizes is downgraded to low-confidence and NOT acted on; the next poll re-confirms. Bias is always toward false-negative. |
| Per-host metrics | `helpers/monitor-metrics.js` | Tracks checks / inStock / outOfStock / blocked / errors, success rate, block rate, API-resolve rate, and latency p50/p95/max (ring-buffered, last 100). Lets you tell "site is hard-blocking from this IP" (high block rate) apart from "parser is wrong" (high checks, low inStock, low block rate). |
| Scheduler coordination | `api/Tasks/monitor.js` (`makeTick`) | When the breaker is OPEN/HALF_OPEN, the next poll is scheduled off the breaker's `retryInMs` (not adaptive backoff), so polling actually cools down. `startMonitor` runs exactly one check at startup (no double-counting against the breaker). |

**Observability endpoint:** `GET /v1/tasks/monitors/reliability` returns the live
metrics + circuit states snapshot for every host.

Covered by `__tests__/integration/reliability.test.js` (circuit breaker
transitions/isolation, strict validation / false-positive prevention, metric
aggregation).

## Anti-Bot Bypass Stack

Layered defense for sites with WAF/bot protection (Imperva, DataDome, Akamai, Cloudflare).

| Layer | File | Purpose |
|---|---|---|
| TLS/JA3 fingerprint | `helpers/stock-monitor.js` (got-scraping + http2) | Real Chrome TLS handshake |
| Per-request fingerprint sync | `helpers/stock-monitor.js` | Sec-CH-UA matched to UA, jittered referer pool |
| Adaptive backoff | `helpers/stock-monitor.js` | Exponential 2s→60s on consecutive blocks |
| Cookie merge (per-name) | `helpers/stock-monitor.js` | Preserves Imperva/DataDome cookies across responses |
| Disk-persisted cookie jar | `helpers/cookie-store.js` (`.local/cookie-jar.json`) | Survives restarts; 9-min TTL filter |
| Imperva session warmer | `helpers/session-warmer.js` | Stealth Chromium 131 solves JS challenge, mouse/scroll entropy |
| Auto-refresh scheduler | `helpers/session-warmer.js` (`startAutoRefresh`/`stopAutoRefresh`) | Re-warms every 4.5 min before TTL expires; cancelled by `clearMonitor` |
| 3 rotating fingerprint profiles | `helpers/cluster.js` | Windows/macOS, Chrome 123/124, varying cores/mem/GPU/timezone |
| CDP STEALTH_SCRIPT | `helpers/cluster.js` | Webdriver/plugins/WebGL/canvas-noise/audio-noise/battery/WebRTC-block/connection-spoof injected via `Page.addScriptToEvaluateOnNewDocument` before any site JS runs |
| UC-mode Chrome flags | `helpers/cluster.js` | 25+ flags (disable-blink-automation, force-webrtc-handling, etc) |
| Stealth plugin | `helpers/cluster.js` | puppeteer-extra-plugin-stealth |
| DataDome solver | `helpers/datadome.js` | Full payload generator (190+ fields), 2Captcha fallback |
| Akamai BMP | `helpers/akamai.js` + `vendor/akamai-bmp/` (Go server :1337) | Sensor data + `_abck` cookie generation; 2056 device profiles |
| 2Captcha integration | `helpers/captcha.js` | hCaptcha / reCAPTCHA / Turnstile auto-solve |
| React-aware human typing | `helpers/human-type.js` | Native value setter + fiber `__reactProps$` walk; 55-140ms jitter; 2.5% typo+backspace; iframe-aware (Adyen/CyberSource) |
| Pre-flight referer chain | `scripts/start-task.js` | Visit homepage → scroll → wait → product (mimics organic navigation) |
| In-place Imperva warm | `scripts/start-task.js` + `helpers/session-warmer.js` (`warmInPlace`) | Warms session in the SAME checkout browser (cookies bound to that browser's fingerprint, no transfer needed) |
| Imperva challenge resolver | `helpers/session-warmer.js` (`waitForImpervaToResolve`) | Polls for absence of Incapsula iframe + bodyLen>1500 before declaring page loaded |
| Proxy plumbing (full stack) | `helpers/cluster.js`, `helpers/session-warmer.js`, `helpers/stock-monitor.js`, `api/Tasks/monitor.js` | Per-task proxy via `tasks.proxy_id` → loaded from `proxies` table → threaded through warmer + checkout browser + got-scraping HTTP poller |
| Cookie protection on transient 403 | `helpers/stock-monitor.js` | Cookies <5 min old are NOT wiped on 403 (avoid self-sabotage during retry) |
| Jittered polling | `api/Tasks/monitor.js` | 1700-2300ms intervals via self-rescheduling setTimeout chain (defeats interval detection) |
| Smart skip on Imperva hosts | `helpers/stock-monitor.js` | Pokemon Center / Foot Locker / Finish Line skip DataDome+Akamai checks (false-positive prevention) |

## Pokemon Center (Imperva) — Real-World Status

**Confirmed working from Replit datacenter IPs:**
- HTTP stock polling via got-scraping (TLS fingerprint passes Imperva, returns `blocked=false`)
- Cookie warming, persistence, in-place warming on checkout browser
- All form-fill code paths (humanType, humanSelect, iframe-aware typing, SFCC selectors)

**Confirmed BROKEN from Replit datacenter IPs:**
- Puppeteer browser navigation to ANY pokemoncenter.com page returns the Incapsula iframe challenge shell (~574 bytes) and never resolves, even after 40+ second waits. The challenge JS in the iframe detects the datacenter ASN and refuses to release cookies.
- Without the page rendering, ATC, checkout, form-fill, and place-order cannot execute.

**To unblock:** Add a residential or mobile proxy via `POST /proxies` (host/port/username/password), then set `tasks.proxy_id` on the task. The full stack (warmer + browser + HTTP poller) automatically routes through it. No further code changes needed.

## Unattended Checkout Safety (Fail-Loud)

The bot runs while you sleep, so a silent wrong/partial order is worse than no order.
Checkout now fails LOUD instead of guessing (focused on the two main targets, Pokemon
Center site_id 6 and Walmart site_id 8):

- **Critical-field assertion before Place Order** (`assertCriticalFields` in
  `helpers/autofill-utils.js`): if a load-bearing field (address1/city/postal/phone/
  email, card name/number/cvv/expiry) didn't fill, the run aborts with
  `checkout_fill_failed` *before* submit. Province/state is intentionally NOT critical
  (a dropdown value-format mismatch must not false-abort an otherwise-complete order).
- **3D Secure → manual hand-off** (`human_required`): the bot can't solve bank OTP/SMS,
  so on 3DS it sends a loud "finish this manually" alert and stops *without* clicking
  Place Order (clicking into 3DS leaves an ambiguous "did it order?" state). The task
  is marked `last_status='needs_human'`; the runner does NOT retry it or count it
  against stop-loss.
- **Never accept a suggested address rewrite** (`chooseAddressKeepButton` /
  `dismissAddressSuggestion`): the address-verification modal is dismissed by keeping
  the address you entered. Only explicit "use original / use the address you entered /
  keep my address / as entered" buttons are clicked; ambiguous "Use this address /
  Confirm / Continue" buttons are never clicked (they may select the site's rewritten
  address → failed delivery). The click step re-verifies the button text to survive DOM
  reordering.
- Covered by `__tests__/integration/checkout-hardening.test.js`.

> **Reality check — checkout needs a residential/mobile proxy.** From Replit's
> datacenter IPs, Puppeteer browser navigation to Pokemon Center (Imperva) and Walmart
> (PerimeterX) is hard-blocked (the page returns a ~1KB challenge shell and never
> resolves). HTTP *stock detection* works from here, but the *browser checkout* will
> not until you add a residential/mobile proxy (`POST /proxies`, then set
> `tasks.proxy_id`). No code change needed — the whole stack auto-routes through it.

## Mid-Checkout Bot Bypass (All 12 Adapters)

Every site adapter now uses the centralized checkout-guards system (`helpers/checkout-guards.js`) for mid-checkout bot detection and recovery. Previously only PokemonCenter and Topps had this coverage.

| Guard | When It Runs | What It Does |
|---|---|---|
| `guardedGoto` | Every `page.goto` (PDP, cart, checkout) | Detects queue pages + bot blocks after navigation. Auto-waits up to 5 min for queues. Calls recovery cascade. |
| `postClickGuard` | After every checkout transition click (cart→checkout, guest checkout, continue shipping/payment, save address, submit) | Lightweight bot-block check after each state change. Auto-recovers if blocked. |
| `preOrderGuard` | Before clicking "Place Order" | Checks for bot blocks + 3D Secure before final submit. Prevents charges on blocked pages. |
| `takeFailureScreenshot` | On any checkout failure | Saves full-page screenshot to `/tmp/sneakerbot-shots/`. |
| `detectQueuePage` / `waitForQueueToPass` | Inside `guardedGoto` | Detects Queue-it, Cloudflare Waiting Room, generic queue text. Waits up to 5 min. |
| `attemptBlockRecovery` | When a bot block is detected | Cascading recovery: Imperva → Cloudflare auto-wait → Turnstile → reCAPTCHA/hCaptcha → PerimeterX (with optional captcha solve) → DataDome (30s wait) → Akamai/Kasada (15s wait) → generic 15s fallback. |

### Bot-Block Detection Coverage (`detectBotBlockOnPage`)
Detects 28+ block signatures including: Cloudflare ("just a moment", "checking your browser"), Imperva ("pardon our interruption"), PerimeterX ("press & hold", `px-captcha`), DataDome (`captcha-delivery.com`), Kasada (`kpsdk`), FingerprintJS Pro (`fpjs.io`), Akamai sensor, AWS WAF, F5/Shape, plus generic challenges ("verify you are human", "rate limited", "automated access", "bot protection").

### Cloudflare Turnstile (5-source sitekey extraction + callback execution)
1. **Render-hook capture** — `helpers/cluster.js` injects a `window.turnstile.render()` proxy into every page that captures `sitekey`, `callback`, `action`, `cdata` into `window.__turnstileCapture`. Catches sites that init Turnstile programmatically.
2. **`data-sitekey` widget** — standard `.cf-turnstile[data-sitekey]`.
3. **Any `[data-sitekey]`** element fallback.
4. **Iframe URL parse** — extracts `?k=<sitekey>` from `challenges.cloudflare.com` iframe.
5. **Inline script regex** — finds `sitekey: "..."` in inline `<script>` tags.

After token solve, `injectTurnstileToken` fills hidden inputs, dispatches `input`+`change` events, calls the captured render-hook callback, the named global `data-callback`, and standard CF callbacks (`onloadTurnstileCallback`, `turnstileCallback`, etc.) to actually unlock the form.

### Checkout Success Hardening
Improvements layered on top of bot bypass to maximize the chance an order actually completes:

| Helper | Where | What It Prevents |
|---|---|---|
| `verifyCartHasItem` (`autofill-utils.js`) | After cart load in Shopify + Nike | Stops the bot from "checking out" an empty cart when ATC silently failed (size lost, OOS, session dropped). Throws a clear OOS-classified error so the restock loop kicks in. |
| `requireCardIframe` (`autofill-utils.js`) | Before payment fill in Shopify, Nike, Demandware, Footsites, Supreme | Throws if the card iframe doesn't load instead of silently typing into the void. Surfaces real iframe failures fast. |
| `isSessionFailure` + `session_expired` retry branch (`decline-detector.js`, `start-task.js`) | Whole task lifecycle | High-traffic drops sometimes invalidate the cart/session mid-checkout. The bot now classifies these as `session_expired` and retries with a fresh browser **without burning a retry attempt** (1× grace), the same pattern used for OOS. |
| Expanded decline patterns (4 new) | `decline-detector.js` | Catches AVS mismatch, CVV2 mismatch, 3D Secure failures, and payment-gateway errors. These previously fell through to "generic failure" and didn't trigger the payment-profile swap. |

### Tests
- `__tests__/integration/checkout-guards.test.js` — 23 tests covering bot detection (Cloudflare, Imperva, PerimeterX, DataDome, Kasada, FingerprintJS), queue/3DS detection, and Turnstile sitekey extraction + token injection.
- `__tests__/integration/checkout-success.test.js` — 14 tests covering decline pattern coverage, `detectDecline` classification (including session-expired), `verifyCartHasItem` (empty / counted / item-listed), and `requireCardIframe` throw-vs-warn behavior.

Run all tests via `npm test`.

## Pro-Bot Parity Features

### Resource Blocker (`helpers/resource-blocker.js`)
Blocks images, fonts, media, and 30+ tracker domains (Google Analytics, Facebook Pixel, Hotjar, Sentry, etc.) via Puppeteer request interception. Two modes: `checkout` (blocks all non-essential resources) and `monitor` (allows only document/XHR/fetch/script). Cuts page load time by 2-3x.

### Decline Detector + Profile Swap (`helpers/decline-detector.js`)
Detects payment declines, OOS errors, and address rejections using 30+ regex patterns scraped from error elements on the page. When a decline is detected mid-checkout, the retry loop auto-swaps to an alternate payment profile (up to 2 swaps) without burning a retry attempt.

### Cookie Pool (`helpers/cookie-pool.js`)
Shares warm Imperva/Cloudflare cookies across tasks targeting the same site. 4-minute TTL. When task A solves a challenge on footlocker.com, task B/C/D skip the warm-up entirely by injecting pooled cookies. Injects on page open, harvests after successful site adapter run.

### Restock Retry Loop
When a product goes OOS mid-checkout, the task re-enters the drop watcher hot poll (up to 3 restock loops) instead of burning a retry attempt. Sends a Discord notification on each restock wait.

### Parallel Task Firing (`POST /v1/tasks/start-group`)
Fire up to 50 tasks simultaneously via `Promise.allSettled`. Accepts `task_ids` (array), `tag` (string), or `site_id` (number). Background execution with per-task error isolation.

### Rich Discord Webhooks (`helpers/notifier.js`)
Site name + logo thumbnails for all 12 sites, clickable product links, speed field, branded footer with timestamp. Supports `siteId` passthrough for site-specific embeds.

### Browser Speed Mode
All 12 site adapters use `waitUntil: 'domcontentloaded'` instead of `networkidle2` for page navigation. Combined with the resource blocker, this typically shaves 1-3 seconds per navigation step.

### Beat-The-Bots Speed + Stealth Upgrades
Speed (win the race against other sneaker bots) and stealth (don't trip detection) upgrades layered on top of the pro-bot parity stack:
- **Shopify JSON ATC fast-path** (`sites/shopify/index.js` `tryJsonAtc`) — POSTs to `/cart/add.js` with the variant ID before any UI click. Skips PDP rendering entirely (~1.5–3s saved). Variant ID extracted from URL `?variant=`, then `<select name="id">`, then `.product-json` script tag, then `window.meta.product`. Falls back cleanly to the visible "Add to Cart" button if anything goes wrong — strict speedup, zero new failure modes.
- **Per-domain concurrency cap** (`helpers/run-queue.js` `MAX_PER_HOST=5`, configurable via `max_concurrent_per_host` setting 1–15) — prevents 25 tasks against the same domain from self-DDoSing one proxy/IP and getting mass-flagged by the WAF. Acquired alongside the global cap; logs throttling events.
- **JA3/JA4 fingerprint diversity** (`helpers/tls-client.js` `pickTlsProfile`) — every `tlsRequest()` that omits `profile` randomly picks from `chrome131` (57%) / `chrome124` (29%) / `chrome120` (14%) so Akamai/Cloudflare can't mass-flag based on a single TLS hash. Weighted toward 131 to match the actual Chromium binary.
- **Sibling-task abort bus** (`helpers/sibling-bus.js`) — when one task confirms an order, it `notifyProductSuccess()` on a normalized productKey (host + pathname, ignoring query/fragment). Sibling tasks subscribed to the same product abort cleanly with `SiblingWonError` instead of wasting proxies/captcha credits/time on duplicate orders. Late-spawning siblings check `getRecentWin()` on startup (5-minute TTL). Returns `failureType: 'sibling_won'` so the retry loop short-circuits instead of trying again.

## Instant Cart Reservation — "Secure The Spot"

`helpers/cart-reserver.js` (`reserveCart({ task, proxy })`) closes the gap between
detecting stock and a browser finishing checkout. The moment the monitor sees
stock, it adds the item to a cart over plain HTTP (no browser) so the unit is held
while the slower Puppeteer checkout spins up.

- **Scope:** generic Shopify only (`site_id 2`) via the public `POST /cart/add.js`.
  Topps (`site_id 7`) is intentionally excluded — its stock check reads Shopify
  product JSON, but its **checkout adapter is Demandware/SFCC**, so it would not
  honor a Shopify cart cookie. Every other site returns `site:'unsupported'` and
  the caller falls back to the normal browser ATC (zero behavior change).
- **Flow:** `api/Tasks/monitor.js` `makeTick` calls `reserveCart` on `inStock`
  before `startTask`, broadcasts `cart_reserved`, and attaches `reservation` to the
  task only when reserved. `sites/shopify/index.js` then injects the cart cookies,
  goes straight to `/cart`, verifies the item, and **skips ATC**. If the cart
  didn't carry over it falls back to the normal PDP → ATC path.
- **Session continuity:** the reservation reuses the warm session cookies + the
  task proxy, and hands the browser the warm cookies **merged** with the fresh cart
  token (`mergeCookieHeaders`) so the reserved cart actually carries over.
- **Never blocks checkout:** `reserveCart` always resolves (never throws); any
  failure just falls through to the browser ATC.
- Tests: `__tests__/integration/cart-reserver.test.js` (Shopify reserve, Topps/
  non-Shopify unsupported fallback, variant resolution, cookie merge, failure
  safety).

> **NOTE — "reservation" = add-to-cart, not guaranteed inventory hold.** Shopify
> generally doesn't truly reserve inventory until checkout/payment. This is a real
> speed win, not an inventory lock.

## Proxy-Conservation — Datacenter-First HTTP Polling

Residential/mobile proxies are expensive and bandwidth-limited. The bot now
conserves proxy usage by separating HTTP stock polling from browser checkout:

| Operation | Proxy Usage |
|---|---|
| HTTP stock polling (TLS sidecar + got-scraping) | **Datacenter IP by default — zero proxy bandwidth** |
| Datacenter IP blocked (403/bot-block pattern) | **Instant retry with proxy, then stay on proxy** |
| 5 consecutive clean polls on proxy | **Automatically drops back to datacenter IP** |
| Imperva/PerimeterX session warming (browser) | **Always proxy** |
| Prewarm browser launch | **Always proxy** |
| Browser checkout | **Always proxy** |

**Implementation:** `checkStock()` in `helpers/stock-monitor.js` tracks a per-task
escalation state (`proxyEscalation` Map, keyed by `taskId`). The task proxy is
split into two roles at call time:
- `proxy` — always available for browser-based operations (session warming)
- `httpProxy` — null (datacenter) unless escalated; used for plain HTTP requests

`taskCheckOpts()` in `monitor.js` threads `taskId` through so escalation state is
per-task. `stopMonitor` calls `clearEscalation(taskId)` so a restarted monitor
always begins on the datacenter IP. `ESCALATION_CLEAN_THRESHOLD = 5` polls.

**In practice:** on a quiet drop day where your datacenter IP is not blocked, the
proxy sees **zero** HTTP polling traffic — only browser checkout (one session of
~30–60s) uses it. The proxy kicks in automatically if the site starts blocking,
then retreats once the IP recovers.

## Proxy-Pool Rotation — Banned-Proxy Failover

When a checkout attempt fails on a bot-detection-class error (Imperva/Cloudflare/
Akamai/DataDome/403/1015), the task **fails over to a backup proxy** instead of
retrying on the same banned IP. `helpers/proxy-pool.js` builds the candidate pool
from all active (`is_deleted=false`) rows in the `proxies` table and picks the best
untried one via the existing per-host scoring in `helpers/proxy-intelligence.js`
(`selectBestProxy` — win-rate + latency + streak, blacklist-aware). The retry loop
in `scripts/start-task.js` swaps `task.proxy_id` in place (the next attempt re-reads
it and threads the new proxy through warmer + browser; prewarm disposes any browser
parked on the old proxy).

| Rule | Behavior |
|---|---|
| Applies to **all** tasks | Even address-attached checkout tasks (unlike *fingerprint* rotation, which stays pinned for payment continuity) — a banned proxy blocks the order entirely, so a fresh exit IP is strictly better. |
| Doesn't burn a retry | A banned proxy isn't the task's fault: swaps use `attempt--`/`continue`, bounded by `MAX_PROXY_SWAPS=3`. |
| Cookie handling on swap | Old proxy's WAF cookies are often IP-bound → carrying them re-flags the session. Non-address tasks get a full identity rotation; address tasks get a **cookies-only wipe** (`wipeSessionCookies` in `helpers/identity-rotator.js`) that keeps the pinned fingerprint but drops stale cookies so the new IP re-warms clean. |
| Proxyless tasks | Left proxyless — the swap only fires when a proxy is already assigned (no silent bandwidth consumption). |
| Opt-out | Respects `rotate_on_retry === false`. |

Covered by `__tests__/integration/proxy-pool.test.js` (pool selection, exclusion,
ranking, empty-pool/DB-failure safety, detection classification) and
`__tests__/integration/identity-rotator.test.js` (cookies-only wipe vs full rotation).

## Consistent, Proxy-Bound Session Warming

`helpers/session-warmer.js` `startAutoRefresh` now (1) accepts the task `proxy` and
re-warms through the **same IP** that runs checkout, and (2) uses a jittered
self-rescheduling timer instead of a fixed `setInterval` (a fixed interval is
itself a detectable signal). `helpers/stock-monitor.js` passes the task proxy
through. Combined with the already-persistent per-task fingerprint
(`fingerprint-store.js`), warm cookies keep a consistent IP↔session↔fingerprint
identity — a returning-shopper profile rather than one that teleports between
networks.

> **KNOWN LIMITATION (by design):** warm cookies, metadata, refresh timers, and the
> persisted cookie jar are keyed by **host only**, not host+proxy. If two tasks hit
> the *same retailer* with *different* proxies at the same time, the first warming
> timer wins and cookies can be shared across proxies. Re-keying the cookie store by
> host+proxy was deliberately deferred (invasive + raises fraud-score risk). Each
> task's own lifecycle (monitor → warm → reserve → checkout) is always
> proxy-consistent; only the cross-task same-host/different-proxy edge is affected.

## Request Mode (Browserless Checkout) — Foundation

`helpers/request-checkout/` adds a **gated, fail-safe** path to advance a Shopify
checkout over plain HTTP (Chrome JA3 via the TLS sidecar) instead of launching
Puppeteer — the "pure speed" direction. Architecture: **request-FIRST /
browser-FALLBACK**. The HTTP path is a strict speedup layered in front of the
proven browser checkout, never a replacement.

| File | Purpose |
|---|---|
| `http-session.js` | Cookie-jar HTTP session over `tlsRequest`. Accumulates Set-Cookie across hops, sends a merged Cookie header, Chrome-131 UA. Never logs bodies/card fields; never throws. |
| `shopify.js` | `classifyShopifyResponse` (challenge/queue/oos/decline/session), `tokenizeCard` (Shopify vault `deposit.shopifycs.com/sessions` — tokenizes **without charging**), `prefillShopifyCheckout` (read-only `dryRun` probe now; mutating cart-add/checkout-open path scaffolded but NOT wired). |
| `index.js` | `requestModeEnabled` (setting `request_mode_enabled`, **default false**), `isRequestModeSupported` (only generic Shopify `site_id 2`), `tryRequestCheckout` (router; always resolves). |

**Safety contract:**
- **Gated OFF by default.** When `request_mode_enabled` is off, the runner path is
  byte-for-byte unchanged. Only wired use today is a **read-only** smoke probe in
  `scripts/start-task.js` before `launchBrowser` (resolve variant + `GET /cart.js`;
  never `/cart/add.js`, never submits).
- **Every entry point always resolves, never throws** — a thrown error could abort
  a real run, so each catches and returns `{ ok:false, ... }` (tested with rejecting
  `tlsRequest`).
- **Never auto-fall-back to the browser after an order-submit attempt** (double-order
  risk) — Phase 3 will surface ambiguous submits as `order_submit_unknown` and stop.
- **Never logs PAN/CVV.** Raw card data goes only to Shopify's vault.

> **Status:** Phase 0–2 (foundation + tokenization) shipped, gated off, covered by
> `__tests__/integration/request-checkout.test.js`. **Phase 3** (full browserless
> order submit) is NOT wired — it touches a real-money path and needs a live/test
> store + real card to validate. Plaintext PAN+CVV storage in `payment_profiles`
> remains a pre-existing risk; an encrypted vault should follow.

## Prewarm / Pre-Position Speed Engine (default-OFF)

`helpers/prewarm-engine.js` cuts the slowest part of the monitor→checkout race —
the cold Chrome launch + Imperva session warm — by doing it AHEAD of the drop
while the monitor is still polling, then handing that warm browser straight to
checkout.

**PARK-THEN-ADOPT (forced by a hard constraint):** `launchBrowser()` opens a
persistent per-task Chrome profile dir (`profiles/task-<id>`) that Chrome locks
exclusively, so you can't have an idle prewarm browser AND a separate cold
checkout browser for the same task — they'd collide on the lock. Therefore the
parked browser *is* the checkout browser: the monitor launches + warms it, and
`runOnce` **adopts** it (skipping launch + warm) the instant stock hits.

| Function | Role |
|---|---|
| `prewarmEnabled()` | Feature gate (setting `prewarm_enabled`, **default false**; mirrors `requestModeEnabled`). |
| `park({task, proxy})` | Fire-and-forget from `startMonitor`/`restoreMonitors` (gated). Launches + warms a browser, registers it, schedules jittered re-warm. Deduped + capped. Never throws. |
| `adoptPrewarm(taskId, {proxyId})` | Called in `runOnce` **ungated**, after `acquireSlot`, before `launchBrowser`. Atomically claims a healthy, proxy-matched, fresh parked browser → `{browser, page}`; else disposes any leftover context (freeing the profile lock) **before** returning null so the cold fallback's `launchBrowser` can't deadlock. Instant no-op when nothing parked. |
| `disposePrewarm(taskId)` | Tear down on `stopMonitor` + TTL sweep. |
| `disposeAll()` | Tear down every parked browser on SIGTERM/SIGINT (`app.js`). |
| `scheduleRewarm` | Jittered self-rescheduling re-warm (~4.5 min, ±30s); discards if warm age exceeds the 8-min TTL. |

**Safety contract (mirrors cart-reserver / request-mode):**
- **Gated OFF by default** — when `prewarm_enabled` was never set, nothing is ever
  parked and `adoptPrewarm` is an instant no-op → today's behavior, byte-for-byte.
- **Never throws** — any failure falls back to the cold checkout path.
- **Holds NO run-queue slot while idle** — only `runOnce` calls `acquireSlot`, so a
  parked browser can never starve a real checkout.
- **`adoptPrewarm` ALWAYS releases the profile lock before returning null** (awaits
  `browser.close()` on stale/proxy-mismatched/unhealthy contexts).
- **Adopt criteria:** healthy + connected, warm age < 8-min TTL, and proxy matches
  the run's proxy (a proxy swap between park and run → discard + cold launch).
- **NOT disposed in the monitor-store cleanup** — `makeTick` calls `clearMonitor`
  *before* checkout on stock; disposing there would kill the browser before adopt.
  Disposal happens only in `stopMonitor`, the TTL sweep, and SIGTERM.

Settings: `prewarm_enabled` (empty=off, `true`/`1`=on), `prewarm_max_parked`
(1–10, default 3; each parked Chrome is ~300–500MB, so the cap guards against OOM).

> **Why default-OFF + unit-tested only:** from Replit datacenter IPs, Puppeteer
> browser navigation to the Imperva/PerimeterX targets is hard-blocked, so the
> live adopt path can't be verified here. The gate, atomic claim, TTL /
> proxy-mismatch / unhealthy dispose, cap, and dispose-before-null are covered by
> `__tests__/integration/prewarm-engine.test.js` (17 tests).

## Running

```bash
npm start         # Production
npm run dev       # Development (file watch)
npm run migrate   # Run DB migrations
npm run seed      # Seed DB
npm test          # Run tests
```
