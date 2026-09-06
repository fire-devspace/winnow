import Foundation

enum VectorError: Error {
    case missingFile(String)
    case badHex(String)
    case malformed(String)
}

func vectorData(_ name: String) throws -> Data {
    guard let url = Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Vectors") else {
        throw VectorError.missingFile(name)
    }
    return try Data(contentsOf: url)
}

func vectorString(_ name: String) throws -> String {
    String(decoding: try vectorData(name), as: UTF8.self)
}

extension Data {
    init?(hex: String) {
        let cleaned = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        guard cleaned.count % 2 == 0, !cleaned.isEmpty else { return nil }
        var bytes = Data()
        bytes.reserveCapacity(cleaned.count / 2)
        var index = cleaned.startIndex
        while index < cleaned.endIndex {
            let next = cleaned.index(index, offsetBy: 2)
            guard let byte = UInt8(cleaned[index ..< next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        self = bytes
    }

    var hex: String {
        map { String(format: "%02x", $0) }.joined()
    }
}

/// Extracts the contents of every <tt>...</tt> tag in a line of a BIP mediawiki doc.
func ttTags(in line: String) -> [String] {
    line.components(separatedBy: "<tt>").dropFirst().compactMap { chunk in
        guard let end = chunk.range(of: "</tt>") else { return nil }
        return String(chunk[..<end.lowerBound])
    }
}

/// Minimal raw-block parser: extracts output scriptPubKeys of every transaction.
/// Handles legacy and segwit serialization; enough for BIP158 filter reconstruction.
func blockOutputScripts(_ block: Data) throws -> [Data] {
    var scripts: [Data] = []
    var offset = 80 // block header

    func readVarInt() throws -> Int {
        guard offset < block.count else { throw VectorError.malformed("varint eof") }
        let first = block[offset]
        offset += 1
        switch first {
        case ..<0xFD: return Int(first)
        case 0xFD:
            guard offset + 2 <= block.count else { throw VectorError.malformed("varint16 eof") }
            defer { offset += 2 }
            return Int(block[offset]) | Int(block[offset + 1]) << 8
        case 0xFE:
            guard offset + 4 <= block.count else { throw VectorError.malformed("varint32 eof") }
            defer { offset += 4 }
            return Int(block[offset]) | Int(block[offset + 1]) << 8 |
                Int(block[offset + 2]) << 16 | Int(block[offset + 3]) << 24
        default:
            guard offset + 8 <= block.count else { throw VectorError.malformed("varint64 eof") }
            var value = 0
            for i in 0 ..< 8 { value |= Int(block[offset + i]) << (8 * i) }
            offset += 8
            return value
        }
    }

    let txCount = try readVarInt()
    for _ in 0 ..< txCount {
        offset += 4 // version
        var inputCount = try readVarInt()
        let segwit = inputCount == 0 && offset < block.count && block[offset] != 0
        if segwit {
            offset += 1 // flag
            inputCount = try readVarInt()
        }
        for _ in 0 ..< inputCount {
            offset += 36 // outpoint
            let scriptLength = try readVarInt()
            offset += scriptLength + 4 // scriptSig + sequence
        }
        let outputCount = try readVarInt()
        for _ in 0 ..< outputCount {
            offset += 8 // value
            let scriptLength = try readVarInt()
            guard offset + scriptLength <= block.count else { throw VectorError.malformed("output eof") }
            scripts.append(block.subdata(in: offset ..< offset + scriptLength))
            offset += scriptLength
        }
        if segwit {
            for _ in 0 ..< inputCount {
                let itemCount = try readVarInt()
                for _ in 0 ..< itemCount {
                    offset += try readVarInt()
                }
            }
        }
        offset += 4 // locktime
    }
    guard offset == block.count else { throw VectorError.malformed("trailing bytes \(offset)/\(block.count)") }
    return scripts
}
