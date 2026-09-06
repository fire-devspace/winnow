# Public-signet story tooling

This package drives a resumable acceptance journey through the real Winnow
app and verifies its transaction and media evidence. It uses public signet
peers. The storefront screenshot test uses the local signet fixture; each
runner retains its existing purpose and neither reruns the library test suite.

Run from the app checkout:

```sh
scripts/winnow-story help
scripts/winnow-story doctor
scripts/ci-story
```

The [runbook](../../.github/internal/story-run.md) covers start/resume,
checkpointing, signing roles, evidence verification and media review. Use
the wrapper for story commands: it keeps the app project, generated build,
and `.build/winnow-story/runs/` state rooted in the app checkout even when
invoked from another working directory.

The package pins the same published `btc-swift` version as `project.yml`.
`scripts/ci-story` checks that the pins agree, runs the package's offline tests,
and verifies the wrapper's environment checks from outside the checkout.
These checks do not start a story, launch a wallet, fund transactions or publish
evidence. The public-signet journey and human media review remain manual.

The source, test coverage and runbook were consolidated from revision
`3eb34e2a349a5552d37f4d558414cd04f4e2db15` of the former story repository.
Existing local runs remain in that checkout's ignored `.build/winnow-story/`
directory. To resume one here, copy its chosen run directory to this app's
`.build/winnow-story/runs/` with permissions preserved and without overwriting
an existing run. Keep the original until the resumed run has been verified.
