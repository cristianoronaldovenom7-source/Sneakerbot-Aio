# Ultra memory + residential bandwidth optimization

This build keeps the existing checkout path, task fingerprints, cookie prewarming, site adapters, and fast monitoring behavior intact while reducing avoidable overhead.

## Main changes

- Shared prewarm browser pool: multiple armed tasks targeting the same host and proxy endpoint reuse one Chromium process. Each checkout receives its own browser context/page, so concurrent checkouts no longer require one whole browser process each.
- Prewarm cookies are harvested into the existing cookie pool so the shared browser can refresh one host session instead of repeating the same warm for every task.
- Monitor transport coalescing ignores size/style at the network layer. One API/HTML response can be parsed independently for many sizes/styles without sending duplicate requests.
- Conditional API/HTML transport validators are shared per URL/network identity, preserving 304 behavior while reducing residential response bytes.
- Residential monitoring escalation is shared by host + proxy endpoint, so a temporary direct-IP block does not make every task independently burn a residential retry.
- Clean residential monitoring drops back to direct polling after one clean proxy poll by default.
- Warm-session resource blocking prefers Chromium CDP URL blocking over per-request Node interception, reducing Node CPU overhead during warm-up.
- Checkout browser concurrency remains adaptive to CPU/RAM/load instead of becoming an unbounded browser-spawn loop.

## Important resource expectation

The 200 MB/task number is not a guaranteed hard cap for Chromium checkout pages. The optimization is intended to lower the fixed per-browser/process overhead and share common work; real checkout pages can still consume more memory depending on the retailer and page state.
