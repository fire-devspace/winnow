import Foundation

/// Bitcoin P2P network address (`CAddress`): services, 16-byte IP, port.
/// In `version` messages it is serialized without a timestamp; in `addr`
/// messages a 4-byte timestamp precedes it.
public struct PeerAddress: Equatable, Sendable {
    public var time: UInt32?
    public var services: UInt64
    /// 16-byte IPv6 address; IPv4 peers use the ::ffff:a.b.c.d mapping.
    public var ip: Data
    public var port: UInt16

    public init(time: UInt32? = nil, services: UInt64, ip: Data, port: UInt16) {
        precondition(ip.count == 16, "ip must be 16 bytes")
        self.time = time
        self.services = services
        self.ip = ip
        self.port = port
    }

    /// IPv4 convenience: maps to ::ffff:a.b.c.d.
    public init(time: UInt32? = nil, services: UInt64, ipv4: (UInt8, UInt8, UInt8, UInt8), port: UInt16) {
        var ip = Data(repeating: 0, count: 10)
        ip.append(contentsOf: [0xFF, 0xFF, ipv4.0, ipv4.1, ipv4.2, ipv4.3])
        self.init(time: time, services: services, ip: ip, port: port)
    }

    /// Loopback placeholder used for the sender/receiver addresses we announce.
    public static let unspecified = PeerAddress(services: 0, ip: Data(repeating: 0, count: 16), port: 0)

    /// Serialize with or without the leading timestamp (`addr` vs `version`).
    public func serialized(includeTime: Bool) -> Data {
        var data = Data()
        if includeTime { data.appendUInt32(time ?? 0) }
        data.appendUInt64(services)
        data.append(ip)
        data.appendUInt16(port.bigEndian) // port is big-endian on the wire
        return data
    }

    public static func decode(from reader: inout ByteReader, includeTime: Bool) throws -> PeerAddress {
        let time = includeTime ? try reader.readUInt32() : nil
        let services = try reader.readUInt64()
        let ip = try reader.readBytes(16)
        let portBE = try reader.readUInt16()
        return PeerAddress(time: time, services: services, ip: ip, port: portBE.bigEndian)
    }

    /// Human-readable "host:port" (IPv4-mapped addresses shown as IPv4).
    public var endpointDescription: String {
        let host: String
        if ip.prefix(10).allSatisfy({ $0 == 0 }), ip[10] == 0xFF, ip[11] == 0xFF {
            host = "\(ip[12]).\(ip[13]).\(ip[14]).\(ip[15])"
        } else {
            host = "[" + stride(from: 0, to: 16, by: 2).map {
                String(UInt16(ip[$0]) << 8 | UInt16(ip[$0 + 1]), radix: 16)
            }.joined(separator: ":") + "]"
        }
        return "\(host):\(port)"
    }
}
