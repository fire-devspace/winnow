import BitcoinCore
import Foundation
import Testing
@testable import BitcoinP2P

/// Always-on validation of the committed fallback list (#161).
///
/// The generator, `winnow-generate fallback-peers`, runs only on the release
/// path; this runs on every CI pass, so a hand edit that breaks the list's invariants fails immediately
/// rather than at the next release.
@Suite("Fallback peer list")
struct FallbackPeerListTests {
    @Test("the committed mainnet list holds the generator's own invariants")
    func committedListIsValid() throws {
        let peers = NetworkParams.mainnet.fallbackPeers
        #expect(peers.count >= 8, "shorter than the hand-curated list it replaced")

        var seenBlocks: Set<String> = []
        var seenHosts: Set<String> = []
        for peer in peers {
            // IP literals only: a hostname would add a resolver to the trust
            // story, and `netblock` is nil for hostnames — which doubles as
            // the literal check.
            let block = try #require(peer.netblock,
                                     "\(peer.host) is not a public IP literal")
            #expect(!seenBlocks.contains(block),
                    "\(peer.host) shares a netblock with an earlier entry")
            #expect(!seenHosts.contains(peer.host), "\(peer.host) is listed twice")
            seenBlocks.insert(block)
            seenHosts.insert(peer.host)
            #expect(peer.port == 8_333)
        }
    }
}
