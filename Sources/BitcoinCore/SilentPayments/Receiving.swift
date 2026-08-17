import CryptoKit
import Foundation
import P256K

public enum SilentPaymentReceivingError: Error, Equatable {
    /// The scan private key is not a valid nonzero scalar.
    case invalidScanKey
    /// The spend key is not a valid compressed/x-only secp256k1 public key.
    case invalidSpendKey
    /// An input public key is not a valid compressed secp256k1 public key.
    case invalidInputPublicKey
    /// hash_BIP0352/Inputs is not a valid scalar — BIP352: fail (negligible).
    case invalidInputHash
    /// hash_BIP0352/SharedSecret is not a valid scalar — BIP352: fail (negligible).
    case invalidTweak
    /// hash_BIP0352/Label is not a valid scalar (negligible probability).
    case invalidLabel
    /// The tweak data is not a valid compressed secp256k1 public key.
    case invalidTweakData
    /// b_spend + tweak is not a valid signing key (zero sum or bad operand).
    case invalidSpendSecret
}

/// BIP352 silent payments, receive side: scan/spend key derivation, address
/// building, per-transaction tweak data (what a tweak-index server publishes),
/// the receiver ECDH, and the §Scanning loop. Transport-agnostic — callers
/// supply tweak data and the taproot output keys of candidate transactions;
/// fetching them (tweak index + BIP158 filter stream) lives above BitcoinCore.
public enum SilentPaymentReceiving {
    /// BIP352 K_max: the receiver stops scanning at k = K_max, so one
    /// transaction yields at most this many matches (DoS limit).
    public static let scanLimit = SilentPaymentSending.maxRecipientsPerGroup

    // MARK: - Key derivation (BIP352 §Key Derivation)

    /// scan_private_key: m/352'/coinType'/account'/1'/0 — hardened through the
    /// change level so the exported scan key exposes neither the master nor
    /// the spend branch; the final index is non-hardened per the BIP.
    public static func scanKey(from master: HDKey, coinType: UInt32 = 0,
                               account: UInt32 = 0) throws -> HDKey {
        try master.derived(path: "m/352'/\(coinType)'/\(account)'/1'/0")
    }

    /// spend_private_key: m/352'/coinType'/account'/0'/0.
    public static func spendKey(from master: HDKey, coinType: UInt32 = 0,
                                account: UInt32 = 0) throws -> HDKey {
        try master.derived(path: "m/352'/\(coinType)'/\(account)'/0'/0")
    }

    // MARK: - Addresses

    /// The receiver's own address: B_scan = b_scan·G and B_m = B_spend (plus
    /// hash_BIP0352/Label(ser256(b_scan) ‖ ser32(m))·G when a label is given).
    /// hrp is "sp" (mainnet) or "tsp" (test networks).
    public static func address(scanPrivateKey: Data, spendPublicKey: Data,
                               label: UInt32? = nil, hrp: String = "sp") throws -> SilentPaymentAddress {
        guard let scanPub = try? SilentPaymentSending.publicKeyPoint(scanPrivateKey) else {
            throw SilentPaymentReceivingError.invalidScanKey
        }
        guard var spendPoint = try? P256K.Signing.PublicKey(dataRepresentation: spendPublicKey,
                                                            format: .compressed) else {
            throw SilentPaymentReceivingError.invalidSpendKey
        }
        if let label {
            let tweak = try labelTweak(scanPrivateKey: scanPrivateKey, label: label)
            guard let labelPoint = try? P256K.Signing.PrivateKey(dataRepresentation: tweak).publicKey,
                  let labeled = try? spendPoint.combine([labelPoint], format: .compressed) else {
                throw SilentPaymentReceivingError.invalidLabel
            }
            spendPoint = labeled
        }
        return try SilentPaymentAddress(scanKey: scanPub, spendKey: spendPoint.dataRepresentation,
                                        hrp: hrp)
    }

    /// hash_BIP0352/Label(ser256(b_scan) ‖ ser32(m)) — the label tweak scalar.
    public static func labelTweak(scanPrivateKey: Data, label: UInt32) throws -> Data {
        guard scanPrivateKey.count == 32 else { throw SilentPaymentReceivingError.invalidScanKey }
        var bigEndianLabel = label.bigEndian
        let tweak = TaggedHash.hash("BIP0352/Label",
                                    scanPrivateKey + withUnsafeBytes(of: &bigEndianLabel) { Data($0) })
        guard SilentPaymentSending.isValidScalar(tweak) else {
            throw SilentPaymentReceivingError.invalidLabel
        }
        return tweak
    }

    // MARK: - Tweak data (BIP352 Appendix A: what a tweak index serves)

    /// A = A₁ + … + Aₙ over the eligible input public keys; nil when there are
    /// none or the sum is the point at infinity (BIP352: skip the transaction).
    public static func inputPublicKeySum(_ inputPublicKeys: [Data]) throws -> Data? {
        let points = try inputPublicKeys.map { key -> P256K.Signing.PublicKey in
            guard let point = try? P256K.Signing.PublicKey(dataRepresentation: key,
                                                           format: .compressed) else {
                throw SilentPaymentReceivingError.invalidInputPublicKey
            }
            return point
        }
        guard let first = points.first else { return nil }
        guard points.count > 1 else { return first.dataRepresentation }
        // combine sums all points at once, so a zero intermediate sum is fine;
        // it fails only when the final sum is the point at infinity.
        guard let sum = try? first.combine(Array(points.dropFirst()), format: .compressed) else {
            return nil
        }
        return sum.dataRepresentation
    }

    /// input_hash·A, 33 bytes — the per-transaction tweak data, with
    /// input_hash = hash_BIP0352/Inputs(outpoint_L ‖ A) over the smallest
    /// outpoint (COutPoint serialization) of ALL transaction inputs.
    public static func tweakData(inputPublicKeySum: Data, smallestOutpoint: Data) throws -> Data {
        guard let sum = try? P256K.Signing.PublicKey(dataRepresentation: inputPublicKeySum,
                                                     format: .compressed) else {
            throw SilentPaymentReceivingError.invalidInputPublicKey
        }
        let inputHash = TaggedHash.hash("BIP0352/Inputs", smallestOutpoint + sum.dataRepresentation)
        guard SilentPaymentSending.isValidScalar(inputHash),
              let tweaked = try? sum.multiply([UInt8](inputHash)) else {
            throw SilentPaymentReceivingError.invalidInputHash
        }
        return tweaked.dataRepresentation
    }

    /// ecdh_shared_secret = input_hash·b_scan·A = b_scan·(tweak data),
    /// serialized compressed. The receiver never needs input_hash or A
    /// individually — exactly why the index can serve their product.
    public static func sharedSecret(scanPrivateKey: Data, tweakData: Data) throws -> Data {
        guard SilentPaymentSending.isValidScalar(scanPrivateKey) else {
            throw SilentPaymentReceivingError.invalidScanKey
        }
        guard let point = try? P256K.Signing.PublicKey(dataRepresentation: tweakData,
                                                       format: .compressed),
              let shared = try? point.multiply([UInt8](scanPrivateKey)) else {
            throw SilentPaymentReceivingError.invalidTweakData
        }
        return shared.dataRepresentation
    }

    // MARK: - Spending (BIP352 §Spending)

    /// d = (b_spend + tweak) mod n — the key-path secret of a matched output.
    /// BIP352 outputs carry no BIP341 TapTweak: d signs directly (BIP340
    /// negates internally when d·G has odd Y).
    public static func spendSecret(spendPrivateKey: Data, tweak: Data) throws -> Data {
        guard SilentPaymentSending.isValidScalar(spendPrivateKey),
              SilentPaymentSending.isValidScalar(tweak),
              let secret = try? SilentPaymentSending.scalarAdd(spendPrivateKey, tweak),
              SilentPaymentSending.isValidScalar(secret) else {
            throw SilentPaymentReceivingError.invalidSpendSecret
        }
        return secret
    }

    // MARK: - Scanning (BIP352 §Scanning)

    /// One detected payment. `tweak` is what the signer adds to b_spend
    /// (t_k, plus the label tweak for labeled matches) — it must be persisted
    /// with the UTXO or the output is unspendable without a rescan.
    public struct Match: Equatable, Sendable {
        /// 32-byte x-only taproot output key, as it appears in the transaction.
        public let outputKey: Data
        /// t_k (+ label tweak) mod n; spend with d = b_spend + tweak.
        public let tweak: Data
        /// The matched label m, nil for the plain address.
        public let label: UInt32?
    }

    /// The receiver's precomputed label set: hash_BIP0352/Label(b_scan ‖ m)·G
    /// per label, looked up by point during scanning (BIP352 recommends
    /// precomputation over per-output addition).
    public struct Labels: Sendable {
        struct Entry: Sendable {
            let label: UInt32
            let tweak: Data
        }

        let byPoint: [Data: Entry]

        /// No labels — matches only the plain address.
        public static let none = Labels(byPoint: [:])

        private init(byPoint: [Data: Entry]) {
            self.byPoint = byPoint
        }

        public init(scanPrivateKey: Data, labels: [UInt32]) throws {
            var byPoint: [Data: Entry] = [:]
            for label in labels {
                let tweak = try SilentPaymentReceiving.labelTweak(scanPrivateKey: scanPrivateKey,
                                                                  label: label)
                guard let point = try? P256K.Signing.PrivateKey(dataRepresentation: tweak).publicKey else {
                    throw SilentPaymentReceivingError.invalidLabel
                }
                byPoint[point.dataRepresentation] = Entry(label: label, tweak: tweak)
            }
            self.byPoint = byPoint
        }

        public var isEmpty: Bool { byPoint.isEmpty }
    }

    /// Runs the BIP352 scanning loop over one transaction's taproot output
    /// keys (32-byte x-only, spent and unspent). Starting at k = 0: compute
    /// P_k = B_spend + t_k·G; a direct hit consumes the output and rescans the
    /// remainder with k+1; otherwise each output is checked against the label
    /// set via output − P_k (both lifts of the x-only output). No match at the
    /// current k — or k reaching K_max — stops the scan.
    public static func scan(outputs: [Data], sharedSecret: Data, spendPublicKey: Data,
                            labels: Labels = .none) throws -> [Match] {
        guard let spendPoint = try? P256K.Signing.PublicKey(dataRepresentation: spendPublicKey,
                                                            format: .compressed) else {
            throw SilentPaymentReceivingError.invalidSpendKey
        }
        guard sharedSecret.count == 33 else { throw SilentPaymentReceivingError.invalidTweakData }
        var remaining = outputs.filter { $0.count == 32 }
        var matches: [Match] = []
        var k: UInt32 = 0
        scanning: while !remaining.isEmpty, k < UInt32(scanLimit) {
            var bigEndianK = k.bigEndian
            let tweak = TaggedHash.hash("BIP0352/SharedSecret",
                                        sharedSecret + withUnsafeBytes(of: &bigEndianK) { Data($0) })
            guard SilentPaymentSending.isValidScalar(tweak),
                  let tweakPoint = try? P256K.Signing.PrivateKey(dataRepresentation: tweak).publicKey,
                  let candidate = try? spendPoint.combine([tweakPoint], format: .compressed) else {
                throw SilentPaymentReceivingError.invalidTweak
            }
            let candidateXonly = candidate.dataRepresentation.dropFirst()
            if let index = remaining.firstIndex(where: { $0 == candidateXonly }) {
                matches.append(Match(outputKey: remaining[index], tweak: tweak, label: nil))
                remaining.remove(at: index)
                k += 1
                continue
            }
            if !labels.isEmpty {
                let negatedCandidate = candidate.negation
                for (index, output) in remaining.enumerated() {
                    // x-only outputs hide the Y coordinate, so try both lifts
                    // (BIP352: "negate output and check a second time").
                    for parity: UInt8 in [0x02, 0x03] {
                        guard let outputPoint = try? P256K.Signing.PublicKey(
                                dataRepresentation: Data([parity]) + output, format: .compressed),
                              let difference = try? outputPoint.combine([negatedCandidate],
                                                                        format: .compressed),
                              let entry = labels.byPoint[difference.dataRepresentation]
                        else { continue }
                        let fullTweak = try SilentPaymentSending.scalarAdd(tweak, entry.tweak)
                        matches.append(Match(outputKey: output, tweak: fullTweak, label: entry.label))
                        remaining.remove(at: index)
                        k += 1
                        continue scanning
                    }
                }
            }
            break
        }
        return matches
    }
}
