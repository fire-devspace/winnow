import Foundation

public enum TweakIndexError: Error, Equatable {
    case httpStatus(Int, String)
    case invalidResponse(String)
}

/// Minimal BIP352 tweak-index REST client — STRICTLY OPT-IN, same rules as
/// EsploraClient: inert until instantiated, contacted only on the explicit,
/// warned, user-initiated silent-payment path.
///
/// Format: `GET {base}/tweaks/{height}` → JSON array of hex strings, each a
/// 33-byte compressed point (input_hash·A per eligible transaction, BIP352
/// Appendix A). This is the shape Winnow's own signet index serves; other
/// index servers (e.g. BlindBit-style) are adapted behind the same endpoint.
///
/// Privacy: queries are by block height only, never by key or script — the
/// operator learns that this IP follows silent-payment data, not which
/// outputs are the wallet's. Matching stays on-device.
public struct TweakIndexHTTPClient: Sendable {
    public let baseURL: URL
    private let session: URLSession

    public init(baseURL: URL, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.session = session
    }

    /// GET /tweaks/{height} — the block's tweak-data points.
    public func tweaks(forBlockAt height: UInt32) async throws -> [Data] {
        let url = baseURL.appending(path: "tweaks/\(height)")
        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse else {
            throw TweakIndexError.invalidResponse("not http")
        }
        guard (200 ..< 300).contains(http.statusCode) else {
            throw TweakIndexError.httpStatus(http.statusCode, String(decoding: data, as: UTF8.self))
        }
        let entries: [String]
        do {
            entries = try JSONDecoder().decode([String].self, from: data)
        } catch {
            throw TweakIndexError.invalidResponse("decoding tweaks: \(error.localizedDescription)")
        }
        return try entries.map { entry in
            guard let tweak = Self.data(hex: entry), tweak.count == 33 else {
                throw TweakIndexError.invalidResponse("tweak entry \(entry.prefix(70))")
            }
            return tweak
        }
    }

    /// Local hex decoding — BlockchainBackend deliberately does not depend on
    /// BitcoinP2P, where the shared Data(hex:) lives.
    private static func data(hex: String) -> Data? {
        guard hex.count % 2 == 0, !hex.isEmpty else { return nil }
        var bytes = Data(capacity: hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index ..< next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        return bytes
    }
}
