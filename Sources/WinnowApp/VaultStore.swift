import BitcoinCore
import BitcoinP2P
import Foundation
import WalletCore

/// Disambiguates the wire-format transaction from `SwiftUI.Transaction` in
/// app files that import both SwiftUI and BitcoinP2P (the module name also
/// collides with the `BitcoinP2P` enum, so module qualification is no help).
typealias BitcoinTransaction = Transaction

/// A created vault as persisted by the app (JSON at `vaults.json`). Signing
/// secrets never live here — vault spends load the wallet's master key from
/// the KeyStore for the duration of the signing call, like `Wallet` does.
struct VaultRecord: Codable, Equatable, Identifiable, Sendable {
    /// The descriptor checksum — stable and unique per descriptor.
    var id: String
    var name: String
    var descriptor: String
    /// Filter-scan height when the vault was added; funds sent earlier than
    /// this are not discovered (forward-only scanning, docs/read-side.md).
    var createdAtHeight: UInt32
    var nextReceiveIndex: UInt32 = 0
    var nextChangeIndex: UInt32 = 0
    /// Vault UTXOs discovered by filter matches. `chain` is the descriptor's
    /// multipath choice (0 receive, 1 change), mirroring `WalletUTXO`.
    var utxos: [WalletUTXO] = []

    var balance: Int64 { utxos.reduce(0) { $0 + $1.amount } }
}

/// App-side vault bookkeeping: the persisted records plus the UTXO tracking
/// that `Wallet` performs for the single-sig wallet. Fed by the same combined
/// filter scan — a vault is just another set of watched scripts.
actor VaultStore {
    private var records: [VaultRecord] = []
    private var storageURL: URL?

    /// Points the store at its JSON file, loading any existing records.
    func configure(storageURL: URL?) {
        self.storageURL = storageURL
        guard let storageURL, let data = try? Data(contentsOf: storageURL) else {
            records = []
            return
        }
        records = (try? JSONDecoder().decode([VaultRecord].self, from: data)) ?? []
    }

    var all: [VaultRecord] { records }

    func record(id: String) -> VaultRecord? {
        records.first { $0.id == id }
    }

    @discardableResult
    func add(name: String, descriptor: Descriptor, createdAtHeight: UInt32) throws -> VaultRecord {
        let serialized = descriptor.serialized()
        let id = String(serialized.split(separator: "#").last ?? Substring(serialized))
        guard !records.contains(where: { $0.id == id }) else {
            throw AppModel.AppError.duplicateVault
        }
        let record = VaultRecord(id: id, name: name, descriptor: serialized,
                                 createdAtHeight: createdAtHeight)
        records.append(record)
        try persist()
        return record
    }

    func remove(id: String) throws {
        records.removeAll { $0.id == id }
        try persist()
    }

    /// Receive/change scripts of every vault, for the combined filter scan.
    func watchScripts(network: BitcoinNetwork) -> [Data] {
        records.flatMap { record in
            (try? Vault(record.descriptor, network: network)
                .watchScripts(upTo: watchCount(for: record))) ?? []
        }
    }

    /// Consumes one matched block like `Wallet.apply`: pays to vault scripts
    /// become UTXOs (advancing the index bookkeeping), spends shrink the set.
    func apply(match: BlockMatch, network: BitcoinNetwork) throws {
        var changed = false
        for recordIndex in records.indices {
            let vault = try Vault(records[recordIndex].descriptor, network: network)
            var owner: [Data: (choice: Int, index: UInt32)] = [:]
            for index in 0 ..< watchCount(for: records[recordIndex]) {
                for choice in 0 ..< 2 {
                    owner[try vault.scriptPubKey(index: index, choice: choice)] = (choice, index)
                }
            }
            for tx in match.block.transactions {
                let txid = tx.txid
                for input in tx.inputs {
                    if let spent = records[recordIndex].utxos.firstIndex(where: {
                        $0.txid == input.previousOutput.txid && $0.vout == input.previousOutput.vout
                    }) {
                        records[recordIndex].utxos.remove(at: spent)
                        changed = true
                    }
                }
                for (vout, output) in tx.outputs.enumerated() {
                    guard let (choice, index) = owner[output.scriptPubKey] else { continue }
                    if let existing = records[recordIndex].utxos.firstIndex(where: {
                        $0.txid == txid && $0.vout == UInt32(vout)
                    }) {
                        // Re-applied block or pending change confirming.
                        records[recordIndex].utxos[existing].height = match.height
                    } else {
                        records[recordIndex].utxos.append(WalletUTXO(
                            txid: txid, vout: UInt32(vout), amount: output.value,
                            scriptPubKey: output.scriptPubKey,
                            chain: AddressChain(rawValue: choice) ?? .receive,
                            index: index, height: match.height))
                    }
                    changed = true
                    if choice == AddressChain.receive.rawValue, index >= records[recordIndex].nextReceiveIndex {
                        records[recordIndex].nextReceiveIndex = index + 1
                    }
                    if choice == AddressChain.change.rawValue, index >= records[recordIndex].nextChangeIndex {
                        records[recordIndex].nextChangeIndex = index + 1
                    }
                }
            }
        }
        if changed { try persist() }
    }

    /// Marks the next receive index used ("New address" in the UI).
    func advanceReceiveIndex(id: String) throws {
        guard let index = records.firstIndex(where: { $0.id == id }) else { return }
        records[index].nextReceiveIndex += 1
        try persist()
    }

    /// After a vault spend is broadcast: the selected inputs leave the set at
    /// once and the change output enters it pending (height 0) until its block
    /// match confirms it — the same rule `Wallet.send` applies locally.
    func recordSpend(id: String, transaction: Transaction, changeScriptPubKey: Data?,
                     changeIndex: UInt32) throws {
        guard let index = records.firstIndex(where: { $0.id == id }) else { return }
        let txid = transaction.txid
        for input in transaction.inputs {
            records[index].utxos.removeAll {
                $0.txid == input.previousOutput.txid && $0.vout == input.previousOutput.vout
            }
        }
        if let changeScriptPubKey,
           let vout = transaction.outputs.firstIndex(where: { $0.scriptPubKey == changeScriptPubKey }) {
            let output = transaction.outputs[vout]
            records[index].utxos.append(WalletUTXO(
                txid: txid, vout: UInt32(vout), amount: output.value,
                scriptPubKey: changeScriptPubKey, chain: .change,
                index: changeIndex, height: 0))
            records[index].nextChangeIndex = changeIndex + 1
        }
        try persist()
    }

    /// Indices 0 ..< max(used receive, used change, 1) + 2 of lookahead.
    private func watchCount(for record: VaultRecord) -> UInt32 {
        max(record.nextReceiveIndex, record.nextChangeIndex, 1) + 2
    }

    private func persist() throws {
        guard let storageURL else { return }
        let data = try JSONEncoder().encode(records)
        try data.write(to: storageURL, options: .atomic)
    }
}
