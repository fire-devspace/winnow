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

The retained Send captures (`05`, `07`, and `08`) come from
[app revision d02ffa3](https://github.com/winnowwallet/winnow/commit/d02ffa314d198f4759069e8398d84bb8a50f19d2).
All 16 app journeys passed in [this UI run](https://github.com/winnowwallet/winnow/actions/runs/34171647009),
including editing a payment, keeping custom fees out of beginner mode, opening
payment diagnostics, and following Bitcoin Core confirmation.
The [run artifact](https://github.com/winnowwallet/winnow/actions/runs/34171647009/artifacts/10036468223)
contains the original captures, log, and result bundle.

The current Receive, review, account, Settings, saved-recipient, and approval
captures (`03`, `06`, `10`, `11`, `23-settings-beginner`, `24-saved-recipient`,
`25-pay-person-review`, `27`, and `35` through `39`) come from
[app revision 4559ecd](https://github.com/winnowwallet/winnow/commit/4559ecd150b2f3399f0b4613cce9db689bcb2d51).
They are unchanged originals captured locally on 2026-09-08 with an iPhone 17 Pro
simulator running iOS 26.5 against a disposable signet node.
All 16 app journeys passed in that run, along with the app unit tests.
The local evidence is `recipients-final-ui.xcresult` and
`winnow-recipients-final-ui.log`.
The recipient journey covers saving, renaming, restarting, removing and re-adding,
then paying through Send. The extra-device journey uses Bitcoin Core as the other
signer and covers setup, review, interruption and restart, both approvals, the
sent receipt, and restoring the pre-payment backup to find the remaining balance.
