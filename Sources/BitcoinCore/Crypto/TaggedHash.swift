import CryptoKit
import Foundation

/// BIP340 tagged hash: SHA256(SHA256(tag) || SHA256(tag) || msg).
public enum TaggedHash {
    public static func hash(_ tag: String, _ message: Data) -> Data {
        let tagHash = Data(SHA256.hash(data: Data(tag.utf8)))
        var sha = SHA256()
        sha.update(data: tagHash)
        sha.update(data: tagHash)
        sha.update(data: message)
        return Data(sha.finalize())
    }
}
