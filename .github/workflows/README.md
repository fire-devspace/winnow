[Back to main README](../../README.md)

# Repository checks and delivery

GitHub Actions runs the package, app, node, fuzz, website, and size-report checks
and the explicit release/submission operations. Keeping these definitions with
the code makes the checks and release inputs reviewable at the same revision.

[CI and release operations](../internal/ci-release.md) is the runbook.
The [testing guide](../../docs/testing.html) explains what each suite establishes
and how to inspect its artifacts. Release workflows reuse the ordinary checks.

Self-hosted jobs select a prepared runner by labels; machine provisioning and
runner registration are private infrastructure responsibilities.
[node-tests.yml](node-tests.yml) owns only the disposable
test node through [signet-fixture](../../scripts/signet-fixture).
Inspect the exact run and job conclusions; skipped jobs are not fresh evidence.
