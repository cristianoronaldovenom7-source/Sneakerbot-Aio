# Request-first checkout hot path

Generic Shopify now uses a live request-first pre-checkout bridge when stock is detected:
1. resolve the available variant over HTTP;
2. POST the public `/cart/add.js` endpoint;
3. open `/checkout` over the same HTTP cookie jar;
4. hand the cookie jar + checkout URL to the dedicated Chromium adapter;
5. let the browser handle dynamic shipping/payment/final-order stages.

This removes PDP/cart rendering from the Shopify hot path while preserving the browser as the final verified payment/order engine.

Other retailers retain their dedicated browser checkout adapters because the current project does not have a verified deterministic public HTTP checkout contract for them. This avoids guessing at private APIs or brittle undocumented endpoints.
