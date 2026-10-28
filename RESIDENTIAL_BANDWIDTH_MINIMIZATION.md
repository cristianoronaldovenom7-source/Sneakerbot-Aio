# Residential Bandwidth Minimization

This build keeps the fast monitor + prewarm + checkout architecture while minimizing residential proxy consumption:

- `monitor_proxy_mode=auto` is direct-first, even when a residential proxy is assigned; the residential endpoint is retained as a fallback rather than used for every poll.
- Checkout proxy selection is resolved separately and is reused for prewarm and checkout, preserving the warm-session/checkout path.
- When a direct monitor response exposes an Imperva challenge, the existing warm-session path can use the dedicated warm/checkout proxy without permanently routing the monitor through residential.
- A task that already has a parked shared prewarm pool does not also start a duplicate periodic residential warmer.
- Shared prewarm pools remain keyed by host + proxy endpoint so multiple tasks can reuse one warmed browser process/session where the same endpoint is appropriate.
- Prewarm rewarm cadence is 6.5 minutes with an 8.5 minute TTL, reducing refresh traffic while keeping a warm session ahead of the 9 minute cookie TTL.
- Explicit `assigned` or `residential_env` monitor modes still work when residential monitoring is intentionally desired.

The goal is to spend residential bandwidth mainly on prewarm/checkout and targeted challenge recovery, not on routine stock polling.
