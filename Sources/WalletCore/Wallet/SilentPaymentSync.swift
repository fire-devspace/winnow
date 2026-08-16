import BitcoinCore
import BitcoinP2P
import BlockchainBackend
import Foundation

/// Per-block BIP352 tweak-data source (BIP352 Appendix A: an index server
/// publishes input_hash·A, 33 bytes per silent-payment-eligible transaction).
/// The index is untrusted for credits — every match is resolved against the
/// merkle-verified block and is spendable by construction — but a lying or
/// incomplete index can cause missed payments, which is why sync is
/// fail-closed when it is unreachable.
public protocol TweakIndexClient: Sendable {
    /// The tweak-data points for the block at `height`, one per eligible
    /// transaction (order irrelevant). Empty when the block has none.
    func tweaks(forBlockAt height: UInt32) async throws -> [Data]
}

extension TweakIndexHTTPClient: TweakIndexClient {}

/// One filter-stage candidate: a tweak's k=0 output. Any silent payment to us
/// in that transaction produces exactly this script at k = 0, so it is the
/// per-block entry the BIP158 filter is probed with.
public struct SilentPaymentCandidate: Sendable, Equatable {
    /// input_hash·A from the index (33 bytes).
    public let tweakData: Data
    /// b_scan·tweakData — the receiver ECDH for this transaction.
    public let sharedSecret: Data
    /// P_0 as a P2TR scriptPubKey.
    public let script: Data
}

/// A silent-payment output found in a fetched block.
public struct SilentPaymentFound: Sendable, Equatable {
    public let txid: Data // internal byte order
    public let vout: UInt32
    public let amount: Int64
    public let scriptPubKey: Data
    /// t_k — persisted with the UTXO; the signer spends with b_spend + t_k.
    public let tweak: Data
}

/// Receive-side scanning support around one wallet's scan/spend keys:
/// candidates for the filter stage, match resolution for fetched blocks.
///
/// Labels are out of v1 end-to-end: filter candidates are unlabeled P_0, so
/// the block stage must scan unlabeled too — a labeled match here would be a
/// payment the filter stage can never see. (Our own change stays BIP86, so
/// not even the change label m=0 is needed.)
public struct SilentPaymentBlockScanner: Sendable {
    let scanPrivateKey: Data
    let spendPublicKey: Data

    public init(scanPrivateKey: Data, spendPublicKey: Data) {
        self.scanPrivateKey = scanPrivateKey
        self.spendPublicKey = spendPublicKey
    }

    /// One candidate per index tweak: ECDH with b_scan, then the k=0 script.
    public func candidates(tweaks: [Data]) throws -> [SilentPaymentCandidate] {
        try tweaks.map { tweakData in
            let sharedSecret = try SilentPaymentReceiving.sharedSecret(
                scanPrivateKey: scanPrivateKey, tweakData: tweakData)
            let script = try SilentPaymentSending.outputScript(
                sharedSecret: sharedSecret, spendKey: spendPublicKey, k: 0)
            return SilentPaymentCandidate(tweakData: tweakData, sharedSecret: sharedSecret,
                                          script: script)
        }
    }

    /// Resolves which candidates actually paid us in a fetched block: a
    /// candidate's P_0 script locates its transaction (a filter hit with no
    /// resolving transaction is a BIP158 false positive — credited nothing),
    /// then the full BIP352 scan of that transaction's taproot outputs finds
    /// every k, not just 0. Deduplicates by (txid, vout).
    public func matches(in block: Block,
                        candidates: [SilentPaymentCandidate]) throws -> [SilentPaymentFound] {
        var found: [SilentPaymentFound] = []
        var claimed: Set<Data> = [] // txid ‖ vout
        for candidate in candidates {
            guard let tx = block.transactions.first(where: { tx in
                tx.outputs.contains { $0.scriptPubKey == candidate.script }
            }) else { continue }
            let outputs = tx.outputs
                .filter { $0.scriptPubKey.count == 34 && $0.scriptPubKey.first == 0x51 }
                .map { Data($0.scriptPubKey.dropFirst(2)) }
            let matches = try SilentPaymentReceiving.scan(outputs: outputs,
                                                          sharedSecret: candidate.sharedSecret,
                                                          spendPublicKey: spendPublicKey)
            let txid = tx.txid
            for match in matches {
                let script = Data([0x51, 0x20]) + match.outputKey
                for (vout, output) in tx.outputs.enumerated()
                    where output.scriptPubKey == script {
                    let key = txid + withUnsafeBytes(of: UInt32(vout).littleEndian) { Data($0) }
                    guard !claimed.contains(key) else { continue }
                    claimed.insert(key)
                    found.append(SilentPaymentFound(txid: txid, vout: UInt32(vout),
                                                    amount: output.value, scriptPubKey: script,
                                                    tweak: match.tweak))
                    break
                }
            }
        }
        return found
    }
}
