[Back to main README](../../../README.md)

# Retained network-soak observations

The two JSONL files retain public-signet observations from 2026-08-24, including
a scan and a run already at the tip. They let a reviewer inspect the measurements
behind historical network findings rather than relying only on a summary.

[The audit manifest](../audit-manifest.md) and
[findings register](../findings.md) provide context.
These records predate the current debugging command layout; preserve their
original contents and interpretation.

For a new run, use the [debugging runbook](../../../Tools/Debug/README.md) and keep
the revision, command, network, time interval, and resulting JSONL together.
Add a new dated record instead of overwriting these files.
They are historical evidence, not a live health check or an automated test fixture.
