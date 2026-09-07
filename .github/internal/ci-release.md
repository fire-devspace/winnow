# CI, release and website operations

Winnow is one repository and one release train. The root Swift package organizes
internal modules and development executables. The app, fuzz harness
and debugging tool share one `Package.swift` and one `Package.resolved`; only
swift-secp256k1 is remote. Xcode resolution must match that root lockfile.

## Checks and ownership

| Workflow | When | Responsibility |
| --- | --- | --- |
| CI | PR, main push, manual, release caller | Complexity, package and debugging tests, app/Keychain tests, release warning and E2E exclusion gates, CLI smoke, provenance, fixed fuzz corpus |
| LOC | Every PR, main push and manual run | cloc 2.10, committed paths, matching JSON/CSV/Markdown and merge-base deltas; 90-day artifacts subject to org limits |
| Fuzz sanitizers | Weekly or manual seed replay | Sustained address/thread sanitizer coverage; does not repeat normal suites |
| Node integration | Differential and UI: same-repo PRs touching code, main pushes, nightly, release, confirmed manual run | Core differential tests and app UI tests, each on a fresh fixture owned by that job |
| Release | New stable version tag or manual validation | Calls CI and Node integration, then signs/uploads and publishes only for tag pushes |
| TestFlight recovery | Manual, exact version and build number | Finish notes/group assignment for an existing upload |
| App Store submission | Manual | Attach a processed build and optionally submit for review |
| Website | docs changes or manual | Validate generated journey pages, links and LFS, then deploy the same static docs tree |

Hosted runners carry every PR check; the persistent Intel and node runners
additionally take pull requests from branches in this repository, never from
forks. Node suites share the source in `Tests/Support/Node` and run serially on
the single listener; they must never share a mining fixture with another
concurrent run.

Runner VM provisioning, registration, and machine inventory live in the separate
private runner repository. Winnow requires a prepared macOS/Xcode seat with
Bitcoin Core tools and the workflow's labels; it manages only its temporary
node through `scripts/signet-fixture`.

Each job owns fixture setup and teardown under its temporary directory; prior
wallet state and difficulty retargets cannot affect the next run.
The three Keychain attribute checks use the app's existing iOS test host.
They verify recorded attributes and round-trip storage; device-lock enforcement
still needs real hardware. The retired story/media workflow has no CI role;
app screenshots now come from the asserted UI journeys.

## Release

Create a new, unused stable `vMAJOR.MINOR.PATCH` tag on the intended Winnow
commit. This is an app release, including its internal modules and tools. Existing
tags in Winnow and the archived library remain fixed; the former library's
`v0.1.0` is historical and is not Winnow's next version.

Run Release manually first to validate the checkout without signing, uploading,
assigning TestFlight groups or publishing. Release checks the generation date
recorded inside `FallbackPeersGenerated.swift`, so copying or squashing history
cannot make an old peer list appear fresh. If older than 30 days, run
`scripts/generate-fallback-peers` (which runs `winnow-debug generate fallback-peers`
from [Tools/Generate](../../Tools/Generate/README.md)), retain its log and
commit the result before tagging. Refreshing the header checkpoint is the same
tool's other subcommand, via `scripts/refresh-checkpoint`, and needs a
genesis-validated header file; it is a manual release-time step, not a check.
The signed app archive is checked for E2E controls and its provenance is
attached to the GitHub release.

The CI workflow is reused directly, so release definitions cannot drift into a
second copy of package/app/fuzz checks. Debug app tests already build the app;
there is no extra debug build. Native CLI smoke and provenance use the same
warning-checked release binary. Fuzz smoke reuses its compiled modules, while
`swift test` runs the library and debugging-tool suites together once per
architecture. The iOS Release build separately checks shipping compiler settings
and bundled resources.

If App Store Connect processing outlasts a release, use **TestFlight recovery**
with its exact marketing version and build number; do not upload that number
again. App Store submission remains a separate deliberate operation.

There is no separate public library product or release process. The local app
and tools change together and need no internal version bumps.

## Website

`docs/` is static HTML. `scripts/build-site` generates home and Advanced from
`docs/journeys.json` and app-test selectors; the other pages are authored directly.
The app bundles the five design papers and `site.css` directly from that directory. Edit them once.
Run `scripts/build-site` after changing journey inputs, then `scripts/check-site`
after `git lfs pull` to check local page/asset links and reject unresolved image pointers.

Website deploys to the existing Cloudflare Pages project `winnow`, using
`CF_API_TOKEN` and `CF_ACCOUNT_ID`. Only `main` deploys production at
<https://winnowwallet.com>. PRs and manually selected branches get previews;
the deployment URL appears in the Actions summary and environment. Fork PRs
validate without deployment credentials. There is no second GitHub Pages site.

## LOC policy

Total source sums nonblank, noncomment lines in app/library/CLI source, tests,
webpages and tooling. Other text has its own physical nonblank count. Fixtures,
vectors, documentation and lockfiles are other text. Shared test helpers count
once per tracked path. Debugging driver code is tooling; its test directory is tests.
Generated fallback peers, dependencies/build output, binaries, symlinks and LFS
pointers are excluded with recorded reasons. Counting policy 4 and schema 1 are
recorded alongside cloc 2.10's verified checksum and commit SHA.

```sh
python3 scripts/report-loc.py --cloc /path/to/cloc-2.10.pl \
  --ref HEAD --base-ref origin/main --output-dir /tmp/winnow-loc
```

Both sides of a PR use the head policy at their merge base. LOC growth is
informational; counting, validation and upload failures fail the job.
