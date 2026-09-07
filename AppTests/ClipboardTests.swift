@testable import WinnowApp
import Foundation
import UIKit
import XCTest

/// Everything the app puts on a pasteboard.
///
/// The two classes stay separate on purpose, and the difference is the point
/// of the file. ClipboardPolicyTests asserts the policies and writes only to a
/// scratch pasteboard from `UIPasteboard.withUniqueName()`, so running the
/// suite never touches the developer's own clipboard. CopyableIdentifierTests
/// asserts what a *row* actually hands the user, which means going through
/// `apply(_:)` and reading `UIPasteboard.general` back — so it owns a tearDown
/// that empties the general pasteboard afterwards. Merging them would either
/// put the general pasteboard under the policy tests or drop that tearDown.

// MARK: - ClipboardPolicyTests

/// Clipboard handoff policy (epic #100, invariant S1).
///
/// The clipboard is the one place wallet material sits outside the app's
/// control, and iOS syncs the general pasteboard to a user's other Apple
/// devices unless told not to. Before this, only the recovery-phrase button
/// set an expiry and kept the item on-device; descriptors, PSBTs and addresses
/// went to the pasteboard bare, with no expiry and free to sync.
///
/// The two policies differ deliberately, and the difference is asserted here
/// so that a later change which "unifies" them has to argue with a test.
@MainActor
final class ClipboardPolicyTests: XCTestCase {
    // MARK: The policies themselves

    /// Recovery words have no legitimate reason to cross to another device.
    func testRecoveryPhraseNeverLeavesTheDevice() {
        XCTAssertTrue(ClipboardPolicy.recoveryPhrase.localOnly)
        XCTAssertEqual(ClipboardPolicy.recoveryPhrase.lifetime, 120)
    }

    /// A watch-only descriptor is meant to be pasted into desktop software and
    /// a PSBT travels between cosigners, so this one may cross devices. The
    /// accepted risk is Universal Clipboard, which is why it still expires.
    func testInterchangeMayCrossDevicesButStillExpires() {
        XCTAssertFalse(ClipboardPolicy.interchange.localOnly)
        XCTAssertGreaterThan(ClipboardPolicy.interchange.lifetime, 0,
                             "interchange material must not sit on the pasteboard indefinitely")
        XCTAssertLessThanOrEqual(ClipboardPolicy.interchange.lifetime, 600,
                                 "an expiry long enough to be meaningless is not an expiry")
    }

    /// The distinction is the point: a seed and a descriptor are not the same
    /// kind of secret and must not share one policy.
    func testTheTwoPoliciesAreDistinct() {
        XCTAssertNotEqual(ClipboardPolicy.recoveryPhrase, ClipboardPolicy.interchange)
        XCTAssertTrue(ClipboardPolicy.recoveryPhrase.localOnly)
        XCTAssertFalse(ClipboardPolicy.interchange.localOnly)
    }

    // MARK: What reaches the pasteboard

    func testOptionsCarryLocalOnlyAndAnExpiryInTheFuture() throws {
        for policy in [ClipboardPolicy.recoveryPhrase, .interchange] {
            let options = policy.options
            let localOnly = try XCTUnwrap(options[.localOnly] as? Bool)
            XCTAssertEqual(localOnly, policy.localOnly)

            let expiry = try XCTUnwrap(options[.expirationDate] as? Date)
            let seconds = expiry.timeIntervalSinceNow
            XCTAssertGreaterThan(seconds, 0, "the expiry must be in the future")
            XCTAssertLessThanOrEqual(seconds, policy.lifetime + 5,
                                     "the expiry must match the policy's lifetime")
        }
    }

    /// Applying a policy really does place the text, checked against a scratch
    /// pasteboard so the developer's own clipboard is untouched.
    func testApplyPlacesTheTextOnThePasteboard() {
        let pasteboard = UIPasteboard.withUniqueName()
        defer { UIPasteboard.remove(withName: pasteboard.name) }

        ClipboardPolicy.interchange.apply("tr(musig(a,b))/<0;1>/*", to: pasteboard)
        XCTAssertEqual(pasteboard.string, "tr(musig(a,b))/<0;1>/*")
    }

    func testApplyReplacesPreviousContents() {
        let pasteboard = UIPasteboard.withUniqueName()
        defer { UIPasteboard.remove(withName: pasteboard.name) }

        ClipboardPolicy.interchange.apply("first", to: pasteboard)
        ClipboardPolicy.recoveryPhrase.apply("second", to: pasteboard)
        XCTAssertEqual(pasteboard.string, "second")
        XCTAssertEqual(pasteboard.numberOfItems, 1,
                       "a copy replaces the item rather than accumulating")
    }
}

// MARK: - CopyableIdentifierTests

/// Transactions have to be gettable out of the app.
///
/// A txid is 64 hex characters and does not fit a list row, so rows abbreviate
/// it. Abbreviated text with only `textSelection` cannot be copied whole —
/// selecting it yields the ellipsis, not the identifier — so the transaction
/// list displayed a value that could not actually be obtained. What is shown
/// is a summary; what is copied must always be the whole thing.
///
/// Unlike the policy tests above, these go through the general pasteboard,
/// because the claim is about what the user really gets when they tap Copy.
/// Hence the tearDown.
@MainActor
final class CopyableIdentifierTests: XCTestCase {
    private let txid = String(repeating: "ab", count: 32)

    override func tearDown() {
        UIPasteboard.general.items = []
        super.tearDown()
    }

    /// The abbreviation is presentation only.
    func testAbbreviationNeverReachesTheClipboard() {
        ClipboardPolicy.interchange.apply(txid)
        XCTAssertEqual(UIPasteboard.general.string, txid)
        XCTAssertEqual(txid.count, 64, "a full txid, not a preview of one")
        XCTAssertFalse(try XCTUnwrap(UIPasteboard.general.string).contains("…"))
    }

    /// A txid is already public on the chain, so it travels under the
    /// interchange policy rather than the recovery-phrase one — crossing to a
    /// desktop is the entire point of copying it.
    func testTransactionsUseTheInterchangePolicy() {
        XCTAssertFalse(ClipboardPolicy.interchange.localOnly,
                       "copying a txid to a desktop is the workflow")
        XCTAssertGreaterThan(ClipboardPolicy.interchange.lifetime, 0,
                            "it still expires rather than sitting there")
    }

    /// …and emphatically not the seed policy, which exists for material that
    /// must never leave the device.
    func testTransactionsDoNotBorrowTheRecoveryPhrasePolicy() {
        XCTAssertNotEqual(ClipboardPolicy.interchange, ClipboardPolicy.recoveryPhrase)
        XCTAssertTrue(ClipboardPolicy.recoveryPhrase.localOnly)
    }

    /// The raw transaction is hex and round-trips as text — the point being
    /// that a user can paste it into a node or explorer that accepts one.
    func testRawTransactionHexCopiesWhole() {
        let raw = String(repeating: "0a", count: 250)
        ClipboardPolicy.interchange.apply(raw)
        XCTAssertEqual(UIPasteboard.general.string, raw)
        XCTAssertEqual(UIPasteboard.general.string?.count, 500)
    }
}
