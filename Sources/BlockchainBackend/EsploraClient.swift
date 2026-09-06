import Foundation

public enum EsploraError: Error, Equatable {
    case httpStatus(Int, String)
    case invalidResponse(String)
}

/// Minimal esplora REST client — STRICTLY OPT-IN (docs/read-side.md §2.2).
///
/// The default read path is P2P compact filters; this client exists only for
/// the explicit, warned, user-initiated fast path. It is inert until
/// instantiated with a base URL; nothing here is contacted otherwise. The
/// privacy trade (the operator learns the queried address set, balances,
/// counterparties and the client IP) is the app's responsibility to surface.
public struct EsploraClient: Sendable {
    /// Well-known public instances, provided as conveniences only. Passing one
    /// of these is itself the opt-in.
    public static let mempoolSpaceMainnet = URL(string: "https://mempool.space/api")!
    public static let mempoolSpaceSignet = URL(string: "https://mempool.space/signet/api")!
    public static let blockstreamMainnet = URL(string: "https://blockstream.info/api")!

    public let baseURL: URL
    private let session: URLSession

    public init(baseURL: URL, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.session = session
    }

    /// GET /blocks/tip/height
    public func tipHeight() async throws -> Int {
        let (data, _) = try await get("blocks/tip/height")
        guard let height = Int(String(decoding: data, as: UTF8.self)) else {
            throw EsploraError.invalidResponse("tip height")
        }
        return height
    }

    /// GET /address/{address}/utxo
    public func utxos(address: String) async throws -> [EsploraUTXO] {
        let (data, _) = try await get("address/\(address)/utxo")
        return try decode([EsploraUTXO].self, from: data)
    }

    /// GET /address/{address}/txs (confirmed transactions, newest first)
    public func transactions(address: String) async throws -> [EsploraTransaction] {
        let (data, _) = try await get("address/\(address)/txs")
        return try decode([EsploraTransaction].self, from: data)
    }

    /// GET /fee-estimates — confirmation target (blocks) → sat/vB.
    public func feeEstimates() async throws -> [Int: Double] {
        let (data, _) = try await get("fee-estimates")
        let raw = try decode([String: Double].self, from: data)
        var estimates: [Int: Double] = [:]
        for (target, feeRate) in raw {
            if let blocks = Int(target) { estimates[blocks] = feeRate }
        }
        return estimates
    }

    /// POST /tx — broadcasts a raw transaction, returns its txid.
    @discardableResult
    public func broadcast(_ rawTx: Data) async throws -> String {
        var request = URLRequest(url: baseURL.appending(path: "tx"))
        request.httpMethod = "POST"
        request.setValue("text/plain", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(rawTx.map { String(format: "%02x", $0) }.joined().utf8)
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard (200 ..< 300).contains(status) else {
            throw EsploraError.httpStatus(status, String(decoding: data, as: UTF8.self))
        }
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: - Internals

    private func get(_ path: String) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(from: baseURL.appending(path: path))
        guard let http = response as? HTTPURLResponse else {
            throw EsploraError.invalidResponse("not http")
        }
        guard (200 ..< 300).contains(http.statusCode) else {
            throw EsploraError.httpStatus(http.statusCode, String(decoding: data, as: UTF8.self))
        }
        return (data, http)
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        do {
            return try decoder.decode(type, from: data)
        } catch {
            throw EsploraError.invalidResponse("decoding \(T.self): \(error.localizedDescription)")
        }
    }
}

/// Entry of /address/{a}/utxo.
public struct EsploraUTXO: Codable, Equatable, Sendable {
    public var txid: String
    public var vout: Int
    public var value: UInt64
    public var status: EsploraStatus

    public init(txid: String, vout: Int, value: UInt64, status: EsploraStatus) {
        self.txid = txid
        self.vout = vout
        self.value = value
        self.status = status
    }
}

public struct EsploraStatus: Codable, Equatable, Sendable {
    public var confirmed: Bool
    public var blockHeight: Int?
    public var blockHash: String?
    public var blockTime: Int?

    public init(confirmed: Bool, blockHeight: Int? = nil, blockHash: String? = nil, blockTime: Int? = nil) {
        self.confirmed = confirmed
        self.blockHeight = blockHeight
        self.blockHash = blockHash
        self.blockTime = blockTime
    }
}

/// Transaction as returned by /address/{a}/txs (display JSON, display-order
/// hex hashes — this is the server-described view, never trusted blindly).
public struct EsploraTransaction: Codable, Equatable, Sendable {
    public struct Input: Codable, Equatable, Sendable {
        public var txid: String
        public var vout: Int
        public var prevout: Output?
        public var scriptsig: String?
        public var witness: [String]?
    }

    public struct Output: Codable, Equatable, Sendable {
        public var scriptpubkey: String
        public var scriptpubkeyAddress: String?
        public var value: UInt64?
    }

    public var txid: String
    public var version: Int
    public var locktime: Int
    public var size: Int
    public var weight: Int
    public var fee: UInt64
    public var vin: [Input]
    public var vout: [Output]
    public var status: EsploraStatus
}
