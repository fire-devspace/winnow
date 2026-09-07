# App Store screenshot candidates

The former storefront-only sequence and its optional workflow are retired.
The app journeys in UITests/WinnowAppUITests.swift are the source of
screenshots. They run with assertions against the real app and disposable
signet fixture; failures remain failures even when a screenshot exists.

CI keeps captures with the UI result bundle in its node-ui artifact.
Choose screenshots from a successful run of the intended app revision.
Use only images suitable for publication: never a recovery phrase, exported
secret, debugging failure capture, or private node configuration.

Existing store-*.png files are historical candidates, not evidence of the
current app. No screenshot upload is performed by tests or site generation.
scripts/testflight.sh appstore-status reports the sets already uploaded.
