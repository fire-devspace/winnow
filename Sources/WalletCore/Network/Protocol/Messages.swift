import Foundation

/// `version` message payload (protocol 70016).
public struct VersionMessage: Equatable, Sendable {
    public var version: Int32
    public var services: UInt64
    public var timestamp: Int64
    public var receiver: PeerAddress
    public var sender: PeerAddress
    public var nonce: UInt64
    public var userAgent: String
    public var startHeight: Int32
    /// BIP37 relay flag (false = we don't want unsolicited tx relay).
    public var relay: Bool

    public init(version: Int32, services: UInt64, timestamp: Int64,
                receiver: PeerAddress, sender: PeerAddress, nonce: UInt64,
                userAgent: String, startHeight: Int32, relay: Bool) {
        self.version = version
        self.services = services
        self.timestamp = timestamp
        self.receiver = receiver
        self.sender = sender
        self.nonce = nonce
        self.userAgent = userAgent
        self.startHeight = startHeight
        self.relay = relay
    }

    public var serialized: Data {
        var data = Data()
        data.appendInt32(version)
        data.appendUInt64(services)
        data.appendInt64(timestamp)
        data.append(receiver.serialized(includeTime: false))
        data.append(sender.serialized(includeTime: false))
        data.appendUInt64(nonce)
        data.appendVarString(userAgent)
        data.appendInt32(startHeight)
        data.appendUInt8(relay ? 1 : 0)
        return data
    }

    public static func decode(_ payload: Data) throws -> VersionMessage {
        var reader = ByteReader(payload)
        let version = try reader.readInt32()
        let services = try reader.readUInt64()
        let timestamp = try reader.readInt64()
        let receiver = try PeerAddress.decode(from: &reader, includeTime: false)
        let sender = try PeerAddress.decode(from: &reader, includeTime: false)
        let nonce = try reader.readUInt64()
        let userAgent = try reader.readVarString(maxLength: 256)
        let startHeight = try reader.readInt32()
        // relay flag is optional (absent in protocol < 70001)
        let relay = reader.remaining > 0 ? try reader.readUInt8() != 0 : true
        return VersionMessage(version: version, services: services, timestamp: timestamp,
                              receiver: receiver, sender: sender, nonce: nonce,
                              userAgent: userAgent, startHeight: startHeight, relay: relay)
    }
}

/// `getheaders` payload: protocol version, block locator, stop hash.
/// A zero stop hash means "as many as possible" (up to 2000).
public struct GetHeadersMessage: Equatable, Sendable {
    public var version: Int32
    public var locatorHashes: [Data]
    public var stopHash: Data

    public init(version: Int32, locatorHashes: [Data], stopHash: Data = Data(repeating: 0, count: 32)) {
        self.version = version
        self.locatorHashes = locatorHashes
        self.stopHash = stopHash
    }

    public var serialized: Data {
        var data = Data()
        data.appendInt32(version)
        data.appendCompactSize(UInt64(locatorHashes.count))
        for hash in locatorHashes { data.append(hash) }
        data.append(stopHash)
        return data
    }

    public static func decode(_ payload: Data) throws -> GetHeadersMessage {
        var reader = ByteReader(payload)
        let version = try reader.readInt32()
        let count = try reader.readVarInt()
        guard count <= 101 else { throw WireError.malformed("locator count \(count)") }
        var hashes: [Data] = []
        for _ in 0 ..< count { hashes.append(try reader.readBytes(32)) }
        let stopHash = try reader.readBytes(32)
        try reader.requireEnd()
        return GetHeadersMessage(version: version, locatorHashes: hashes, stopHash: stopHash)
    }
}

/// `getcfilters` / `getcfheaders` payload (BIP157, identical layout).
public struct GetCFiltersRequest: Equatable, Sendable {
    public var filterType: UInt8
    public var startHeight: UInt32
    public var stopHash: Data

    public init(filterType: UInt8 = 0, startHeight: UInt32, stopHash: Data) {
        self.filterType = filterType
        self.startHeight = startHeight
        self.stopHash = stopHash
    }

    public var serialized: Data {
        var data = Data()
        data.appendUInt8(filterType)
        data.appendUInt32(startHeight)
        data.append(stopHash)
        return data
    }

    public static func decode(_ payload: Data) throws -> GetCFiltersRequest {
        var reader = ByteReader(payload)
        let request = try GetCFiltersRequest(filterType: reader.readUInt8(),
                                             startHeight: reader.readUInt32(),
                                             stopHash: reader.readBytes(32))
        try reader.requireEnd()
        return request
    }
}

/// `cfilter` payload (BIP157). `filter` is the BIP158 NBytes:
/// compactSize(N) || Golomb-Rice bitstream.
public struct CFilterMessage: Equatable, Sendable {
    public var filterType: UInt8
    public var blockHash: Data
    public var filter: Data

    public init(filterType: UInt8 = 0, blockHash: Data, filter: Data) {
        self.filterType = filterType
        self.blockHash = blockHash
        self.filter = filter
    }

    public var serialized: Data {
        var data = Data()
        data.appendUInt8(filterType)
        data.append(blockHash)
        data.appendVarData(filter)
        return data
    }

    public static func decode(_ payload: Data) throws -> CFilterMessage {
        var reader = ByteReader(payload)
        let message = try CFilterMessage(filterType: reader.readUInt8(),
                                         blockHash: reader.readBytes(32),
                                         filter: reader.readVarData())
        try reader.requireEnd()
        return message
    }

    /// Splits the BIP158 NBytes into (item count, bitstream) for GCSFilter.
    public func parsedFilter() throws -> (n: UInt32, encoded: Data) {
        var reader = ByteReader(filter)
        let n = try reader.readVarInt()
        guard n <= UInt64(UInt32.max) else {
            throw WireError.malformed("filter element count \(n)")
        }
        return (UInt32(n), filter.subdata(in: reader.offset ..< filter.count))
    }
}

/// `cfheaders` payload (BIP157): previous filter header plus one filter hash
/// per block in [startHeight, stopHeight].
public struct CFHeadersMessage: Equatable, Sendable {
    public var filterType: UInt8
    public var stopHash: Data
    public var previousFilterHeader: Data
    public var filterHashes: [Data]

    public init(filterType: UInt8 = 0, stopHash: Data, previousFilterHeader: Data, filterHashes: [Data]) {
        self.filterType = filterType
        self.stopHash = stopHash
        self.previousFilterHeader = previousFilterHeader
        self.filterHashes = filterHashes
    }

    public var serialized: Data {
        var data = Data()
        data.appendUInt8(filterType)
        data.append(stopHash)
        data.append(previousFilterHeader)
        data.appendCompactSize(UInt64(filterHashes.count))
        for hash in filterHashes { data.append(hash) }
        return data
    }

    public static func decode(_ payload: Data) throws -> CFHeadersMessage {
        var reader = ByteReader(payload)
        let filterType = try reader.readUInt8()
        let stopHash = try reader.readBytes(32)
        let previousFilterHeader = try reader.readBytes(32)
        let count = try reader.readVarInt()
        guard count <= 2_000 else { throw WireError.malformed("cfheaders count \(count)") }
        var hashes: [Data] = []
        for _ in 0 ..< count { hashes.append(try reader.readBytes(32)) }
        try reader.requireEnd()
        return CFHeadersMessage(filterType: filterType, stopHash: stopHash,
                                previousFilterHeader: previousFilterHeader, filterHashes: hashes)
    }
}

/// `getcfcheckpt` payload (BIP157).
public struct GetCFCheckptRequest: Equatable, Sendable {
    public var filterType: UInt8
    public var stopHash: Data

    public init(filterType: UInt8 = 0, stopHash: Data) {
        self.filterType = filterType
        self.stopHash = stopHash
    }

    public var serialized: Data {
        var data = Data()
        data.appendUInt8(filterType)
        data.append(stopHash)
        return data
    }

    public static func decode(_ payload: Data) throws -> GetCFCheckptRequest {
        var reader = ByteReader(payload)
        let request = try GetCFCheckptRequest(filterType: reader.readUInt8(),
                                              stopHash: reader.readBytes(32))
        try reader.requireEnd()
        return request
    }
}

/// `cfcheckpt` payload (BIP157): filter headers at 1000-block intervals.
/// Note Core's actual semantics (net_processing.cpp ProcessGetCFCheckPt):
/// the response holds `stopHeight / 1000` headers at heights 1000, 2000, …
/// — ascending, and NEVER the stop block itself unless it is a multiple of
/// 1000 (height 0 is never included).
public struct CFCheckptMessage: Equatable, Sendable {
    public var filterType: UInt8
    public var stopHash: Data
    public var filterHeaders: [Data]

    public init(filterType: UInt8 = 0, stopHash: Data, filterHeaders: [Data]) {
        self.filterType = filterType
        self.stopHash = stopHash
        self.filterHeaders = filterHeaders
    }

    public var serialized: Data {
        var data = Data()
        data.appendUInt8(filterType)
        data.append(stopHash)
        data.appendCompactSize(UInt64(filterHeaders.count))
        for header in filterHeaders { data.append(header) }
        return data
    }

    public static func decode(_ payload: Data) throws -> CFCheckptMessage {
        var reader = ByteReader(payload)
        let filterType = try reader.readUInt8()
        let stopHash = try reader.readBytes(32)
        let count = try reader.readVarInt()
        guard count <= 100_000 else { throw WireError.malformed("cfcheckpt count \(count)") }
        var headers: [Data] = []
        for _ in 0 ..< count { headers.append(try reader.readBytes(32)) }
        try reader.requireEnd()
        return CFCheckptMessage(filterType: filterType, stopHash: stopHash, filterHeaders: headers)
    }
}

/// A decoded P2P message. Unknown commands are preserved as raw payloads.
public enum PeerMessage: Equatable, Sendable {
    case version(VersionMessage)
    case verack
    case ping(UInt64)
    case pong(UInt64)
    case sendheaders
    /// BIP133: minimum feerate (sat/kvB) the peer relays to us.
    case feefilter(Int64)
    case inv(InventoryPayload)
    case getdata(InventoryPayload)
    case notfound(InventoryPayload)
    case tx(Transaction)
    case block(Block)
    case getheaders(GetHeadersMessage)
    case headers([BlockHeader])
    case getcfilters(GetCFiltersRequest)
    case cfilter(CFilterMessage)
    case getcfheaders(GetCFiltersRequest)
    case cfheaders(CFHeadersMessage)
    case getcfcheckpt(GetCFCheckptRequest)
    case cfcheckpt(CFCheckptMessage)
    case unknown(command: String, payload: Data)

    public var command: String {
        switch self {
        case .version: "version"
        case .verack: "verack"
        case .ping: "ping"
        case .pong: "pong"
        case .sendheaders: "sendheaders"
        case .feefilter: "feefilter"
        case .inv: "inv"
        case .getdata: "getdata"
        case .notfound: "notfound"
        case .tx: "tx"
        case .block: "block"
        case .getheaders: "getheaders"
        case .headers: "headers"
        case .getcfilters: "getcfilters"
        case .cfilter: "cfilter"
        case .getcfheaders: "getcfheaders"
        case .cfheaders: "cfheaders"
        case .getcfcheckpt: "getcfcheckpt"
        case .cfcheckpt: "cfcheckpt"
        case let .unknown(command, _): command
        }
    }

    public var payload: Data {
        switch self {
        case let .version(message): return message.serialized
        case .verack, .sendheaders: return Data()
        case let .ping(nonce), let .pong(nonce):
            var data = Data()
            data.appendUInt64(nonce)
            return data
        case let .feefilter(feeRate):
            var data = Data()
            data.appendInt64(feeRate)
            return data
        case let .inv(payload), let .getdata(payload), let .notfound(payload): return payload.serialized
        case let .tx(tx): return tx.serialized(includeWitness: true)
        case let .block(block): return block.serialized
        case let .getheaders(message): return message.serialized
        case let .headers(headers):
            var data = Data()
            data.appendCompactSize(UInt64(headers.count))
            for header in headers {
                data.append(header.serialized)
                data.appendCompactSize(0) // txn_count, always zero in `headers`
            }
            return data
        case let .getcfilters(request), let .getcfheaders(request): return request.serialized
        case let .cfilter(message): return message.serialized
        case let .cfheaders(message): return message.serialized
        case let .getcfcheckpt(request): return request.serialized
        case let .cfcheckpt(message): return message.serialized
        case let .unknown(_, payload): return payload
        }
    }

    public static func decode(command: String, payload: Data) throws -> PeerMessage {
        switch command {
        case "version": return .version(try VersionMessage.decode(payload))
        case "verack":
            try ByteReader(payload).requireEnd()
            return .verack
        case "ping":
            var reader = ByteReader(payload)
            let nonce = try reader.readUInt64()
            try reader.requireEnd()
            return .ping(nonce)
        case "pong":
            var reader = ByteReader(payload)
            let nonce = try reader.readUInt64()
            try reader.requireEnd()
            return .pong(nonce)
        case "sendheaders":
            try ByteReader(payload).requireEnd()
            return .sendheaders
        case "feefilter":
            var reader = ByteReader(payload)
            let feeRate = try reader.readInt64()
            try reader.requireEnd()
            return .feefilter(feeRate)
        case "inv": return .inv(try InventoryPayload.decode(payload))
        case "getdata": return .getdata(try InventoryPayload.decode(payload))
        case "notfound": return .notfound(try InventoryPayload.decode(payload))
        case "tx": return .tx(try Transaction.decode(payload))
        case "block": return .block(try Block.decode(payload))
        case "getheaders": return .getheaders(try GetHeadersMessage.decode(payload))
        case "headers":
            var reader = ByteReader(payload)
            let count = try reader.readVarInt()
            guard count <= 2_000 else { throw WireError.malformed("headers count \(count)") }
            var headers: [BlockHeader] = []
            headers.reserveCapacity(Int(count))
            for _ in 0 ..< count {
                headers.append(try BlockHeader.decode(from: &reader))
                let txCount = try reader.readVarInt() // always zero
                guard txCount == 0 else { throw WireError.malformed("headers txn_count \(txCount)") }
            }
            try reader.requireEnd()
            return .headers(headers)
        case "getcfilters": return .getcfilters(try GetCFiltersRequest.decode(payload))
        case "cfilter": return .cfilter(try CFilterMessage.decode(payload))
        case "getcfheaders": return .getcfheaders(try GetCFiltersRequest.decode(payload))
        case "cfheaders": return .cfheaders(try CFHeadersMessage.decode(payload))
        case "getcfcheckpt": return .getcfcheckpt(try GetCFCheckptRequest.decode(payload))
        case "cfcheckpt": return .cfcheckpt(try CFCheckptMessage.decode(payload))
        default: return .unknown(command: command, payload: payload)
        }
    }
}
