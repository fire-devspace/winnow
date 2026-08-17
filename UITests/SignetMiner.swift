import BitcoinCore
import BitcoinP2P
import CryptoKit
import Foundation
import P256K

/// BIP325 signet miner for the dev node. Core 31.1's `generatetoaddress`
/// builds blocks but does NOT sign them for custom signets (no signet
/// signing path in rpc/mining.cpp — the node rejects them with
/// bad-signet-blksig), so the harness runs the whole cycle itself:
/// getblocktemplate → build coinbase → BIP325 block signature (legacy
/// SIGHASH_ALL against the challenge) → PoW grind → submitblock.
///
/// Copy of Tests/DifferentialTests/SignetMiner.swift (the SPM test target and
/// the Xcode UI-test target are separate worlds; keep them in sync).
enum SignetMiner {
    enum MinerError: Error, Equatable {
        case wallet(String)
        case rejected(String)
    }

    private static func sha256d(_ data: Data) -> Data {
        Data(SHA256.hash(data: Data(SHA256.hash(data: data))))
    }

    /// The challenge's signing secret, from the miner wallet's private
    /// descriptor (WIF inside `multi(1,<wif>)`). Never printed.
    private static func signingSecret() throws -> Data {
        let result = try BitcoinCLI.runObject(["listdescriptors", "true"], wallet: "miner")
        let descriptors = try BitcoinCLI.array(result, "descriptors")
        guard let descriptor = (descriptors.first as? [String: Any])?["desc"] as? String,
              let open = descriptor.firstIndex(of: "("), let close = descriptor.lastIndex(of: ")")
        else { throw MinerError.wallet("miner wallet has no private descriptor") }
        let wif = String(descriptor[descriptor.index(after: open) ..< close]
            .split(separator: ",").last ?? "")
        let payload = try Base58Check.decode(wif)
        guard payload.count == 34, payload.first == 0xEF, payload.last == 0x01 else {
            throw MinerError.wallet("unexpected WIF payload")
        }
        return payload.dropFirst().dropLast()
    }

    /// CScript-style data push (handles PUSHDATA1 for the ~80-byte section).
    private static func push(_ data: Data) -> Data {
        switch data.count {
        case 0: return Data([0x00])
        case 1 ... 75: return Data([UInt8(data.count)]) + data
        default: return Data([0x4C, UInt8(data.count)]) + data
        }
    }

    /// BIP34 height as a minimally-encoded script number push.
    private static func heightPush(_ height: Int) -> Data {
        var bytes: [UInt8] = []
        var value = height
        while value > 0 { bytes.append(UInt8(value & 0xFF)); value >>= 8 }
        if let last = bytes.last, last & 0x80 != 0 { bytes.append(0) }
        return push(Data(bytes))
    }

    /// Bitcoin merkle root over internal-order hashes (duplicates the last
    /// hash on odd levels).
    private static func merkleRoot(_ hashes: [Data]) -> Data {
        var level = hashes
        while level.count > 1 {
            if level.count % 2 == 1 { level.append(level[level.count - 1]) }
            level = stride(from: 0, to: level.count, by: 2).map { sha256d(level[$0] + level[$0 + 1]) }
        }
        return level[0]
    }

    /// `submitblock` answers for a block the node accepted but did not connect
    /// as the tip — valid, just not on the most-work chain. That is a lost race
    /// against the node's background miner, not a broken block.
    private static let offChainAnswers: Set<String> = ["inconclusive", "duplicate-inconclusive"]

    /// One `key=value` line per mining draw, on stderr. Emitted on the
    /// success path as well as the failure one: a lost race that the retry
    /// then won used to leave no trace at all, so a quiet log said nothing
    /// about whether races were being lost — and a retry bound nobody can
    /// measure is a bound nobody can justify (#28). Every draw prints now, so
    /// `lost=0` means no race was lost and no `signet-miner:` output at all
    /// means this code did not run.
    private static func trace(_ fields: String) {
        FileHandle.standardError.write(Data("signet-miner: \(fields)\n".utf8))
    }

    /// Mines one block paying the subsidy (+fees) to `payoutScript`. Returns
    /// the accepted block hash (display hex) whether or not it became the tip;
    /// callers that need the tip use `mineOntoTip`.
    @discardableResult
    static func mineBlock(payingTo payoutScript: Data) async throws -> String {
        let submission = try await submitMinedBlock(payingTo: payoutScript)
        trace("mineBlock result=\(submission.answer == nil ? "connected" : "offchain")"
            + " answer=\(submission.answer ?? "-")")
        return submission.hash
    }

    /// Mines until one of our blocks is the tip. The dev node's background
    /// miner produces a block every ~10 minutes, so losing a race is expected:
    /// re-mine on the winner rather than failing the test.
    ///
    /// `maxAttempts` bounds one tip win, but the suites need long unbroken
    /// runs of them — 101 in `FullLoopDiffTests`, 102 across the UI e2e — so
    /// at a per-race loss probability `p` a suite survives with probability
    /// `(1 - p^maxAttempts)^101`: ~4% at p = 0.5 on the old bound of 5, and
    /// ~99.98% at 20. Extra attempts cost nothing on runs that lose no race,
    /// which is what makes raising the bound safe *before* the measurement it
    /// is waiting on; size it for real once the traces above give a p (#28).
    @discardableResult
    static func mineOntoTip(payingTo payoutScript: Data,
                            maxAttempts: Int = 20) async throws -> String {
        var lastAnswer = "connected-then-reorged"
        var lost = 0
        for attempt in 0 ..< maxAttempts {
            let submission = try await submitMinedBlock(payingTo: payoutScript)
            if try BitcoinCLI.bestBlockHash() == submission.hash {
                trace("mineOntoTip result=won attempts=\(attempt + 1) max=\(maxAttempts)"
                    + " lost=\(lost) last=\(lost == 0 ? "-" : lastAnswer)")
                return submission.hash
            }
            lost += 1
            if let answer = submission.answer { lastAnswer = answer }
        }
        trace("mineOntoTip result=exhausted attempts=\(maxAttempts) max=\(maxAttempts)"
            + " lost=\(lost) last=\(lastAnswer)")
        throw MinerError.rejected("lost \(maxAttempts) block races (last: \(lastAnswer))")
    }

    /// The mining cycle itself: the block hash plus the node's `submitblock`
    /// answer, which is nil when the block connected as the new tip.
    private static func submitMinedBlock(payingTo payoutScript: Data) async throws
        -> (hash: String, answer: String?)
    {
        let template = try BitcoinCLI.runObject(["getblocktemplate", #"{"rules":["segwit","signet"]}"#])
        let height = try BitcoinCLI.int(template, "height")
        let bitsText = try BitcoinCLI.string(template, "bits")
        let bits = UInt32(bitsText, radix: 16)!
        let time = UInt32(try BitcoinCLI.int(template, "curtime"))
        let version = Int32(bitPattern: UInt32(try BitcoinCLI.int(template, "version")))
        let previousHash = Data(Data(hex: try BitcoinCLI.string(template, "previousblockhash"))!.reversed())
        let coinbaseValue = Int64(try BitcoinCLI.int(template, "coinbasevalue"))
        let reserved = Data(repeating: 0, count: 32)

        let entries = try BitcoinCLI.array(template, "transactions").compactMap { $0 as? [String: Any] }
        let txs = try entries.map { try Transaction.decode(Data(hex: BitcoinCLI.string($0, "data"))!) }
        let txids = try entries.map { Data(Data(hex: try BitcoinCLI.string($0, "txid"))!.reversed()) }
        let wtxids = try entries.map { Data(Data(hex: try BitcoinCLI.string($0, "hash"))!.reversed()) }

        // Coinbase: BIP34 height, witness reserved value, subsidy output and
        // the BIP141 witness commitment (signet section appended post-signing).
        let witnessRoot = merkleRoot([Data(repeating: 0, count: 32)] + wtxids)
        let commitment = Data([0xAA, 0x21, 0xA9, 0xED]) + sha256d(witnessRoot + reserved)
        func makeCoinbase(_ commitmentScript: Data) -> Transaction {
            Transaction(version: 1, inputs: [Transaction.Input(
                previousOutput: Transaction.Outpoint(txid: Data(repeating: 0, count: 32),
                                                     vout: 0xFFFF_FFFF),
                scriptSig: heightPush(height), sequence: 0xFFFF_FFFF, witness: [reserved])],
                outputs: [Transaction.Output(value: coinbaseValue, scriptPubKey: payoutScript),
                          Transaction.Output(value: 0, scriptPubKey: commitmentScript)],
                locktime: 0)
        }
        let unsignedCommitment = Data([0x6A]) + push(commitment)
        // BIP325: the signed-over signet merkle root is computed over the
        // coinbase whose commitment script carries ONLY the 4-byte
        // SIGNET_HEADER push — Core's FetchAndClearCommitmentSection replaces
        // the whole section push with push(header) (erase from
        // begin()+header.size() to end(), then re-push), which is also what
        // the reference miner signs (contrib/signet/miner). Verified
        // empirically against the live default-signet tip.
        let signetHeader = Data([0xEC, 0xC7, 0xDA, 0xA2])
        let coinbase = makeCoinbase(unsignedCommitment + push(signetHeader))

        let signetMerkle = merkleRoot([coinbase.txid] + txids)
        var blockData = Data()
        blockData.appendUInt32LE(UInt32(bitPattern: version))
        blockData.append(previousHash)
        blockData.append(signetMerkle)
        blockData.appendUInt32LE(time)

        // tx_to_spend: version 0, locktime 0, in(prevout null/0xFFFFFFFF,
        // scriptSig = OP_0 push(blockData), seq 0), out(0, challenge).
        var toSpend = Data()
        toSpend.appendUInt32LE(0)
        toSpend.appendVarInt(1)
        toSpend.append(Data(repeating: 0, count: 32))
        toSpend.appendUInt32LE(0xFFFF_FFFF)
        toSpend.appendVarData(Data([0x00]) + push(blockData))
        toSpend.appendUInt32LE(0)
        toSpend.appendVarInt(1)
        toSpend.appendUInt64LE(0)
        toSpend.appendVarData(BitcoinCLI.challenge)
        toSpend.appendUInt32LE(0)
        let toSpendTxid = sha256d(toSpend)

        // Legacy SIGHASH_ALL preimage of tx_spending spending the challenge.
        var preimage = Data()
        preimage.appendUInt32LE(0)
        preimage.appendVarInt(1)
        preimage.append(toSpendTxid)
        preimage.appendUInt32LE(0)
        preimage.appendVarData(BitcoinCLI.challenge)
        preimage.appendUInt32LE(0)
        preimage.appendVarInt(1)
        preimage.appendUInt64LE(0)
        preimage.appendVarData(Data([0x6A])) // OP_RETURN
        preimage.appendUInt32LE(0)
        preimage.appendUInt32LE(1) // SIGHASH_ALL
        let sighash = SHA256.hash(data: Data(SHA256.hash(data: preimage)))

        // The challenge is 1 <pubkey> 1 OP_CHECKMULTISIG — a bare legacy
        // script, so the solution lives in tx_spending's scriptSig (the
        // witness stack is ignored for non-witness scriptPubKeys):
        // OP_0 (CHECKMULTISIG dummy, NULLDUMMY) || push(sig); empty witness.
        let secret = try signingSecret()
        let signature = try P256K.Signing.PrivateKey(dataRepresentation: secret)
            .signature(for: sighash).derRepresentation + Data([0x01])
        let solutionScriptSig = Data([0x00]) + push(signature)
        var section = signetHeader
        section.appendVarData(solutionScriptSig) // tx_spending scriptSig
        section.appendVarInt(0) // tx_spending witness stack (empty)

        let finalCoinbase = makeCoinbase(unsignedCommitment + push(section))
        let merkle = merkleRoot([finalCoinbase.txid] + txids)

        // PoW: grind the nonce with bitcoin-util (multithreaded SHA256 —
        // ~2^22 expected hashes per block at signet difficulty).
        let header = BlockHeader(version: version, previousHash: previousHash,
                                 merkleRoot: merkle, time: time, bits: bits, nonce: 0)
        guard let util = BitcoinCLI.bitcoinUtilPath else {
            throw MinerError.rejected("bitcoin-util not found next to bitcoin-cli")
        }
        let grind = try HostProcess.run(util, ["-signet", "-signetchallenge=\(BitcoinCLI.challengeHex)",
                                               "grind", header.serialized.hex])
        let groundHex = grind.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard grind.status == 0, let groundHeader = Data(hex: groundHex),
              groundHeader.count == BlockHeader.serializedSize
        else { throw MinerError.rejected("bitcoin-util grind failed") }
        let ground = try BlockHeader.decode(groundHeader)

        var block = ground.serialized
        block.appendVarInt(UInt64(txs.count + 1))
        block.append(finalCoinbase.serialized(includeWitness: true))
        for tx in txs { block.append(tx.serialized(includeWitness: true)) }

        let result = try BitcoinCLI.runJSON(["submitblock", block.hex])
        if let answer = result as? String {
            guard offChainAnswers.contains(answer) else { throw MinerError.rejected(answer) }
            return (ground.hash.displayHex, answer)
        }
        return (ground.hash.displayHex, nil)
    }
}

private extension Data {
    /// Little-endian fixed-width appends (BitcoinP2P's are module-internal).
    mutating func appendUInt32LE(_ value: UInt32) {
        Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }

    mutating func appendUInt64LE(_ value: UInt64) {
        Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }

    /// Bitcoin compactSize varint (BitcoinP2P's own is module-internal).
    mutating func appendVarInt(_ value: UInt64) {
        switch value {
        case ..<0xFD:
            append(UInt8(value))
        case ...0xFFFF:
            append(0xFD)
            Swift.withUnsafeBytes(of: UInt16(value).littleEndian) { append(contentsOf: $0) }
        case ...0xFFFF_FFFF:
            append(0xFE)
            Swift.withUnsafeBytes(of: UInt32(value).littleEndian) { append(contentsOf: $0) }
        default:
            append(0xFF)
            Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
        }
    }

    mutating func appendVarData(_ bytes: Data) {
        appendVarInt(UInt64(bytes.count))
        append(bytes)
    }
}
