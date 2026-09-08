[Back to main README](../../README.md)

# Selected app captures

These committed images illustrate app journeys on the website; timings.json
retains capture-session observations. They let readers see the GUI being described.
PNGs use Git LFS, so fetch the image objects before viewing or publishing.

[UI tests](../../UITests/README.md) produce new captures in each run's artifacts.
[Journey metadata](../journeys.json) selects the images used by generated pages,
and [build-site](../../scripts/build-site) checks their named capture ownership.
Select replacements from a successful run of the intended revision and retain its
provenance in the change; follow the [screenshot guidance](../../.github/internal/app-store-screenshots.md).

Existing store-*.png files are historical candidates. Neither an image nor the
timing file proves that the current app passes its tests.
[check-site](../../scripts/check-site) checks referenced assets and unresolved LFS
pointers; reviewing the actual rendered image remains necessary.

The Send captures (`05` through `08`) and person-payment review (`25`) were
refreshed from [app revision d02ffa3](https://github.com/winnowwallet/winnow/commit/d02ffa314d198f4759069e8398d84bb8a50f19d2).
All 16 app journeys passed in [this UI run](https://github.com/winnowwallet/winnow/actions/runs/34171647009),
including editing a payment, keeping custom fees out of beginner mode, opening
payment diagnostics, and following Bitcoin Core confirmation.
The [run artifact](https://github.com/winnowwallet/winnow/actions/runs/34171647009/artifacts/10036468223)
contains the original captures, log, and result bundle.

The extra-device captures (`35` through `39`) come from
[app revision 75d08be](https://github.com/winnowwallet/winnow/commit/75d08be333311ee1bd53d1e2eb4d6a3118a747d9).
All 16 app scenarios passed in
[this UI run](https://github.com/winnowwallet/winnow/actions/runs/34253766409).
The Core-backed journey covers account setup, review, interruption and restart,
both approvals, the sent receipt, and restoring the pre-payment backup to find
the remaining balance. The images are unchanged originals from the
[run artifact](https://github.com/winnowwallet/winnow/actions/runs/34253766409/artifacts/10068373928),
which also includes the log and result bundle. They show an iPhone simulator on
a private test chain; they do not show a hardware-wallet integration.
