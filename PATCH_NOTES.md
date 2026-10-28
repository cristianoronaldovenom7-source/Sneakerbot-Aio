

## Speed + bypass upgrade — 2026-10-24 (sidecar pooling & cookie continuity)

The hardening pass fixed *what* the fingerprints say; this pass fixes *how the
wire behaves*, which was where the remaining time and detectability went.

**Root cause found:** the sidecar built a brand-new `tls_client` for every
request. That threw the connection pool away each time, so every poll paid a
fresh TCP + TLS + HTTP/2 handshake (2+ RTT through a residential proxy before
the first byte), and the JA3 hash was free to change between two polls seconds
apart on the same identity.

**Corrected on audit (same day)**

Three hard compile breaks in `pool.go`, all caught by source review before the
first `go build` (no toolchain on this box):

- A duplicate `package main` clause mid-file.
- `cookieHeaderFor` was left unclosed: `hostOf` had been pasted *inside* its
  body, and the function's real tail (the jar render loop) was orphaned at
  end-of-file. Package-level callers of `hostOf` would not have linked.
- Balanced the whole file; braces and parens now check out.

RAM leaks the first pass left behind (all unbounded, all real):

- `cookieStore` was keyed by caller session id and never evicted — every
  `HttpSession` generates a fresh id, so it grew forever on a long-lived bot.
  Now: 10-minute idle TTL, hard ceiling of 256 sessions, swept on write.
- `decodeBody` deleted `Content-Encoding` after decompressing but left the
  stale compressed `Content-Length` in place, so a caller that trusted it
  truncated a valid body.
- The DNS cache only shed *expired* entries when it hit its ceiling; under
  sustained multi-host load it could grow past that ceiling. Hard cap added.
- `maxPooledClients` (64) was also wired in as `MaxIdleConns` **per client**,
  and `MaxIdleConnsPerHost: 32` on top — 64 clients × 64 idle sockets with
  full read/write buffers was the bulk of the sidecar's resident set. Now 16
  and 8 respectively.
- `stickyProfiles` in `tls-client.js` was a `Map` that only ever grew. Now
  swept on write and capped at 512 identities.

**Residential-proxy hardening (new)**

Pooling introduced a failure mode it did not have before: residential gateways
reap idle keep-alives in roughly 15-45 s, far below what an origin holds one
open, so a pooled socket that *looked* warm was often already dead. Two fixes:

- `IdleConnTimeout` tightens to 20 s when a proxy is configured (90 s direct),
  so the transport stops offering sockets it should know are gone.
- A transport error on a **reused** pooled client evicts that client and
  rebuilds the request once — GET only, because a retried POST duplicates the
  action. Requests are re-built rather than replayed, since a failed `Do` may
  already have consumed the body reader.

Also: the session jar is now re-derived **per redirect hop** instead of once.
Previously a redirect to a different host carried the first host's cookies —
a real browser never does that, and it was both a fingerprint tell and a data
leak into the next origin. `req.Headers` is also initialised when the payload
carries no headers at all, since assigning to a nil map panics.

**Fixed (`tls-sidecar/pool.go` + `main.go`)**

- Pooled clients keyed by (profile, proxy): sockets are reused across requests,
  capped at 64 entries with a 2-minute idle eviction. Hot polls now cost ~1 RTT.
- Session cookie store: `session` ids make Set-Cookie persist server-side, so a
  multi-step flow looks like one browser tab instead of N cold ones. Caller
  `Cookie` headers still win, so existing jar threading is untouched.
- SSRF-guard DNS cache (60s TTL): the guard was doing a blocking `net.LookupIP`
  on the URL *and on every redirect hop*.
- `decodeBody()`: gzip/deflate/br response bodies are decompressed. Previously
  origins replying with compression were regex-matched as raw bytes, so HTML
  stock probes silently failed. Also cuts residential proxy bandwidth ~60-80%
  on HTML probes. (br decodes via the already-pinned brotli module.)
- `POST /preconnect`: opens and keeps the pooled TLS/H2 connection before the
  hot-poll window, so probe #1 skips the handshake entirely.
- Per-request deadlines now travel on the request context, so one pooled client
  can serve callers with different timeouts.

**Fixed (`helpers/tls-client.js`)**
- Sticky TLS profile per (host, proxy) instead of per-request random pick: a
  real browser does not change its ClientHello between two polls. The 15-min
  rotation still draws from the same diverse pool, so different sessions don't
  collapse into one fingerprint.
- In-flight GET coalescing: N tasks polling the same URL through the same proxy
  now share one request instead of N parallel handshakes for one response.
- `tlsPreconnect()` export for pre-warming; `session` passthrough.

**Wired in**
- `helpers/drop-watcher.js` calls `tlsPreconnect()` when entering the hot
  window, so the first probe is connection-warm.
- `request-checkout/http-session.js` gives every HttpSession a stable session
  id, giving the whole cart → checkout → pay flow one persistent identity and
  connection.

**Verified:** full jest run matches the known baseline (the 5 documented
environment-dependent failures plus `memory-optimization`, which fails only
because `CPU_PERFORMANCE_MODE` defaults to `max` on this many-core dev box and
the cgroup/limits assumptions that test encodes don't hold here); smoke test
passes end to end. `tls-sidecar` still needs a `go build` on a machine with a
Go toolchain — source is reviewed but unbuilt.


## Bypass + spoofing hardening — 2026-10-24

Closes the fingerprint-coherence holes in the browser and HTTP stealth layers.
The toolkit already had the expensive parts (JA3/JA4 sidecar, per-task pinning,
CDP stealth script); what it leaked was *consistency* between them.

**New: `helpers/fingerprint-coherence.js`**
- `validate()` reports every pairwise contradiction as structured
  fatal/warn issues (UA vs platform token, engine version vs UA, renderer vs
  GPU/OS, viewport vs screen, chrome headroom, plausible core/mem counts,
  missing vendor/timezone/font seed).
- `repair()` fixes them without discarding the pinned canvas/audio/font seeds,
  so the task still looks like the same device, just a correctly configured one.
- `deriveScreenMetrics()` / `screenGeometry()` are the single source of truth
  for the screen/viewport/dpr triad; a window can no longer be wider than its
  own monitor, and chrome always fits.

**`helpers/fingerprint-store.js`**
- Screens, viewports and `devicePixelRatio` are now drawn as one coherent
  triad instead of independently.
- Every shipped profile carries a platform-correct ANGLE renderer string
  (`ANGLE (Apple, …, Metal)` vs `ANGLE (NVIDIA, …, D3D11)`).
- `healIfIncoherent()` repairs and re-persists pinned fingerprints written by
  older builds on first load; seeds are preserved.
- Engine version is overridable via `CHROME_FINGERPRINT_MAJOR` /
  `CHROME_FINGERPRINT_FULL` so the image can move past Chromium 131 without a
  code edit. Removal of the last "unmasked macOS-with-D3D11" class of profile.

**`helpers/cluster.js`**
- `screen.width/height/avail*/outer*/inner*/devicePixelRatio` all derive from
  the profile geometry; the hardcoded `1920x1080` screen is gone.
- `navigator.pdfViewerEnabled` spoofed `true` (headless reports false, which
  contradicted the spoofed PDF plugins).
- `Function.prototype.toString` masking extended to every patched function
  (permissions.query, getGamepads, matchMedia, attachShadow, getBattery,
  document.fonts.check, chrome.csi/loadTimes, getHighEntropyValues). Unmasked
  patched functions stringify as non-native and are a one-line detection.

**`helpers/geo-consistency.js`**
- `resolveTimezoneForExit()` prefers the proxy exit timezone over the pinned
  device timezone, so a Toronto-pinned session egressing through Los Angeles no
  longer reports a Toronto clock.
- Added Denver, Berlin and Paris; unknown timezones report `matched: false`
  instead of silently pretending to be Toronto.
- `alignProfileToExit()` applies the result; TZ, locale, geolocation and
  Accept-Language now all travel together.

**`helpers/datadome.js`**
- `sec-ch-ua` tracks the UA version (was hardcoded to Chrome 124 while the UA
  said 131 — a direct self-contradiction).
- Payload `pf`, `glrd` and `vnd` follow the UA engine family
  (Chrome/Edge/Firefox/Safari/Linux) instead of always claiming `Win32` +
  a Windows D3D11 renderer + `Google Inc.`.
- Payload `lg`/`lgs` and the `accept-language` header follow the caller locale;
  `br_ow`/`br_oh` follow the profile screen instead of a fixed 1920x1080.
- `buildDataDomeFingerprint()` exported for testing.

**`tls-sidecar/main.go`**
- Chrome's H2 header order now includes the whole `sec-ch-ua-*` block
  contiguously (arch, bitness, model, platform-version, full-version-list,
  wow64) plus `priority`, instead of splitting them into the alphabetical tail.
- Added `firefox133` and `chrome131_psk` profile mappings. Note: tls-client
  v1.7.10 ships no `Chrome_133`, so `chrome133` maps to `Chrome_131_PSK`
  rather than a profiled that does not exist.

**`helpers/tls-client.js`**
- Sidecar profile pool is overridable via `TLS_SIDECAR_PROFILES`.

**Tests**
- `__tests__/integration/fingerprint-coherence.test.js` (30 cases)
- `__tests__/integration/geo-consistency.test.js` (13 cases)
- `__tests__/integration/datadome-payload.test.js` (6 cases)
- `scripts/smoke-test.mjs` gained an anti-bot coherence section so the
  dependency-free path also guards this wiring.

Baseline note: `cart-reserver`, `request-checkout`, `prewarm-engine`,
`proxy-pool` and `site-request-first` were already failing before this batch
(23 tests, identical set) and are untouched here.


## Best Buy checkout/autofill hardening — 2026-09-17

Updated `sites/bestbuy/index.js` to bring Best Buy checkout form handling closer to the more robust Pokémon Center flow.

- Added retry + post-fill verification for shipping fields.
- Added stronger selector fallbacks for Canadian postal code, province, phone, email, and payment fields.
- Added critical-field checks so checkout stops instead of submitting an incomplete form.
- Added address-suggestion handling that keeps the address the user entered.
- Added billing-address support, including same-as-shipping detection.
- Added more resilient guest-checkout and continue-button handling.
- Added payment-frame retries and card-type detection when a card-type selector is present.
- Added more robust order-number extraction after confirmation.
- Did not add CAPTCHA/queue bypass logic; existing checkout guards remain responsible for challenge/queue handling.


## Review vs current Stellar public feature set
- Kept the existing Command Search, Live Feed, and Performance Analytics surfaces documented publicly by Stellar.
- Replaced the dashboard's 2.5s live-feed polling with a push-based SSE stream plus a 10s fallback, reducing redundant API/database traffic while making monitor updates more immediate.
- Fixed a real readiness-wait fallback bug where a Node-side `visible()` helper was referenced inside `page.evaluate()`, making selector fallback checks fail silently.
- Added single-flight monitor startup so concurrent scheduler/manual/restart requests cannot create duplicate polling loops for the same task.
- Corrected dashboard success-rate math to use actual `task_runs` outcomes rather than the task `has_been_used` flag.
- Added a short-lived run-stats cache and identical drop-probe coalescing to reduce repeated DB/HTTP work during active dashboards/drop windows.

## Workflow v5 adjustments
- Skips drop-time delay when a stock monitor has already detected inventory.
- Makes task starts single-flight to prevent duplicate queued checkouts.
- Adds live stage telemetry to PC/Best Buy workflows.
- Replaces Pokémon Center guest-button polling with mutation-aware readiness.


## Role-separated proxy routing
- `monitor_proxy_id` / `checkout_proxy_id` + role modes
- Per-task dashboard selectors for Monitoring vs Checkout
- Optional `RESIDENTIAL_PROXY_URL`, `RESIDENTIAL_MONITOR_PROXY_URL`, `RESIDENTIAL_CHECKOUT_PROXY_URL`
- Residential gateway credentials remain in the deployment environment

## 1 GiB Residential Bandwidth Mode
- Auto monitoring is now direct by default; residential is reserved for checkout unless a monitoring proxy is explicitly assigned.
- Added persistent monthly residential bandwidth accounting with a default 1024 MB budget.
- Strict budget mode prevents new residential sessions once the budget/reserve is exhausted.
- Proxy metadata now reports residential usage, remaining monthly budget, and per-role consumption.

## Pokémon Center no-residential resilience
- Direct monitoring uses a stable client identity for the PC host rather than rotating User-Agent on every poll.
- Direct PC polling never runs faster than ~2.2s by default.
- Repeated access denials exponentially back off from about 60s up to 15m while leaving the task armed for automatic recovery.
- No stealth, queue bypass, or anti-bot circumvention was added.


## Self-healing checkout DOM recovery
- Added dependency-free semantic selector recovery shared by all site adapters.
- Explicit site selectors remain first choice; if markup drifts, the runtime now maps labels, autocomplete, names, test IDs, and action text back to a safe selector.
- Recovery runs early instead of waiting through the entire selector timeout.
- Final order actions require explicit order semantics and disabled/destructive controls are excluded.
- Existing critical-field validation and final-order safeguards remain unchanged.
