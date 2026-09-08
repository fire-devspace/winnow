import Foundation
import TestSupport
@testable import WalletCore

/// Master switch: the differential suite talks to the dev custom-signet node
/// ONLY when WINNOW_DIFF=1 is set. Default `swift test` runs skip cleanly
/// and never touch the network or the node.
///
/// Run it as:
///
///     scripts/signet-fixture up
///     WINNOW_DIFF=1 swift test --filter DiffTests --no-parallel
///
/// `--no-parallel` is required. Two suites mine onto the same tip, and run
/// concurrently they race for every block — each re-mines on the winner, and
/// the run stalls indefinitely instead of failing, which looks exactly like a
/// hang with no output.
let diffEnabled = ProcessInfo.processInfo.environment["WINNOW_DIFF"] == "1"
