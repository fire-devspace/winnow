import Foundation

/// Little-endian / compactSize appenders for Bitcoin serializations. Kept
/// module-internal, mirroring BitcoinP2P's Wire.swift helpers (which are not
/// public); reading goes through BitcoinP2P's public `ByteReader`.
extension Data {
    mutating func appendUInt8(_ value: UInt8) { append(value) }

    mutating func appendUInt32(_ value: UInt32) {
        Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }

    mutating func appendUInt64(_ value: UInt64) {
        Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }

    mutating func appendInt32(_ value: Int32) { appendUInt32(UInt32(bitPattern: value)) }
    mutating func appendInt64(_ value: Int64) { appendUInt64(UInt64(bitPattern: value)) }

    mutating func appendCompactSize(_ value: UInt64) {
        switch value {
        case ..<0xFD:
            append(UInt8(value))
        case ...0xFFFF:
            append(0xFD)
            Swift.withUnsafeBytes(of: UInt16(value).littleEndian) { append(contentsOf: $0) }
        case ...0xFFFF_FFFF:
            append(0xFE)
            appendUInt32(UInt32(value))
        default:
            append(0xFF)
            appendUInt64(value)
        }
    }

    mutating func appendVarData(_ bytes: Data) {
        appendCompactSize(UInt64(bytes.count))
        append(bytes)
    }
}
