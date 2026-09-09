import Foundation
import Testing
import TestSupport
@testable import WalletCore

/// Bounds on hostile descriptor text (epic #100, invariants S7 and S10).
///
/// Descriptors arrive from places the wallet does not control: a string pasted
/// into vault creation, an imported bundle, and — most importantly — persisted
/// vault records, which are parsed while the app is starting up.
///
/// The descriptor parser is recursive descent. Before the depth bound, a tap
/// tree nested about a thousand levels deep exhausted the stack and terminated
/// the process with a signal rather than an error. That failure mode is worse
/// than a rejected descriptor in a specific way: stack exhaustion is not a
/// Swift error, so none of the fail-closed damaged-storage handling can
/// intercept it, and a hostile record would take the app down at every launch.
@Suite("Descriptor input bounds")
struct DescriptorBoundsTests {
    static let key = "xpub6FC1fXFP1GXQpyRFfSE1vzzySqs3Vg63bzimYLeqtNUYbzA87kMNTcuy9ubr7MmavGRjW2FRYHP4WGKjwutbf1ghgkUW9H7e3ceaPLRcVwa"
    static let nums = Taproot.unspendableInternalKey.hex

    /// `{{{pk,pk},pk},pk}` nested `depth` levels: `depth` opening braces,
    /// the innermost `pk`, then `depth` closing `,pk}`. Built in one pass so
    /// the 50,000-level fixture below is linear in `depth`, not quadratic.
    static func nested(depth: Int) -> String {
        let leaf = "pk(\(key))"
        let inner = String(repeating: "{", count: depth) + leaf
            + String(repeating: ",\(leaf)}", count: depth)
        return "tr(\(nums),\(inner))"
    }

    /// A tree at the BIP341 maximum is legitimate and must still parse.
    /// Without this control, the refusals below could be explained by the
    /// parser rejecting all nesting.
    @Test("a tree at the BIP341 maximum depth parses")
    func maximumDepthAccepted() throws {
        let descriptor = try Descriptor(Self.nested(depth: 128))
        #expect(descriptor.serialized().hasPrefix("tr("))
    }

    /// One level past the consensus maximum is refused. A deeper tree can
    /// never produce a valid control block, so accepting it would only ever
    /// create an unspendable output.
    @Test("a tree one level past the maximum is refused")
    func justOverMaximumRefused() {
        #expect(throws: DescriptorError.treeTooDeep) {
            _ = try Descriptor(Self.nested(depth: 129))
        }
    }

    /// The depth that used to terminate the process. This is the regression
    /// test for the crash: it must now return an error rather than take the
    /// test runner down with it.
    @Test("a tree deep enough to exhaust the stack is refused, not fatal")
    func stackExhaustingDepthRefused() {
        #expect(throws: DescriptorError.treeTooDeep) {
            _ = try Descriptor(Self.nested(depth: 1_000))
        }
    }

    /// Far beyond any plausible input, to show the bound is checked before
    /// recursion rather than after it.
    @Test("an absurdly deep tree is refused promptly", arguments: [5_000, 50_000])
    func absurdDepthRefused(_ depth: Int) {
        #expect(throws: DescriptorError.treeTooDeep) {
            _ = try Descriptor(Self.nested(depth: depth))
        }
    }

    /// Unbalanced nesting fails as a parse error rather than running off the
    /// end of the input.
    @Test("unbalanced nesting is refused")
    func unbalancedNestingRefused() {
        #expect(throws: (any Error).self) {
            _ = try Descriptor("tr(\(Self.nums),\(String(repeating: "{", count: 64))pk(\(Self.key)))")
        }
    }

    /// Ordinary descriptors are unaffected.
    @Test("a shallow descriptor still parses")
    func shallowDescriptorUnaffected() throws {
        let descriptor = try Descriptor(Self.nested(depth: 2))
        #expect(descriptor.serialized().hasPrefix("tr("))
    }

    /// `tr([fp/0/0/...]KEY/<0;1>/*)` with `steps` origin steps: the wallet's
    /// own descriptor shape, so `Wallet.origin(of:)` and an import bundle both
    /// accept the text on every ground except its length.
    static func longOrigin(steps: Int) -> String {
        "tr([73c5da0a\(String(repeating: "/0", count: steps))]\(key)/<0;1>/*)"
    }

    /// A key origin can name at most as many steps as a BIP32 key can be deep.
    /// This is a different bound from the tree's and a different failure: the
    /// tree exhausted the stack inside the parser, while a long origin parsed
    /// happily and terminated the process later, wherever the path was walked.
    /// `depth` is a `UInt8` and `child(at:)` computes `depth + 1`, so the 256th
    /// step overflows in whoever is walking — which the descriptor's own key
    /// resolution does, and which signing does.
    ///
    /// A hostile import bundle used to reach that: the descriptor parsed, the
    /// wallet was built, and the first attempt to sign took the app down. The
    /// refusal now lands at the parse, so `Wallet.origin(of:)` and
    /// `Wallet.importing` never see the descriptor at all — they report the
    /// same error because the text never becomes a `Descriptor`.
    @Test("an origin path longer than a key can be deep is refused")
    func longOriginPathRefused() {
        #expect(throws: DescriptorError.originTooDeep(steps: 256, limit: 255)) {
            _ = try Descriptor(Self.longOrigin(steps: 300))
        }
        #expect(throws: (any Error).self) {
            _ = try Wallet.origin(of: Descriptor(Self.longOrigin(steps: 300)))
        }
        let bundle = ImportBundle(network: "signet", descriptor: Self.longOrigin(steps: 300),
                                  lastKnownHeight: 100)
        #expect(throws: (any Error).self) {
            _ = try Wallet.importing(bundle, keyStore: InMemoryKeyStore())
        }
    }

    /// The control the refusal needs: the longest origin a key can actually
    /// have still parses, and the first step past it does not. Without this the
    /// bound could be off by one, or refuse every origin, and the test above
    /// would pass either way.
    @Test("an origin path at the maximum depth parses, one past it does not")
    func maximumOriginPathAccepted() throws {
        let descriptor = try Descriptor(Self.longOrigin(steps: 255))
        #expect(try Wallet.origin(of: descriptor).path.count == 255)
        #expect(throws: (any Error).self) {
            _ = try Descriptor(Self.longOrigin(steps: 256))
        }
        // And an ordinary wallet origin is three steps, nowhere near it.
        #expect(try Wallet.origin(of: Descriptor(Self.longOrigin(steps: 3))).path.count == 3)
    }

    /// Pins the one-pass builder to the tree written out level by level —
    /// the text every depth above hands the parser.
    @Test("the nested fixture is the level-by-level tree")
    func nestedFixtureShape() {
        let pk = "pk(\(Self.key))"
        #expect(Self.nested(depth: 3) == "tr(\(Self.nums),{{{\(pk),\(pk)},\(pk)},\(pk)})")
    }
}
