# Dedicated checkout reliability pass

- Every built-in retailer now has an explicit checkout contract and dedicated final-control semantics.
- Added strict pre-submit critical-field assertions to non-Amazon adapters where those fields are collected in-session.
- Added final-button intent validation so an ambiguous/cancel/edit/continue control cannot be mistaken for Place Order/Complete Order/Process Payment.
- Replaced the Target placeholder with a dedicated Target adapter using Target-specific product/cart/checkout selectors, shipping fulfillment handling, field reporting, payment handling, final Place Order verification, and confirmation detection.
- Added static smoke coverage requiring all 12 adapters to be real implementations and have checkout contracts.

Note: retailer DOMs can change over time; the adapters fail loudly when required selectors disappear rather than guessing at a different button.
