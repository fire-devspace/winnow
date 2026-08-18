import Foundation

public enum HeaderChainError: LocalizedError, Equatable {
    case doesNotConnect
    case invalidTarget(height: UInt32)
    case targetAbovePowLimit(height: UInt32)
    case insufficientProofOfWork(height: UInt32)
    case reorgWithoutMoreWork
    case storageCorrupt(String)
    case storageUnavailable(String)
    case badPeerResponse(String)

    public var errorDescription: String? {
        switch self {
        case .doesNotConnect:
            "A peer sent block headers that do not connect to the known Bitcoin chain."
        case let .invalidTarget(height):
            "A peer sent an invalid proof-of-work target at block \(height)."
        case let .targetAbovePowLimit(height):
            "A peer sent an impossibly easy proof-of-work target at block \(height)."
        case let .insufficientProofOfWork(height):
            "A peer sent a header without enough proof of work at block \(height)."
        case .reorgWithoutMoreWork:
            "A peer offered an older or weaker Bitcoin chain."
        case let .storageCorrupt(reason):
            "The saved block-header data is damaged (\(reason))."
        case let .storageUnavailable(reason):
            "Winnow could not read or save its local block-header data (\(reason))."
        case let .badPeerResponse(reason):
            "A peer returned an invalid block-header response (\(reason))."
        }
    }
}

/// Headers-only view of the best proof-of-work chain, synced with `getheaders`.
///
/// What is validated per header (deliberately minimal, light-client scope):
/// - previous-hash linkage to the known chain,
/// - compact bits decodes to a valid target ≤ consensus powLimit,
/// - SHA256d(header) ≤ target (proof of work).
///
/// What is NOT validated (documented deviation from full validation):
/// - the difficulty *retarget schedule* (claimed bits are accepted as long as
///   each header individually satisfies its claimed target),
/// - timestamps (no median-time-past / future-drift rules),
/// - anything below the header (merkle root, signet block signatures).
/// Fork choice is cumulative-work; competing branches replace ours only with
/// strictly more work.
public actor HeaderChain {
    public static let maxHeadersPerRequest = 2_000

    public let params: NetworkParams
    private let storageURL: URL?

    /// Main chain, index = height. Element 0 is the genesis header.
    private var headers: [BlockHeader]
    /// Cumulative work, aligned with `headers`.
    private var chainwork: [UInt256]
    private var heightByHash: [Data: UInt32]

    public init(params: NetworkParams, storageURL: URL? = nil) throws {
        self.params = params
        self.storageURL = storageURL
        let genesis = HeaderChain.genesisHeader(for: params)
        headers = [genesis]
        chainwork = [UInt256()]
        heightByHash = [genesis.hash: 0]
        if let storageURL, FileManager.default.fileExists(atPath: storageURL.path) {
            do {
                (headers, chainwork, heightByHash) = try Self.load(from: storageURL, params: params)
            } catch let error as HeaderChainError {
                throw error
            } catch {
                throw HeaderChainError.storageUnavailable(
                    "could not read the header file: \(error.localizedDescription)")
            }
        } else {
            // Seed cumulative work for genesis.
            chainwork = [try Self.checkedWork(for: genesis, params: params, height: 0)]
        }
    }

    /// Genesis header reconstructed from the network parameters.
    public static func genesisHeader(for params: NetworkParams) -> BlockHeader {
        BlockHeader(version: 1, previousHash: Data(repeating: 0, count: 32),
                    merkleRoot: params.genesisMerkleRoot, time: params.genesisTime,
                    bits: params.genesisBits, nonce: params.genesisNonce)
    }

    public var tip: BlockHeader { headers[headers.count - 1] }
    public var tipHash: Data { tip.hash }
    public var height: UInt32 { UInt32(headers.count - 1) }

    /// Cumulative chainwork at the tip, big-endian (display) byte order.
    public var tipWork: Data { chainwork[chainwork.count - 1].bigEndianData }

    public func header(at height: UInt32) -> BlockHeader? {
        height < headers.count ? headers[Int(height)] : nil
    }

    public func blockHash(at height: UInt32) -> Data? {
        header(at: height)?.hash
    }

    /// Standard getheaders locator: the last 10 heights step 1, then
    /// exponentially larger steps back, always ending at genesis.
    public func blockLocator() -> [Data] {
        var locator: [Data] = []
        var step = 1
        var index = headers.count - 1
        while index > 0 {
            locator.append(headers[index].hash)
            if locator.count >= 10 { step *= 2 }
            index = max(index - step, 0)
        }
        locator.append(headers[0].hash)
        return locator
    }

    /// Validates PoW for one header. Returns the block's work contribution.
    static func checkedWork(for header: BlockHeader, params: NetworkParams, height: UInt32) throws -> UInt256 {
        let (target, work) = try targetAndWork(bits: header.bits, params: params, height: height)
        let hashAsNumber = UInt256(littleEndian: header.hash)
        guard hashAsNumber <= target else { throw HeaderChainError.insufficientProofOfWork(height: height) }
        return work
    }

    /// Target decoding and block-work division depend only on `bits`. Header
    /// files commonly repeat the same difficulty for long stretches, so load
    /// can cache this expensive result while still hashing and PoW-checking
    /// every individual header.
    private static func targetAndWork(bits: UInt32, params: NetworkParams,
                                      height: UInt32) throws -> (UInt256, UInt256) {
        guard let target = UInt256.target(compact: bits) else {
            throw HeaderChainError.invalidTarget(height: height)
        }
        let powLimit = UInt256(littleEndian: params.powLimit)
        guard target <= powLimit else { throw HeaderChainError.targetAbovePowLimit(height: height) }
        guard let work = UInt256.blockWork(target: target) else {
            throw HeaderChainError.invalidTarget(height: height)
        }
        return (target, work)
    }

    /// Connects a batch of headers received from a peer. The first header must
    /// build on a block already in the chain (usually the tip; an earlier
    /// height means a reorg, accepted only with strictly more total work).
    /// Returns the number of headers appended.
    @discardableResult
    public func connect(_ newHeaders: [BlockHeader]) throws -> Int {
        guard !newHeaders.isEmpty else { return 0 }
        guard let forkHeight = heightByHash[newHeaders[0].previousHash] else {
            throw HeaderChainError.doesNotConnect
        }

        var stagedHeaders = Array(headers[...Int(forkHeight)])
        var stagedWork = Array(chainwork[...Int(forkHeight)])
        for header in newHeaders {
            let height = UInt32(stagedHeaders.count)
            guard header.previousHash == stagedHeaders[stagedHeaders.count - 1].hash else {
                throw HeaderChainError.doesNotConnect
            }
            let work = try Self.checkedWork(for: header, params: params, height: height)
            stagedHeaders.append(header)
            stagedWork.append(stagedWork[stagedWork.count - 1] + work)
        }

        // A shorter replacement branch must carry strictly more work.
        if Int(forkHeight) < headers.count - 1,
           stagedWork[stagedWork.count - 1] <= chainwork[chainwork.count - 1] {
            throw HeaderChainError.reorgWithoutMoreWork
        }

        headers = stagedHeaders
        chainwork = stagedWork
        heightByHash = heightByHash.filter { $0.value <= forkHeight }
        for (index, header) in headers.enumerated() where heightByHash[header.hash] == nil {
            heightByHash[header.hash] = UInt32(index)
        }
        try persist()
        return newHeaders.count
    }

    /// Syncs from the current tip to the peer's best tip via getheaders.
    public func sync(using peer: PeerConnection, timeout: Duration = .seconds(30)) async throws {
        while true {
            let request = GetHeadersMessage(version: PeerConnection.protocolVersion,
                                            locatorHashes: blockLocator())
            let message = try await peer.request(.getheaders(request),
                                                 expecting: ["headers"],
                                                 timeout: timeout)
            guard case let .headers(batch) = message else {
                throw HeaderChainError.badPeerResponse("expected headers")
            }
            if batch.isEmpty { return }
            try connect(batch)
            if batch.count < Self.maxHeadersPerRequest { return }
        }
    }

    // MARK: - Persistence

    /// File format: uint32 LE header count, then raw 80-byte headers in height
    /// order. Rewritten atomically on every successful connect — fine for a
    /// fresh-wallet client whose chains are short.
    private func persist() throws {
        guard let storageURL else { return }
        var data = Data()
        data.appendUInt32(UInt32(headers.count))
        for header in headers { data.append(header.serialized) }
        // .atomic writes to a temp file then renames — safe mid-write crash.
        do {
            try data.write(to: storageURL, options: .atomic)
        } catch {
            throw HeaderChainError.storageUnavailable(
                "could not save the header file: \(error.localizedDescription)")
        }
    }

    private static func load(from url: URL, params: NetworkParams) throws
        -> (headers: [BlockHeader], chainwork: [UInt256], heightByHash: [Data: UInt32]) {
        let data = try Data(contentsOf: url)
        var reader = ByteReader(data)
        guard let count = try? reader.readUInt32(), data.count == 4 + Int(count) * BlockHeader.serializedSize else {
            throw HeaderChainError.storageCorrupt("bad length")
        }
        let genesis = HeaderChain.genesisHeader(for: params)
        var loadedHeaders: [BlockHeader] = []
        var loadedWork: [UInt256] = []
        var work = UInt256()
        var workByBits: [UInt32: (target: UInt256, work: UInt256)] = [:]
        for index in 0 ..< count {
            guard let header = try? BlockHeader.decode(from: &reader) else {
                throw HeaderChainError.storageCorrupt("bad header at \(index)")
            }
            let parameters: (target: UInt256, work: UInt256)
            if let cached = workByBits[header.bits] {
                parameters = cached
            } else {
                parameters = try targetAndWork(bits: header.bits, params: params, height: index)
                workByBits[header.bits] = parameters
            }
            // Caching block-work must never cache header validity: every hash
            // remains independently checked against the repeated target.
            let hashAsNumber = UInt256(littleEndian: header.hash)
            guard hashAsNumber <= parameters.target else {
                throw HeaderChainError.insufficientProofOfWork(height: index)
            }
            work = work + parameters.work
            if index == 0, header != genesis { throw HeaderChainError.storageCorrupt("genesis mismatch") }
            if index > 0, header.previousHash != loadedHeaders[loadedHeaders.count - 1].hash {
                throw HeaderChainError.storageCorrupt("broken linkage at \(index)")
            }
            loadedHeaders.append(header)
            loadedWork.append(work)
        }
        let index = Dictionary(uniqueKeysWithValues: loadedHeaders.enumerated().map { ($1.hash, UInt32($0)) })
        return (loadedHeaders, loadedWork, index)
    }
}
