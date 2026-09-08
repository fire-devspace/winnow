[Back to main README](../README.md)

# Asserted app journeys

XCUITest drives real screens for wallet creation, recovery, receiving, sending,
saved recipients, shared savings, and Advanced signing. These tests check the combined app,
wallet, and node behavior that isolated unit tests cannot establish.
The ordinary, shared, and extra-device journeys all start payments in Send.
Form editing is checked once; each signing journey then checks its own approval
rules and the result accepted by the Bitcoin node.

[WinnowAppUITests.swift](WinnowAppUITests.swift) contains the scenarios.
[The journey inventory](../docs/journeys.json) maps them to the public website;
[build-site](../scripts/build-site) validates selectors and named screenshot captures.
[Node support](../Tests/Support/Node/README.md) supplies transactions and mined blocks.

[Node CI](../.github/workflows/node-tests.yml) creates a disposable signet and
uploads the result bundle, screenshots, and timing observations.
[The testing guide](../docs/testing.html) explains those artifacts and limits.
Screenshots do not turn a failed assertion into a pass; simulator evidence does
not establish physical-device behavior.
