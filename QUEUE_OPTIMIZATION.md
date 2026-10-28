# Queue Handling Optimization

- Queue waits no longer hard-stop after 30 minutes by default. `QUEUE_MAX_WAIT_MS=0` means persistent wait until the task/site/session exits.
- Queue state is detected with a low-cost DOM `MutationObserver` plus a short fallback window, so queue release is noticed quickly without constant full-page polling.
- Queue pages are not refreshed simply because the wait is long; this protects legitimate waiting-room state from being reset.
- Transient page-evaluation failures are treated as `unknown/possibly still queued`, not as an immediate queue-clear signal.
- `QUEUE_LOG_INTERVAL_MS` controls status-log frequency (default 60s) and `QUEUE_WATCH_WINDOW_MS` controls the DOM observation window (default 2200ms).
- Site adapters (Pokémon Center and Best Buy) now rely on the shared persistent queue handler.
- This is queue resilience only; no queue bypass or anti-bot circumvention is added.
