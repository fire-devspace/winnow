import Foundation

/// A created vault as persisted by the app (JSON at `vaults.json`). Signing
/// secrets never live here — vault spends load the wallet's master key from
/// the KeyStore for the duration of the signing call, like `Wallet` does.
public struct VaultRecord: Codable, Equatable, Identifiable, Sendable {
    /// The descriptor checksum — stable and unique per descriptor.
    public var id: String
    public var name: String
    public var descriptor: String
    /// Filter-scan height when the vault was added; funds sent earlier than
    /// this are not discovered (forward-only scanning, docs/read-side.md).
    public var createdAtHeight: UInt32
    public var nextReceiveIndex: UInt32 = 0
    public var nextChangeIndex: UInt32 = 0
    /// Every vault coin row, spent ones included. Mutations go through this;
    /// reads should use `utxos`, which hides the tombstones.
    public var allUtxos: [WalletUTXO] = []

    public init(id: String, name: String, descriptor: String, createdAtHeight: UInt32,
                nextReceiveIndex: UInt32 = 0, nextChangeIndex: UInt32 = 0,
                allUtxos: [WalletUTXO] = []) {
        self.id = id
        self.name = name
        self.descriptor = descriptor
        self.createdAtHeight = createdAtHeight
        self.nextReceiveIndex = nextReceiveIndex
        self.nextChangeIndex = nextChangeIndex
        self.allUtxos = allUtxos
    }

    /// The coins this vault actually has.
    ///
    /// Computed rather than stored so a spent row cannot reach the balance,
    /// the spend screen, or `createSpend` by anyone forgetting to filter --
    /// `VaultDetailView` passes this straight into coin selection (#127).
    public var utxos: [WalletUTXO] { allUtxos.filter { !$0.isSpent } }

    public var balance: Int64 { utxos.reduce(0) { $0 + $1.amount } }

    /// The stored property is `allUtxos` while the on-disk key stays `utxos`,
    /// so a vaults.json written before #127 loads unchanged.
    private enum CodingKeys: String, CodingKey {
        case id, name, descriptor, createdAtHeight, nextReceiveIndex, nextChangeIndex
        case allUtxos = "utxos"
    }
}

