import Foundation

/// Cloudflare's DNS-over-HTTPS JSON endpoint, addressed by IP so finding
/// the resolver does not itself go through unauthenticated system DNS.
public let defaultDoHEndpoint = URL(string: "https://1.1.1.1/dns-query")!

/// RR types we ask for. dns-json uses the IANA numbers.
private let dnsTypeA = 1
private let dnsTypeAAAA = 28

/// Parse + filter + resolve Bitcoin DNS seeds.
///
/// Default path: HTTPS dns-json to a configurable DoH endpoint (Cloudflare
/// 1.1.1.1). If that yields no acceptable addresses, fall back to
/// `getaddrinfo` so a DoH outage does not empty the seed list. Both paths
/// drop RFC1918 / loopback / link-local answers on public networks so a
/// poisoned resolver cannot steer the pool onto attacker LAN hosts.
/// Custom signets keep those answers (dev nodes on loopback or RFC1918).
public struct SeedResolver: Sendable {
    /// Fetches one dns-json body for `name` + `type` (`"A"` / `"AAAA"`).
    public typealias JSONFetch = @Sendable (_ name: String, _ type: String) async throws -> Data
    /// System resolver (getaddrinfo).
    public typealias SystemResolve = @Sendable (_ host: String, _ port: UInt16) -> [PeerEndpoint]
    /// Full lookup override used by tests to stub the whole seed step.
    public typealias Lookup = @Sendable (_ host: String, _ port: UInt16, _ allowPrivate: Bool) async -> [PeerEndpoint]

    public var lookup: Lookup

    public init(lookup: @escaping Lookup) {
        self.lookup = lookup
    }

    public static func live(
        endpoint: URL = defaultDoHEndpoint,
        session: URLSession = .shared,
        fetchJSON: JSONFetch? = nil,
        systemResolve: @escaping SystemResolve = SeedResolver.getaddrinfo
    ) -> SeedResolver {
        let fetch = fetchJSON ?? { name, type in
            try await Self.dohGET(endpoint: endpoint, session: session, name: name, type: type)
        }
        return SeedResolver { host, port, allowPrivate in
            await Self.resolve(
                host: host, port: port, allowPrivate: allowPrivate,
                fetchJSON: fetch, systemResolve: systemResolve
            )
        }
    }

    public func resolve(host: String, port: UInt16, allowPrivate: Bool) async -> [PeerEndpoint] {
        await lookup(host, port, allowPrivate)
    }

    /// Resolve every seed (shuffled, in parallel) and flatten, de-duplicating.
    public func resolveSeeds(_ seeds: [String], port: UInt16, allowPrivate: Bool) async -> [PeerEndpoint] {
        guard !seeds.isEmpty else { return [] }
        var collected: [PeerEndpoint] = []
        await withTaskGroup(of: [PeerEndpoint].self) { group in
            for seed in seeds.shuffled() {
                group.addTask { await self.resolve(host: seed, port: port, allowPrivate: allowPrivate) }
            }
            for await batch in group {
                collected.append(contentsOf: batch)
            }
        }
        var seen = Set<PeerEndpoint>()
        return collected.filter { seen.insert($0).inserted }
    }

    // MARK: - Live lookup

    static func resolve(
        host: String, port: UInt16, allowPrivate: Bool,
        fetchJSON: @escaping JSONFetch, systemResolve: SystemResolve
    ) async -> [PeerEndpoint] {
        let fromDoH = await dohHosts(name: host, fetchJSON: fetchJSON)
        let doh = endpoints(hosts: fromDoH, port: port, allowPrivate: allowPrivate)
        if !doh.isEmpty { return doh }
        let system = systemResolve(host, port).map(\.host)
        return endpoints(hosts: system, port: port, allowPrivate: allowPrivate)
    }

    static func dohHosts(name: String, fetchJSON: @escaping JSONFetch) async -> [String] {
        var hosts: [String] = []
        await withTaskGroup(of: [String].self) { group in
            for type in ["A", "AAAA"] {
                group.addTask {
                    guard let data = try? await fetchJSON(name, type) else { return [] }
                    return (try? DNSJSON.hosts(from: data)) ?? []
                }
            }
            for await batch in group { hosts.append(contentsOf: batch) }
        }
        return hosts
    }

    static func endpoints(hosts: [String], port: UInt16, allowPrivate: Bool) -> [PeerEndpoint] {
        var seen = Set<String>()
        var result: [PeerEndpoint] = []
        for host in hosts {
            guard seen.insert(host).inserted else { continue }
            guard SeedAddressFilter.accepts(host, allowPrivate: allowPrivate) else { continue }
            result.append(PeerEndpoint(host: host, port: port))
        }
        return result
    }

    static func dohGET(endpoint: URL, session: URLSession, name: String, type: String) async throws -> Data {
        var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "name", value: name),
            URLQueryItem(name: "type", value: type),
        ]
        guard let url = components?.url else { throw URLError(.badURL) }
        var request = URLRequest(url: url)
        request.setValue("application/dns-json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 5
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard (200 ..< 300).contains(status) else {
            throw URLError(.badServerResponse)
        }
        return data
    }

    /// Resolves a hostname via getaddrinfo (system DNS). Public so tests can
    /// exercise the fallback without going through DoH.
    public static func getaddrinfo(host: String, port: UInt16) -> [PeerEndpoint] {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        var result: UnsafeMutablePointer<addrinfo>?
        guard Darwin.getaddrinfo(host, nil, &hints, &result) == 0, let first = result else { return [] }
        defer { freeaddrinfo(first) }
        var endpoints: [PeerEndpoint] = []
        var current: UnsafeMutablePointer<addrinfo>? = first
        while let info = current {
            defer { current = info.pointee.ai_next }
            guard info.pointee.ai_family == AF_INET || info.pointee.ai_family == AF_INET6 else { continue }
            var hostBuffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let status = getnameinfo(info.pointee.ai_addr, info.pointee.ai_addrlen,
                                     &hostBuffer, socklen_t(hostBuffer.count), nil, 0, NI_NUMERICHOST)
            guard status == 0 else { continue }
            let bytes = hostBuffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
            endpoints.append(PeerEndpoint(host: String(decoding: bytes, as: UTF8.self), port: port))
        }
        return endpoints
    }
}

/// Cloudflare / Google / RFC 8427 dns-json body.
public enum DNSJSON {
    struct Body: Decodable {
        var Status: Int
        var Answer: [Answer]?
        struct Answer: Decodable {
            var type: Int
            var data: String
        }
    }

    /// Host strings from A (1) and AAAA (28) answers. Other RR types
    /// (CNAME, etc.) are ignored. Non-zero `Status` yields an empty list.
    public static func hosts(from data: Data) throws -> [String] {
        let body = try JSONDecoder().decode(Body.self, from: data)
        guard body.Status == 0 else { return [] }
        return (body.Answer ?? []).compactMap { answer in
            guard answer.type == dnsTypeA || answer.type == dnsTypeAAAA else { return nil }
            let host = answer.data.trimmingCharacters(in: .whitespacesAndNewlines)
            return host.isEmpty ? nil : host
        }
    }
}

/// RFC1918 / loopback / link-local filter for seed answers.
public enum SeedAddressFilter {
    /// `allowPrivate` keeps RFC1918/loopback/link-local (custom signets).
    /// Hostnames that are not IP literals are always rejected.
    public static func accepts(_ host: String, allowPrivate: Bool) -> Bool {
        if let v4 = ipv4Octets(host) {
            return allowPrivate || isPublicIPv4(v4)
        }
        if let v6 = ipv6Octets(host) {
            if isIPv4Mapped(v6) {
                let v4 = (v6[12], v6[13], v6[14], v6[15])
                return allowPrivate || isPublicIPv4(v4)
            }
            return allowPrivate || isPublicIPv6(v6)
        }
        return false
    }

    static func ipv4Octets(_ host: String) -> (UInt8, UInt8, UInt8, UInt8)? {
        var bytes = [UInt8](repeating: 0, count: 4)
        let ok = host.withCString { inet_pton(AF_INET, $0, &bytes) == 1 }
        guard ok else { return nil }
        return (bytes[0], bytes[1], bytes[2], bytes[3])
    }

    static func ipv6Octets(_ host: String) -> [UInt8]? {
        var bytes = [UInt8](repeating: 0, count: 16)
        let ok = host.withCString { inet_pton(AF_INET6, $0, &bytes) == 1 }
        return ok ? bytes : nil
    }

    static func isIPv4Mapped(_ bytes: [UInt8]) -> Bool {
        bytes.count == 16
            && bytes.prefix(10).allSatisfy({ $0 == 0 })
            && bytes[10] == 0xFF && bytes[11] == 0xFF
    }

    static func isPublicIPv4(_ o: (UInt8, UInt8, UInt8, UInt8)) -> Bool {
        if o.0 == 0 { return false }                       // 0.0.0.0/8
        if o.0 == 10 { return false }                      // 10.0.0.0/8
        if o.0 == 127 { return false }                     // 127.0.0.0/8
        if o.0 == 169 && o.1 == 254 { return false }       // 169.254.0.0/16
        if o.0 == 172 && (o.1 & 0xF0) == 16 { return false } // 172.16.0.0/12
        if o.0 == 192 && o.1 == 168 { return false }       // 192.168.0.0/16
        if o.0 >= 224 { return false }                     // multicast / reserved
        return true
    }

    static func isPublicIPv6(_ bytes: [UInt8]) -> Bool {
        if bytes.allSatisfy({ $0 == 0 }) { return false }                  // ::
        if bytes.prefix(15).allSatisfy({ $0 == 0 }) && bytes[15] == 1 {    // ::1
            return false
        }
        if bytes[0] & 0xFE == 0xFC { return false }                        // fc00::/7
        if bytes[0] == 0xFE && bytes[1] & 0xC0 == 0x80 { return false }    // fe80::/10
        if bytes[0] == 0xFF { return false }                               // ff00::/8
        return true
    }
}
