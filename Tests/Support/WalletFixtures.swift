import BitcoinCore
import WalletCore
import Foundation

/// The well-known BIP39 all-"abandon" mnemonic's 16-byte entropy.
public let testEntropy = Data(repeating: 0, count: 16)
/// …and its mnemonic sentence. The harness never holds real funds.
public let testMnemonic = "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about"

public func testMaster(network _: BitcoinNetwork = .signet) throws -> HDKey {
    try HDKey(seed: BIP39.seed(mnemonic: testMnemonic))
}

/// A no-PoW block header — `Wallet.apply` trusts the FilterSync match, so
/// fixtures don't need mining.
public func fakeHeader(previousHash: Data = Data(repeating: 0, count: 32),
                       time: UInt32 = 1_700_000_000) -> BlockHeader {
    BlockHeader(version: 2, previousHash: previousHash, merkleRoot: Data(repeating: 0xAA, count: 32),
                time: time, bits: 0x207F_FFFF, nonce: 0)
}

/// A coinbase-like input (never our spend).
public func coinbaseInput() -> Transaction.Input {
    Transaction.Input(previousOutput: Transaction.Outpoint(txid: Data(repeating: 0, count: 32),
                                                           vout: 0xFFFF_FFFF),
                      scriptSig: Data([0x01]), sequence: 0xFFFF_FFFF)
}

/// After applying a coinbase at `height`, record a scan frontier that makes it
/// consensus-mature (`Wallet.coinbaseMaturity` confirmations).
public func matureCoinbase(_ wallet: Wallet, height: UInt32) async throws {
    try await wallet.recordScanHeight(height + Wallet.coinbaseMaturity)
}

/// A match carrying `transactions` at `height`, wrapped in a fake block.
public func fakeMatch(height: UInt32, transactions: [Transaction]) -> BlockMatch {
    let block = Block(header: fakeHeader(time: 1_700_000_000 + height), transactions: transactions)
    return BlockMatch(height: height, blockHash: block.hash, block: block)
}

/// A plausible validated tip for tests that build a send.
///
/// Paired with a fixed draw of 0.5 at the call sites, which misses the
/// one-in-ten lookback branch, so the resulting locktime is exactly this and
/// the transaction is byte-stable across runs. Tests that care about the
/// locktime itself live in "Anti-fee-sniping locktime"; everything else just
/// needs sends to look like real ones (#139).
public let testChainTip: UInt32 = 840_000

/// A fresh wallet on the test mnemonic, created at `creationHeight`. The
/// parameter order follows the wrapper every suite used to write for itself.
public func makeTestWallet(network: BitcoinNetwork = .signet,
                           storageURL: URL? = nil,
                           keyStore: any KeyStore = InMemoryKeyStore(),
                           creationHeight: UInt32 = 100) throws -> Wallet {
    try Wallet.create(network: network, keyStore: keyStore, storageURL: storageURL,
                      entropy: testEntropy, creationHeight: creationHeight)
}

/// Pays `amount` to the wallet's (`chain`, `index`) address from a coinbase
/// seen in a block at `height`, and returns that funding transaction. The
/// coin is immature until `matureCoinbase` records a deep enough frontier.
@discardableResult
public func fund(_ wallet: Wallet, amount: Int64, height: UInt32,
                 chain: AddressChain = .receive, index: UInt32 = 0) async throws -> Transaction {
    let script = try await wallet.scriptPubKey(chain: chain, index: index)
    let funding = Transaction(version: 2, inputs: [coinbaseInput()], outputs: [
        Transaction.Output(value: amount, scriptPubKey: script),
    ], locktime: 0)
    try await wallet.apply(match: fakeMatch(height: height, transactions: [funding]))
    return funding
}

/// A fresh wallet funded with one coinbase per entry of `coins`, in order,
/// then (when `mature`) matured past the highest funding height — the
/// prologue most wallet tests share. Returns the funding transactions in the
/// same order, so a test can spend or re-find them.
public func fundedWallet(network: BitcoinNetwork = .signet,
                         storageURL: URL? = nil,
                         keyStore: any KeyStore = InMemoryKeyStore(),
                         creationHeight: UInt32 = 100,
                         coins: [(chain: AddressChain, index: UInt32, amount: Int64, height: UInt32)]
                             = [(.receive, 0, 500_000, 100)],
                         mature: Bool = true) async throws -> (wallet: Wallet, fundings: [Transaction]) {
    let wallet = try makeTestWallet(network: network, storageURL: storageURL,
                                    keyStore: keyStore, creationHeight: creationHeight)
    var fundings: [Transaction] = []
    for coin in coins {
        fundings.append(try await fund(wallet, amount: coin.amount, height: coin.height,
                                       chain: coin.chain, index: coin.index))
    }
    if mature, let top = coins.map({ $0.height }).max() {
        try await matureCoinbase(wallet, height: top)
    }
    return (wallet, fundings)
}
