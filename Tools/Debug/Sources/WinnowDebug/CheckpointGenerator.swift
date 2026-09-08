import WalletCore
import Foundation

/// Regenerates a shipped header checkpoint from a header file this code
/// produced by syncing that network from genesis (#89), run by
/// `scripts/refresh-checkpoint`. `--network` picks which one; there is no
/// second copy of this derivation per network, because a copy is how two
/// networks end up with two different definitions of the same constant.
///
/// The point of the checkpoint is that nobody has to take it on faith. So it is
/// not derived by a separate parser that could agree with the constant while
/// both are wrong — the header file is loaded through `HeaderChain` itself,
/// which proof-of-work-checks every header and rejects a broken chain. What the
/// app would compute is what gets printed.
///
/// Then the acceptance test from #89, in-process: a chain synced from genesis
/// and a chain started from the freshly derived checkpoint must agree on tip
/// hash and total chainwork 2,000 blocks later. Same answer, different starting
/// point. Those 2,000 headers are what `--vector-out` writes, so the always-on
/// `HeaderChainTests` replays the same blocks without the 77 MB file.
enum CheckpointGenerator {
    /// How far past the checkpoint the agreement check connects real headers.
    static let agreementSpan: UInt32 = 2_000
    /// The count field `HeaderChain` writes first in a checkpoint-rooted file,
    /// so the two layouts cannot be confused for one another.
    static let checkpointRootedMarker: UInt32 = 0xFFFF_FFFF

    struct Options {
        let source: URL
        /// Which network's constant is being derived. The header file has to
        /// be that network's: the loader holds a genesis-rooted file's first
        /// header to the genesis these parameters describe, so the wrong file
        /// is refused rather than turned into a plausible wrong constant.
        let network: BitcoinNetwork
        /// nil derives at the shipped height, which checks the constant.
        let height: UInt32?
        let vectorOut: URL?

        init(_ arguments: [String]) throws {
            guard arguments.count > 1, !arguments[1].hasPrefix("-") else {
                throw GenerateError.usage("checkpoint needs the path of a genesis-rooted headers.bin")
            }
            source = URL(fileURLWithPath: (arguments[1] as NSString).expandingTildeInPath)
            network = try WinnowGenerate.network(in: arguments)
            height = try WinnowGenerate.number("--height", in: arguments)
            vectorOut = WinnowGenerate.option("--vector-out", in: arguments).map { URL(fileURLWithPath: $0) }
        }
    }

    static func run(_ options: Options) async throws {
        let params = NetworkParams.params(for: options.network)
        guard let height = options.height ?? params.checkpoint?.height else {
            throw GenerateError.usage("\(options.network.rawValue) ships no checkpoint; pass --height")
        }
        let raw = try Data(contentsOf: options.source)

        // Truncate to the checkpoint height and hand the copy to the real
        // loader. It re-validates linkage and proof of work on every header.
        let temp = FileManager.default.temporaryDirectory
            .appending(path: "winnow-checkpoint-\(options.network.rawValue)-\(height + 1).bin")
        try truncated(raw, toHeaders: height + 1).write(to: temp, options: .atomic)
        defer { try? FileManager.default.removeItem(at: temp) }
        let fromGenesis = try HeaderChain(params: params, storageURL: temp)
        let derived = try await derive(from: fromGenesis, expecting: height)

        // Emit it in source form, so regenerating at a new height is a copy
        // out of the log rather than a hand-assembled constant.
        let tip = await fromGenesis.tip
        print("\n" + literal(height: derived.height, header: tip, work: derived.chainwork) + "\n")
        try compare(derived, shipped: params.checkpoint)

        let next = try await proveAgreement(raw, params: params, fromGenesis: fromGenesis, derived: derived)
        if let vectorOut = options.vectorOut {
            try Data(vectorText(next).utf8).write(to: vectorOut, options: .atomic)
            print("checkpoint: wrote \(next.count) headers past height \(height) to \(vectorOut.path)")
        }
    }

    /// What the app computed for `height`, as the constant it would ship.
    static func derive(from chain: HeaderChain, expecting height: UInt32) async throws -> NetworkParams.Checkpoint {
        let start = await chain.startHeight
        let loaded = await chain.height
        guard start == 0, loaded == height else {
            throw GenerateError.badSource("loaded a chain from \(start) to \(loaded), wanted 0 to \(height)")
        }
        return NetworkParams.Checkpoint(height: loaded, header: await chain.tip.serialized,
                                        chainwork: await chain.tipWork)
    }

    /// At the shipped height the constant must be what the genesis-validated
    /// chain computes, which was the original point of the generator. At any
    /// other height the derived value is the candidate replacement.
    static func compare(_ derived: NetworkParams.Checkpoint, shipped: NetworkParams.Checkpoint?) throws {
        guard let shipped, shipped.height == derived.height else {
            let shippedHeight = shipped.map { String($0.height) } ?? "none"
            print("checkpoint: derived at height \(derived.height); the shipped constant is at \(shippedHeight)")
            return
        }
        guard shipped == derived else {
            throw GenerateError.divergence(
                "the shipped checkpoint at height \(shipped.height) is not what a genesis-validated chain computes")
        }
        print("checkpoint: the shipped constant at height \(shipped.height) is what a genesis-validated chain computes")
    }

    /// The acceptance test from #89: after connecting the same real headers,
    /// the genesis-rooted chain and a chain started from the derived
    /// checkpoint must reach the same tip with the same total work — the
    /// checkpoint start is not a different chain, just a later entrance.
    static func proveAgreement(_ raw: Data, params: NetworkParams, fromGenesis: HeaderChain,
                               derived: NetworkParams.Checkpoint) async throws -> [BlockHeader] {
        let target = derived.height + agreementSpan
        let next = try headers(in: raw, from: derived.height + 1, throughInclusive: target)
        // No stored file at all, so it starts from the derived constant.
        let fromCheckpoint = try HeaderChain(params: parameters(params, with: derived),
                                             storageURL: nil, start: .checkpoint)
        // They already agree at the checkpoint itself.
        try await requireAgreement(fromGenesis, fromCheckpoint, at: [derived.height])

        let appendedFromGenesis = try await fromGenesis.connect(next).appended
        let appendedFromCheckpoint = try await fromCheckpoint.connect(next).appended
        guard appendedFromGenesis == next.count, appendedFromCheckpoint == next.count else {
            throw GenerateError.divergence("connected \(appendedFromGenesis) and \(appendedFromCheckpoint) "
                                           + "of \(next.count) headers past the checkpoint")
        }
        // And after doing real work on top, which is the claim that matters.
        try await requireAgreement(fromGenesis, fromCheckpoint,
                                   at: [derived.height, derived.height + 1, target - 1, target])
        let work = await fromGenesis.tipWork
        print("checkpoint: genesis-rooted and checkpoint-rooted chains agree through height \(target), "
              + "work \(work.hex)")
        return next
    }

    /// Tip, work and height must match, and heights must mean the same thing
    /// in both — not merely end up equal.
    static func requireAgreement(_ fromGenesis: HeaderChain, _ fromCheckpoint: HeaderChain,
                                 at heights: [UInt32]) async throws {
        let genesisHeight = await fromGenesis.height
        let checkpointHeight = await fromCheckpoint.height
        guard genesisHeight == checkpointHeight else {
            throw GenerateError.divergence(
                "heights differ: \(genesisHeight) from genesis, \(checkpointHeight) from the checkpoint")
        }
        let genesisTip = await fromGenesis.tipHash
        let checkpointTip = await fromCheckpoint.tipHash
        guard genesisTip == checkpointTip else {
            throw GenerateError.divergence("tip hashes differ at height \(genesisHeight)")
        }
        let genesisWork = await fromGenesis.tipWork
        let checkpointWork = await fromCheckpoint.tipWork
        guard genesisWork == checkpointWork else {
            throw GenerateError.divergence("cumulative work diverged at height \(genesisHeight) — the chainwork is wrong")
        }
        for wanted in heights {
            let genesisHash = await fromGenesis.blockHash(at: wanted)
            let checkpointHash = await fromCheckpoint.blockHash(at: wanted)
            guard genesisHash == checkpointHash else {
                throw GenerateError.divergence("block hashes differ at height \(wanted)")
            }
        }
    }

    // MARK: - Pure parts

    /// The network's parameters with the derived checkpoint in place of the
    /// shipped one, so the checkpoint-rooted chain starts from what was just
    /// computed rather than from the constant under test.
    static func parameters(_ base: NetworkParams, with checkpoint: NetworkParams.Checkpoint) -> NetworkParams {
        NetworkParams(network: base.network, magic: base.magic, defaultPort: base.defaultPort,
                      genesisTime: base.genesisTime, genesisBits: base.genesisBits,
                      genesisNonce: base.genesisNonce, genesisMerkleRoot: base.genesisMerkleRoot,
                      genesisHash: base.genesisHash, powLimit: base.powLimit, dnsSeeds: base.dnsSeeds,
                      fallbackPeers: base.fallbackPeers, checkpoint: checkpoint)
    }

    /// The first `wanted` headers of a genesis-rooted file, in the same
    /// layout: count || count × 80 bytes. A checkpoint-rooted file cannot be
    /// a source here — it would be assuming what we are deriving.
    static func truncated(_ raw: Data, toHeaders wanted: UInt32) throws -> Data {
        var reader = ByteReader(raw)
        let count = try reader.readUInt32()
        guard count != checkpointRootedMarker else {
            throw GenerateError.badSource("the file is checkpoint-rooted; the checkpoint must come from a genesis sync")
        }
        guard count >= wanted else {
            throw GenerateError.badSource("the file holds \(count) headers, need \(wanted)")
        }
        let end = 4 + Int(wanted) * BlockHeader.serializedSize
        guard raw.count >= end else {
            throw GenerateError.badSource("the file is shorter than its count of \(count) headers")
        }
        var out = Data()
        out.appendLittleEndian(wanted)
        out.append(raw[raw.startIndex + 4 ..< raw.startIndex + end])
        return out
    }

    /// Headers `from` through `throughInclusive` by height, straight out of
    /// the genesis-rooted file. Nothing is validated here; the chains do that.
    static func headers(in raw: Data, from: UInt32, throughInclusive: UInt32) throws -> [BlockHeader] {
        let size = BlockHeader.serializedSize
        guard from <= throughInclusive, raw.count >= 4 + (Int(throughInclusive) + 1) * size else {
            throw GenerateError.badSource("no headers \(from) through \(throughInclusive) in the file")
        }
        return try (from ... throughInclusive).map { height in
            let start = raw.startIndex + 4 + Int(height) * size
            return try BlockHeader.decode(raw[start ..< start + size])
        }
    }

    /// The constant in source form, spelled and broken across lines exactly
    /// as `NetworkParams.swift` holds it, so the paste is a pure replacement.
    static func literal(height: UInt32, header: BlockHeader, work: Data) -> String {
        let bytes = header.serialized.hex
        return """
        // Block \(grouped(height, separator: ",")) hash, display order:
        //   \(header.hash.displayHex)
        checkpoint: Checkpoint(
            height: \(grouped(height, separator: "_")),
            header: Data(hex:
                "\(bytes.prefix(72))"
                + "\(bytes.dropFirst(72).prefix(64))"
                + "\(bytes.dropFirst(136))")!,
            chainwork: Data(hex:
                "\(work.hex)")!
        )
        """
    }

    /// Digits in threes, the way the source spells its heights.
    static func grouped(_ value: UInt32, separator: String) -> String {
        let digits = Array(String(value))
        return digits.enumerated().map { offset, digit in
            let remaining = digits.count - offset
            return (offset > 0 && remaining % 3 == 0 ? separator : "") + String(digit)
        }.joined()
    }

    /// One 80-byte header per line as 160 lowercase hex characters, the
    /// shape `HeaderChainTests` reads back.
    static func vectorText(_ headers: [BlockHeader]) -> String {
        headers.map { $0.serialized.hex + "\n" }.joined()
    }
}

extension Data {
    /// `Data.appendUInt32` is internal to BitcoinP2P; the count prefix of the
    /// genesis-rooted header file is the one little-endian field this writes.
    mutating func appendLittleEndian(_ value: UInt32) {
        Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }
}
