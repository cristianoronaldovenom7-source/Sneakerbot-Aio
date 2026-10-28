# Lightweight / 100-per-site build

This build changes task capacity around a queue-first architecture:

- Up to 1,000 browserless monitor tasks can remain armed globally by default.
- Up to 100 armed monitor tasks can target the same hostname by default.
- `LIGHTWEIGHT_TASK_MODE=true` keeps monitoring browserless and suppresses prewarm/parked Chromium instances.
- `TASK_MEMORY_BUDGET_MB=200` is a soft tuning target for armed monitor tasks. It is not a hard OS memory limit.
- A Chromium browser is still created only when a task actually enters checkout. The global checkout governor remains adaptive so 100 armed tasks do not become 100 simultaneous browsers.
- Active checkout concurrency per hostname can be configured up to 100, but the global CPU/RAM governor still determines how many browsers actually run at once.

Existing databases are upgraded by migration `20260924000031_lightweight_task_capacity.js` without overwriting non-default custom capacity settings.
