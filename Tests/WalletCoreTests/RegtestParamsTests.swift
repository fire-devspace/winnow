import Foundation
import Testing
import TestSupport
@testable import WalletCore

/// Regtest as a network: the constants are Core's, proven by building the
/// genesis header from them and getting Core's genesis hash back, and by
/// the header chain accepting that genesis as its root.
@Suite("Regtest")
struct RegtestParamsTests {
    @Test("the genesis constants hash to Core's regtest genesis")
    func genesis() async throws {
        let params = NetworkParams.regtest
        #expect(params.network == .regtest)
        #expect(params.magic == Data([0xFA, 0xBF, 0xB5, 0xDA]))
        #expect(params.defaultPort == 18_444)
        #expect(params.dnsSeeds.isEmpty)
        #expect(params.checkpoint == nil)
        let chain = try HeaderChain(params: params, start: .genesis)
        #expect(await chain.height == 0)
        #expect(await chain.tipHash == params.genesisHash)
        #expect(NetworkParams.params(for: .regtest) == params)
    }

    @Test("addresses, coin type and key versions are the test-network ones")
    func derivation() throws {
        #expect(AddressDecoder.hrp(for: .regtest) == "bcrt")
        #expect(Wallet.coinType(for: .regtest) == 1)
        #expect(Wallet.hdNetwork(for: .regtest) == .testnet)
        let key = Data(repeating: 0x02, count: 32)
        let address = try BIP86.address(internalKey: key, hrp: "bcrt")
        #expect(address.hasPrefix("bcrt1p"))
        let script = try AddressDecoder.scriptPubKey(for: address, network: .regtest)
        #expect(script.count == 34 && script[script.startIndex] == 0x51)
        #expect(throws: (any Error).self) { _ = try AddressDecoder.scriptPubKey(for: address, network: .signet) }
    }
}
