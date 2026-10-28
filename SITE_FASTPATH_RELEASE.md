# Site-wide Checkout Fast-Path Upgrade

All built-in checkout adapters now use a shared, conservative fast-path layer that avoids redundant cart/checkout navigation when the site has already transitioned to the correct surface. The optimization is applied to every retailer without inventing undocumented private HTTP APIs.

Shopify retains the existing public request-first cart/checkout preparation because it has a documented JSON/cart surface in this project. Other retailers receive browser-level state reuse and navigation elimination through their own dedicated adapters.

## v3 — same-session request-first ATC across built-in adapters

All non-Shopify adapters now attempt a conservative same-session HTTP Add-to-Cart submission using the retailer's currently rendered DOM form. The helper only accepts same-origin POST forms whose action is clearly cart/add/bag-related and includes a matched Add-to-Cart control. If no safe form is found or the request fails, the adapter immediately falls back to its existing site-specific browser click path. Final checkout/payment/order submission remains browser-driven unless a verified public request contract already exists.
