# Engineering Scorecard

Status of each quality axis, what backs the claim, and the honest limit. Numbers come
from `npm run bench` and `npm test` — run them, do not take the prose.

Last verified: 2026-10-27 — 657 tests / 59 suites green, 0 smoke failures, bench 7/7
within budget, Go sidecar compiles.

## How to reproduce

```bash
npm test                    # 690 tests + stealth + smoke audits
npm run bench               # hot-path latency, fails on regression
npm run bench:e2e           # end-to-end pipeline latency over real HTTP
node scripts/check-english.mjs <files>   # no CJK / mojibake
```

Every budget in `scripts/bench.mjs` is a real gate: the script exits 1 and marks the
row FAIL when a metric misses. Verified by inserting a 400k-iteration loop into the
poll-delay path (3.77ms p95 vs 0.5ms budget, exit 1) and reverting it.

## Axes

### Stock monitoring speed — 9/10
Parser benchmark parses a 57KB product page in **0.095ms p95** against a 25ms budget.
Conditional requests (ETag/304) and cross-task response coalescing mean one fetch
serves many monitors. 304s are billed at 1KB, not full body size, so the optimization
does not eat the budget it saves.

Limit: parsing is never the bottleneck — network is. Budgets are single-host, not
measured under a 1000-task fleet.

### Network efficiency — 9/10
Poll economy backs off quiet monitors; a confirmed change opens a 90s burst window
that overrides the backoff, so freshness is not traded away permanently. **HTML polls
fetch a head-only `Range` slice** (~70-90% less body on a real PDP; every consumer is
head-only), with a full refetch when a truncated head parses to nothing. Residential
exits are pinned per task+host and ranked on region fit plus a monthly IP quota.

Limit: servers that ignore `Range` simply return 200 and cost full size. Sticking to
one exit concentrates risk — a burned IP costs one failure before rotating.

### Checkout speed — 8.5/10
Request-first cart path, prewarmed browsers, stage-level recovery. A dead exit now
fails a stage fast and requests rotation instead of retrying into another timeout.
**Captcha solves are now commonly instant**: the token stockpile (previously a dead
module) serves a pre-solved token ahead of the provider cascade, turning a 10-30s
hCaptcha into a Map lookup.

Limit: a live browser checkout is still seconds. The stockpile only holds tokens this
process minted, so a cold first solve is unchanged.

### Reliability and recovery — 8.5/10
Circuit breaker, adaptive backoff, per-exit liveness, fail-fast on dead exits. All
recovery paths are asserted (687 tests, mutation-verified). **Duplicate suppression is
now live** — a win announces itself on the sibling bus and other tasks armed on the
same product abort before submitting, releasing their browser, exit and queue slot
instead of buying a duplicate order.

Limit: real-retailer success rate is still unmeasured; everything here is design plus
unit evidence.

### Concurrency and scaling — 8/10
Global and per-host caps, admission gated on RAM and residential concurrency together.
The queue is now **ageing** — anything waiting 20s outranks priority, so a stream of
hot restocks cannot starve background work — and bounded at 1000 waiters with a clear
rejection instead of unbounded growth.

Limit: ageing threshold is a judgement call, not tuned against real traffic.

### Test and performance evidence — 8.5/10
690 tests across 64 suites; four dependency-free audits (stealth, smoke, English,
bench) plus an **end-to-end latency harness** (`npm run bench:e2e`) that drives the real
`checkStock()` pipeline over a real HTTP server with Range and 304 support. Measured
p50 ~10ms per poll for both API and HTML paths, with the 304 revalidation path at ~11ms.
The benchmark is a genuine gate that exits non-zero on regression.

**The suite is now environment-independent.** It previously inherited
`CPU_PERFORMANCE_MODE` and `CHECKOUT_*` from the ambient shell, so it passed alone and
failed in a full run; the governor suite pins and restores those per test, mocking CPU
count as well as memory, and the queue suite forces a deterministic slot count. Verified
green with the variable unset, `balanced`, `high`, and `max`.

Limit: the e2e harness uses a local server, so network is held constant. It proves
pipeline cost, not retailer latency or checkout success rate. Only a live drop settles
those, and `bench:e2e` names that in its own output.

### Production security and operations — 8.5/10
- Login rate limited 10/5min keyed on **username+IP** so one attacker cannot lock the
  owner out (verified live: 10x401 then 429).
- API ceiling 600/min with `Retry-After`.
- Session cookie gains `secure` when the public URL is HTTPS (CWE-614), with an
  override for TLS-terminating proxies; `rolling` re-issues on activity.
- **`SESSION_SECRET` is now required in production** — boot fails with a clear message
  rather than silently shipping the public fallback secret (which lets anyone forge a
  cookie). `ALLOW_INSECURE_SESSION_SECRET=1` opts out for throwaway boxes.
- **TLS verification is explicit**: `TLS_VERIFY_STRICT=1` turns on `rejectUnauthorized`
  for fetches and `ignoreHTTPSErrors: false` for the browser, from one predicate so the
  two cannot disagree. Default stays permissive on purpose (a gateway presenting a bad
  chain mid-drop costs a checkout; a MITM is theoretical).
- `/healthz` reports dependency state **and the live security posture**, returns 503 on
  hard-down and 200 when merely degraded.
- `trust proxy` set, so limits key on real client IPs behind a reverse proxy.

Limit: the limiter is in-process and fixed-window — resets on restart and is evadable
by many IPs. TLS verification is off by default, so "permissive" is a choice, not an
oversight.

### Stealth and spoofing — 9/10
31 fingerprint patches, native-code hygiene, per-profile deterministic canvas/audio,
coherence validation, headful launch with real focus, Kasada/Shape adapters, proxied
captcha solving, and a sampled self-audit including a main-vs-isolated-world diff.

Limit: headless remains the default on small hosts, and that carries a real penalty.

## Known gaps, ranked
1. No live-retailer checkout benchmark — the largest single evidence hole, now narrowed
   to latency only (pipeline cost is measured; retailer cost is not).
2. Kasada's fork path usually ends in `needBrowser`; it is escalation, not a solve.
3. `country_code` / `monthly_ip_cap` columns do not exist yet; region and quota
   degrade to neutral until something populates them.
4. Resolved captcha tokens are not validated before use.
5. Rate limiting is per-process, so it weakens across replicas.
6. Three empty artifacts still ship: `current_src/`, `needs`, `OK; else echo have=`.

## Fixed this round (was listed by review)
- **Balanced mode bypassed the RAM governor.** `recommendedCheckoutConcurrency`
  returned `min(8, configured)` before any RAM arithmetic, so a 1 GB host in balanced
  mode was handed 8 Chromium browsers while `ramCap` was 1 — an OOM mid-checkout, not
  just a test artifact. Mode is now one more term in the same `min()`. Verified:
  1 GB gives 1 under every mode.
- **Environment-sensitive tests.** Governor and queue suites inherited ambient env and
  timed out in a full run. Now pinned per test.
- **Public fallback session secret reachable in production.** Now a boot error.
- **`rejectUnauthorized: false` / `ignoreHTTPSErrors: true` hardcoded.** Now one
  switch, and reported by `/healthz`.
- **Two complete modules had zero callers** — `token-stockpile.js` (pre-solved captcha
  tokens, the largest bypass speedup available) and `sibling-bus.js` (duplicate
  suppression). Both wired and mutation-verified.
- **Page teardown never asked for GC.** Rendered memory sat resident until pressure
  forced a sweep, which on a 2 GB box is too late. Teardown now presses the renderer
  lifecycle and requests a collection before close, and tolerates every CDP failure.
