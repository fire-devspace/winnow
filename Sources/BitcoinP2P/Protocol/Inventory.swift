import Foundation

/// Inventory vector type (uint32 on the wire). MSG_WITNESS_FLAG (0x40000000)
/// is OR'd into the base type to request witness serialization (BIP144).
public struct InventoryType: RawRepresentable, Equatable, Sendable, Hashable {
    public let rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }

    public static let error = InventoryType(rawValue: 0)
    public static let tx = InventoryType(rawValue: 1)
    public static let block = InventoryType(rawValue: 2)
    public static let filteredBlock = InventoryType(rawValue: 3)
    public static let cmpctBlock = InventoryType(rawValue: 4)
    public static let witnessTx = InventoryType(rawValue: 0x4000_0001)
    public static let witnessBlock = InventoryType(rawValue: 0x4000_0002)

    /// Base type with the witness flag stripped.
    public var baseType: InventoryType { InventoryType(rawValue: rawValue & 0x3FFF_FFFF) }
    public var isWitness: Bool { rawValue & 0x4000_0000 != 0 }
}

/// One (type, hash) pair inside `inv` / `getdata` / `notfound` payloads.
/// `hash` is a 32-byte txid/block hash in internal byte order; for witness
/// types the hash is still the plain txid/block hash (BIP144).
public struct InventoryVector: Equatable, Sendable {
    public var type: InventoryType
    public var hash: Data

    public init(type: InventoryType, hash: Data) {
        precondition(hash.count == 32, "inventory hash must be 32 bytes")
        self.type = type
        self.hash = hash
    }

    public var serialized: Data {
        var data = Data()
        data.appendUInt32(type.rawValue)
        data.append(hash)
        return data
    }

    public static func decode(from reader: inout ByteReader) throws -> InventoryVector {
        InventoryVector(type: InventoryType(rawValue: try reader.readUInt32()),
                        hash: try reader.readBytes(32))
    }
}

/// Shared payload shape of `inv`, `getdata` and `notfound`.
public struct InventoryPayload: Equatable, Sendable {
    public var vectors: [InventoryVector]

    public init(_ vectors: [InventoryVector]) { self.vectors = vectors }

    public var serialized: Data {
        var data = Data()
        data.appendCompactSize(UInt64(vectors.count))
        for vector in vectors { data.append(vector.serialized) }
        return data
    }

    public static func decode(_ payload: Data) throws -> InventoryPayload {
        var reader = ByteReader(payload)
        let count = try reader.readVarInt()
        guard count <= 50_000 else { throw WireError.malformed("inventory count \(count)") }
        var vectors: [InventoryVector] = []
        vectors.reserveCapacity(Int(count))
        for _ in 0 ..< count { vectors.append(try InventoryVector.decode(from: &reader)) }
        try reader.requireEnd()
        return InventoryPayload(vectors)
    }
}
