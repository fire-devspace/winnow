import WalletCore
import SwiftUI
import UIKit

/// One vault: receive address, tracked UTXOs, and the spend flow entry
/// points (creator role here, signer/combiner in `MuSig2SignView`).
struct VaultDetailView: View {
    let recordID: String
    var send: () -> Void
    @Environment(AppModel.self) private var model
    @State private var showSign = false
    @State private var showBackup = false

    private var record: VaultRecord? { model.vaults.first { $0.id == recordID } }

    /// " · matures in N blocks" for an immature coinbase coin — the review
    /// gate will refuse to spend it until then, so the row says why first.
    private func maturityNote(for utxo: WalletUTXO) -> String {
        guard utxo.isCoinbase, utxo.height > 0 else { return "" }
        let matureAt = utxo.height + Wallet.coinbaseMaturity - 1
        guard model.status.tipHeight < matureAt else { return "" }
        return " · matures in \(matureAt - model.status.tipHeight) blocks"
    }

    var body: some View {
        List {
            if let record, let vault = try? Vault(record.descriptor, network: model.network) {
                Section("Receive") {
                    if let address = try? vault.address(index: record.nextReceiveIndex) {
                        HStack {
                            Spacer()
                            QRCodeView(content: address)
                                .frame(width: 180, height: 180)
                            Spacer()
                        }
                        CopyableTextBlock(text: address)
                        Button("New address") {
                            Task { await model.advanceVaultReceiveIndex(id: record.id) }
                        }
                    }
                }

                Section("Balance · confirmed") {
                    LabeledContent("Total") {
                        Text(satsText(record.balance))
                            .accessibilityIdentifier("vaultBalance")
                    }
                    ForEach(Array(record.utxos.enumerated()), id: \.offset) { _, utxo in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(satsText(utxo.amount))
                            Text("\(utxo.txid.displayHex.prefix(16))…:\(utxo.vout) · \(utxo.height > 0 ? "block \(utxo.height)" : "awaiting confirmation")\(maturityNote(for: utxo))")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    if record.utxos.isEmpty {
                        Text("No funds found yet. Payments to the vault's addresses appear once they confirm in a block.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }

                VaultPolicySection(vault: vault)

                Section {
                    Button("Back up this wallet") { showBackup = true }
                        .accessibilityIdentifier("vaultBackupButton")
                } footer: {
                    Text("Save the wallet backup file and your recovery phrase. Each other signer needs its own key backup. A backup cannot replace a missing signer’s key.")
                }

                Section {
                    Button("Send", action: send)
                        .accessibilityIdentifier("sendFromAccountButton")
                        .disabled(record.utxos.isEmpty)
                    Button("Continue signing") { showSign = true }
                } footer: {
                    Text("Create a payment, then exchange approvals with the other signer.")
                }
            } else {
                Text("This vault is no longer available.")
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle(record?.name ?? "Vault")
        .sheet(isPresented: $showSign) {
            MuSig2SignView(recordID: recordID)
        }
        .sheet(isPresented: $showBackup) {
            ExportBundleView()
        }
    }
}

/// Read from the spending descriptor, never from a label or imported claim.
struct VaultPolicySection: View {
    let vault: Vault

    var body: some View {
        Section {
            Text("\(vault.threshold) of \(vault.signerCount) signing keys required")
                .accessibilityIdentifier("vaultRequiredKeys")
            Text(vault.isScriptPath ? "Shared control" : "Every signing key")
                .accessibilityIdentifier("vaultPolicyPurpose")
            Text(vault.threshold == 1
                 ? "One signing key can spend these funds."
                 : "One signing key cannot spend these funds.")
                .accessibilityIdentifier("vaultSingleKeyRule")
            DisclosureGroup("What this policy proves") {
                Text(vault.isScriptPath
                     ? "The spending script enforces the threshold, with no secret key that bypasses it. A spend reveals the script and threshold on chain; the receiving address alone does not."
                     : "MuSig2 requires every participating key and produces one Taproot key-path signature. The signature itself does not reveal how many devices participated. There is no recovery path if a required key and its backups are lost.")
                Text("Names and cards do not enforce protection. The policy cannot prove who has key copies, where they are kept, or safety from physical coercion.")
            }
            .font(.footnote)
        } header: {
            Text("Signing policy")
        }
    }
}
