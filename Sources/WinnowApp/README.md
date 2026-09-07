[Back to main README](../../README.md)

# The iPhone wallet

SwiftUI screens and AppModel turn wallet and network state into receiving,
sending, recovery, people, and shared-savings flows. The app owns user review,
authentication, presentation, and lifecycle; WalletCore owns the Bitcoin rules.

[Documented journeys](../../docs/journeys.json) identify the supported experiences.
[App tests](../../AppTests/README.md) check state and protected actions;
[UI tests](../../UITests/README.md) drive the simulator against a disposable node.
Simulator tests do not establish physical-device lock behavior or battery life.

Assets.xcassets contains the app icon and its Xcode metadata; it is an asset bundle,
not another code layer. [make-icon.swift](../../scripts/make-icon.swift) creates icon
artwork; changing it requires inspecting the rendered icon and building the app.
Keep documentation outside the asset catalog so it is not treated as an asset.
