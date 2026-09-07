import WalletCore
import SwiftUI
import UIKit

/// One vault: receive address, tracked UTXOs, and the spend flow entry
/// points (creator role here, signer/combiner in `VaultSignView`).
struct VaultDetailView: View {
    let recordID: String
    @Environment(AppModel.self) private var model
    @State private var showSpend = false
    @State private var showSign = false

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
                    Button("Create spend PSBT…") { showSpend = true }
                        .disabled(record.utxos.isEmpty)
                    Button("Sign / combine PSBTs…") { showSign = true }
                } footer: {
                    Text("Spends run as a PSBTv2 workflow: create here, partial-sign on each cosigner device, combine when enough partials are collected, then finalize and broadcast.")
                }
            } else {
                Text("This vault is no longer available.")
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle(record?.name ?? "Vault")
        .sheet(isPresented: $showSpend) {
            VaultSpendView(recordID: recordID)
        }
        .sheet(isPresented: $showSign) {
            VaultSignView(recordID: recordID)
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

/// Creator role: destination + amount + feerate → the spend PSBT (Base64),
/// shared with the cosigners.
struct VaultSpendView: View {
    let recordID: String
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var destination = ""
    @State private var amountText = ""
    @State private var feeRateText = ""
    @State private var created: String?
    @State private var error: String?
    /// Informational, not a failure: rendered orange, kept separate from
    /// `error` so a successful creation never looks like a failed one (#151).
    @State private var notice: String?

    private var record: VaultRecord? { model.vaults.first { $0.id == recordID } }

    var body: some View {
        NavigationStack {
            Form {
                Section("Spend from vault") {
                    LabeledContent("Available", value: satsText(record?.balance ?? 0))
                    TextField("Destination address", text: $destination)
                        .font(.system(.footnote, design: .monospaced))
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    TextField("Amount (sats)", text: $amountText)
                        .keyboardType(.numberPad)
                    TextField("Feerate (sat/vB)", text: $feeRateText)
                        .keyboardType(.decimalPad)
                }
                if let error {
                    Section { Text(error).foregroundStyle(.red).font(.footnote) }
                }
                if let notice {
                    Section {
                        Label(notice, systemImage: "clock.arrow.circlepath")
                            .foregroundStyle(.orange).font(.footnote)
                            .accessibilityIdentifier("vaultLocktimeLagNotice")
                    }
                }
                Section {
                    Button("Create spend PSBT") { create() }
                        .disabled(destination.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                  || Int64(amountText) == nil)
                }
                if let created {
                    Section {
                        CopyableTextBlock(text: created)
                    } header: {
                        Text("Spend PSBT")
                    } footer: {
                        Text("Share this with the cosigners. Each signs it in “Sign / combine PSBTs”; combine the partials there when enough are collected.")
                    }
                }
            }
            .navigationTitle("Create spend")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .task {
                let rate = await model.resolvedFeeRate(priority: .medium, override: nil)
                feeRateText = rate.formatted(.number.precision(.fractionLength(0 ... 2)))
            }
        }
    }

    private func create() {
        error = nil
        notice = nil
        created = nil
        guard let record else { return }
        do {
            guard let amount = Int64(amountText), amount > 0,
                  let feeRate = Double(feeRateText), feeRate > 0
            else {
                error = "Enter an amount in sats and a feerate in sat/vB."
                return
            }
            let payment = try model.vaultPayment(amount: amount, address: destination)
            let (psbt, lagsTip) = try model.createVaultSpend(record: record, payment: payment,
                                                             feeRateSatPerVByte: feeRate)
            created = psbt.base64
            // #151, same as the ordinary send path: the PSBT's locktime came
            // from `status.tipHeight`, which lags while headers catch up.
            notice = lagsTip
                ? "Created while header sync is catching up: the spend carries a "
                    + "locktime behind the network tip, which on-chain reveals it was "
                    + "built mid-sync. Recreate it after sync to avoid that."
                : nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}
