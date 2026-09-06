# Deterministic fuzzing

The harness covers nine parsing surfaces: PSBT, descriptors, transactions,
blocks, wire messages, framing, filters, addresses, and import bundles. It
uses the local Bitcoin modules as a development target in the root package.
It is excluded from the app target and counted as test code.

From the repository root, run the fixed regression corpus:

```sh
swift run --configuration release WinnowFuzz \
  --iterations 1000 --seed 0x57494e4e4f575055 --max-input 16384 \
  --artifact-dir /tmp/fuzz-smoke
```

Every iteration exercises all nine targets, so this runs 9,000 deterministic
cases. Use `--target psbt` (or another target name) to focus a run. Keep the
target selection, seed, input limit, and iteration count when replaying.

CI runs the fixed corpus for PRs, main, and Winnow releases. The separate weekly
and manually dispatched lanes run 25,000 iterations per sanitizer with
distinct rotating seeds: 225,000 cases under Address Sanitizer and another
225,000 under Thread Sanitizer. A manual `replay_seed` input reproduces a
recorded seed. For example, replay an address-sanitized run locally with:

```sh
swift run --scratch-path /tmp/fuzz-address-build \
  --configuration release --sanitize address WinnowFuzz \
  --iterations 25000 --seed 0x57494e4e4f575055 --max-input 65536 \
  --artifact-dir /tmp/fuzz-address
```

Use `--sanitize thread` and a separate scratch path for Thread Sanitizer.
CI records `seed.txt` before starting and uploads it with `run.log`; detected
invariant failures also save the input bytes. A crash or timeout may stop the
process before an input is saved, so retain the run's seed and configuration.

The source and embedded corpus were migrated unchanged from revision
`0f051dadc94f99355577632b0cc8c30c9357d8a1` of the former harness repository.
They remain covered by the repository's MIT license.
