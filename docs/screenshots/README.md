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
