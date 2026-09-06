import Foundation

/// 80-byte block header. `hash` is the block hash (SHA256d) in internal order.
public struct BlockHeader: Equatable, Sendable {
    public static let serializedSize = 80

    public let version: Int32
    public let previousHash: Data // 32 bytes, internal order
    public let merkleRoot: Data // 32 bytes, internal order
    public let time: UInt32
    public let bits: UInt32
    public let nonce: UInt32

    /// Block hash (SHA256d of the 80-byte header), internal byte order.
    ///
    /// Stored rather than computed. A header never changes after construction,
    /// and `hash` sits in the hottest loops in the client: proof-of-work
    /// checks, chain indexing and block locators all ask for it repeatedly.
    /// Recomputing it there meant hundreds of millions of double-SHA256s over
    /// a mainnet sync (#86).
    public let hash: Data

    public init(version: Int32, previousHash: Data, merkleRoot: Data, time: UInt32, bits: UInt32, nonce: UInt32) {
        precondition(previousHash.count == 32 && merkleRoot.count == 32)
        self.version = version
        self.previousHash = previousHash
        self.merkleRoot = merkleRoot
        self.time = time
        self.bits = bits
        self.nonce = nonce
        var serialized = Data()
        serialized.reserveCapacity(Self.serializedSize)
        serialized.appendInt32(version)
        serialized.append(previousHash)
        serialized.append(merkleRoot)
        serialized.appendUInt32(time)
        serialized.appendUInt32(bits)
        serialized.appendUInt32(nonce)
        hash = SHA256d.hash(serialized)
    }

    public var serialized: Data {
        var data = Data()
        data.reserveCapacity(Self.serializedSize)
        data.appendInt32(version)
        data.append(previousHash)
        data.append(merkleRoot)
        data.appendUInt32(time)
        data.appendUInt32(bits)
        data.appendUInt32(nonce)
        return data
    }

    public static func decode(from reader: inout ByteReader) throws -> BlockHeader {
        BlockHeader(version: try reader.readInt32(),
                    previousHash: try reader.readBytes(32),
                    merkleRoot: try reader.readBytes(32),
                    time: try reader.readUInt32(),
                    bits: try reader.readUInt32(),
                    nonce: try reader.readUInt32())
    }

    public static func decode(_ data: Data) throws -> BlockHeader {
        var reader = ByteReader(data)
        let header = try decode(from: &reader)
        try reader.requireEnd()
        return header
    }
}

/// A full block as carried by the `block` message (segwit serialization).
public struct Block: Equatable, Sendable {
    public var header: BlockHeader
    public var transactions: [Transaction]

    public init(header: BlockHeader, transactions: [Transaction]) {
        self.header = header
        self.transactions = transactions
    }

    /// Block hash — must equal the hash announced in the inv/getdata exchange.
    public var hash: Data { header.hash }

    /// Merkle root recomputed from the transaction set (SHA256d over txids,
    /// odd rows duplicating the last node — Bitcoin's rule), internal order.
    /// nil for an empty block, which is invalid.
    public var computedMerkleRoot: Data? {
        guard !transactions.isEmpty else { return nil }
        var level = transactions.map(\.txid)
        while level.count > 1 {
            if level.count % 2 == 1 { level.append(level[level.count - 1]) }
            var next: [Data] = []
            next.reserveCapacity(level.count / 2)
            var index = 0
            while index < level.count {
                next.append(SHA256d.hash(level[index] + level[index + 1]))
                index += 2
            }
            level = next
        }
        return level.first
    }

    /// True when the transaction set hashes to the header's committed merkle
    /// root. Duplicate txids are rejected first (CVE-2012-2459 malleability),
    /// so a mutated transaction list cannot reproduce a valid root. This is
    /// what authenticates the block *body* against the PoW-checked header —
    /// without it, a peer could substitute an arbitrary transaction set.
    public var hasValidMerkleRoot: Bool {
        let txids = transactions.map(\.txid)
        guard Set(txids).count == txids.count else { return false }
        return computedMerkleRoot == header.merkleRoot
    }

    public var serialized: Data {
        var data = header.serialized
        data.appendCompactSize(UInt64(transactions.count))
        for tx in transactions { data.append(tx.serialized(includeWitness: true)) }
        return data
    }

    public static func decode(_ data: Data) throws -> Block {
        var reader = ByteReader(data)
        let header = try BlockHeader.decode(from: &reader)
        let count = try reader.readVarInt()
        guard count <= 100_000 else { throw WireError.malformed("block tx count \(count)") }
        var transactions: [Transaction] = []
        transactions.reserveCapacity(Int(count))
        for _ in 0 ..< count { transactions.append(try Transaction.decode(from: &reader)) }
        try reader.requireEnd()
        return Block(header: header, transactions: transactions)
    }
}
