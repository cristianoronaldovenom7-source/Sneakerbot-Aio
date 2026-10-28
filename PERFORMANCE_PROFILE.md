# Hardware performance profile

## Scalable lightweight task mode
- Up to 1,000 browserless monitor tasks can stay armed by default, with up to 100 armed tasks per hostname.
- `LIGHTWEIGHT_TASK_MODE=true` enables lower-overhead Chromium launch settings without changing checkout workflows or disabling prewarm when it is explicitly enabled.
- Browserless armed-monitor bookkeeping is targeted around 200 MB/task as a soft planning number; actual memory varies with workload.
- `CHECKOUT_MEMORY_BUDGET_MB=500` and `CHECKOUT_RESERVED_MEMORY_MB=2048` let the adaptive checkout governor use the available RAM more efficiently than the old 1.30 GB/browser reservation.


This build is tuned for a dedicated Intel/AMD laptop-class machine with roughly 8-16 GB RAM.

## What the program can optimize
- CPU-bound JavaScript stays on V8's optimized JIT path.
- Browser concurrency is sized from logical CPU count + available memory and load.
- Node's libuv threadpool is expanded for parallel TLS/filesystem/network helper work.
- Chromium foreground timers/renderers are less likely to be background-throttled during active checkout.
- Direct monitoring requests reuse HTTP/TLS connections instead of rebuilding sockets for every poll.
- Same-session browser navigations keep Chromium's HTTP cache enabled.
- Prewarmed browsers are capped by memory pressure so CPU scaling does not cause an OOM spiral.

## What no software setting can guarantee
- A motherboard cannot guarantee microsecond Internet latency. WAN latency is dominated by the ISP path, router, proxy/provider, and retailer server location.
- Integrated graphics are not a major accelerator for this headless checkout architecture; the workload is primarily CPU, memory, browser-process, and network bound.
- More concurrent tasks are not always faster. Once the CPU is saturated or the upstream server/connection is the bottleneck, adding tasks can increase contention.

## Runtime telemetry
The `/healthz` endpoint now reports CPU/load, recommended concurrency, memory, and HTTP connection-pool settings so you can validate the real machine rather than guessing.


## Elite performance profile (2026-09-20)
- Max-mode concurrency governor now uses CPU load and event-loop p95 lag to avoid oversubscription while allowing up to 12 active runs on capable hosts.
- Max-mode libuv threadpool default scales to 8-12 threads based on logical CPU count.
- Direct HTTP keep-alive socket pool defaults to 128 sockets / 32 idle sockets; TLS sidecar agent defaults to 64 / 16.
- Prewarmed browsers remain an explicit opt-in speed feature; the memory guard automatically backs off as pressure rises.
- Queue contention logs are DEBUG-only to reduce hot-path console I/O.


## Checkout performance mode

The max profile keeps armed-task capacity separate from heavyweight Chromium checkout concurrency. Lightweight monitoring can scale into the hundreds without launching a browser per task; checkout slots are granted adaptively to the hottest/oldest waiting runs as capacity opens. The checkout governor now uses a smaller configurable RAM budget and a wider CPU ceiling, while retaining load/event-loop backpressure.

This distinction is intentional: 16 simultaneous monitors and 16 simultaneous Chromium checkouts are not equivalent workloads. The former is realistic on 16 GB; the latter can cause RAM pressure and CPU thermal throttling.
