[Back to main README](../README.md)

# App decisions and protected actions

These tests exercise the app's state transitions, persistence, privacy, and
authorization boundaries without driving every case through screen taps.
They protect the decisions behind payment review, recovery, and shared savings.

The tests run in the [iOS app host](../Sources/WinnowApp/README.md) and share
fixtures from [TestSupport](../Tests/Support/README.md).
[UI journeys](../UITests/README.md) provide the complementary screen-level checks.

Run `scripts/ci-app-tests /tmp/winnow-app-tests` from the repository root with
Xcode and a simulator installed. [CI](../.github/workflows/ci.yml) retains the
result bundle and logs. Keychain attributes and authentication policy are tested;
actual locked-device behavior still needs [device evidence](../docs/security/README.md).
