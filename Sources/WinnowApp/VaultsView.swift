import BitcoinCore
import SwiftUI
import UIKit
import WalletCore

/// The created vaults (k-of-n script-path and n-of-n MuSig2), with balances
/// tracked by the combined filter scan.
struct VaultsView: View {
    @Environment(AppModel.self) private var model
    @State private var showCreate = false

    var body: some View {
        NavigationStack {
            List {
                if model.vaults.isEmpty {
                    Text("No vaults yet. A vault is a shared-custody Taproot descriptor watched by the same filter stream as the wallet.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                ForEach(model.vaults) { record in
                    NavigationLink(destination: VaultDetailView(recordID: record.id)) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(record.name)
                            Text(policySummary(record))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(satsText(record.balance))
                            .font(.subheadline)
                    }
                }
                .onDelete { offsets in
                    for index in offsets {
                        Task { await model.removeVault(id: model.vaults[index].id) }
                    }
                }
            }
            .navigationTitle("Vaults")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button("New vault") { showCreate = true }
                        .accessibilityIdentifier("newVaultButton")
                }
            }
            .sheet(isPresented: $showCreate) {
                VaultCreateView()
            }
        }
    }

    private func policySummary(_ record: VaultRecord) -> String {
        guard let vault = try? Vault(record.descriptor, network: model.network) else {
            return "invalid descriptor"
        }
        switch vault.policy {
        case let .multiA(threshold, _, cosigners, _):
            return "\(threshold)-of-\(cosigners.count) · script path"
        case let .muSig2(participants, _):
            return "\(participants.count)-of-\(participants.count) · MuSig2 key path"
        }
    }
}

/// Builds a vault descriptor from cosigner key expressions (pasted, or this
/// device's own wallet key), previews the descriptor and first address, and
/// saves it into the vault store.
struct VaultCreateView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var isMuSig2 = false
    @State private var threshold = 2
    @State private var cosigners: [String] = []
    @State private var pasted = ""
    @State private var builtDescriptor: Descriptor?
    @State private var error: String?
    @State private var saving = false

    private var policyName: String { isMuSig2 ? "MuSig2" : "k-of-n" }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Vault name", text: $name)
                        .accessibilityIdentifier("vaultNameField")
                    Picker("Policy", selection: $isMuSig2) {
                        Text("k-of-n (script path)").tag(false)
                        Text("n-of-n (MuSig2)").tag(true)
                    }
                    if !isMuSig2 {
                        Stepper("Threshold: \(threshold) of \(max(cosigners.count, 1))",
                                value: $threshold, in: 1 ... max(cosigners.count, 1))
                    }
                }

                Section {
                    ForEach(Array(cosigners.enumerated()), id: \.offset) { index, expression in
                        VStack(alignment: .leading) {
                            Text("Cosigner \(index + 1)").font(.caption)
                            Text(expression)
                                .font(.system(.caption2, design: .monospaced))
                                .lineLimit(2)
                        }
                    }
                    .onDelete { cosigners.remove(atOffsets: $0) }
                    TextField("Paste a cosigner key expression", text: $pasted)
                        .font(.system(.caption, design: .monospaced))
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .accessibilityIdentifier("cosignerField")
                    Button("Add pasted key") { addPasted() }
                        .accessibilityIdentifier("addPastedKeyButton")
                        .disabled(pasted.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Button("Add this device's key") { addOwn() }
                        .accessibilityIdentifier("addDeviceKeyButton")
                } header: {
                    Text("Cosigners")
                } footer: {
                    Text(isMuSig2
                         ? "MuSig2 participants are bare key expressions: [fingerprint/path]xpub with no derivation suffix (BIP390)."
                         : "Each cosigner is a key expression like [fingerprint/86'/1'/0']xpub…/<0;1>/*. The vault's internal key is the BIP341 NUMS point — no one can key-path spend around the multisig.")
                }

                if let error {
                    Section { Text(error).foregroundStyle(.red).font(.footnote) }
                }

                Section {
                    Button("Build descriptor") { build() }
                        .accessibilityIdentifier("buildDescriptorButton")
                        .disabled(cosigners.isEmpty)
                }

                if let builtDescriptor, let vault = try? Vault(descriptor: builtDescriptor, network: model.network) {
                    Section("Descriptor") {
                        CopyableTextBlock(text: builtDescriptor.serialized())
                            .accessibilityIdentifier("descriptorBlock")
                    }
                    Section("First address") {
                        if let address = try? vault.address(index: 0) {
                            CopyableTextBlock(text: address)
                        }
                    }
                    Section {
                        Button(saving ? "Saving…" : "Save vault") { save(descriptor: builtDescriptor) }
                            .accessibilityIdentifier("saveVaultButton")
                            .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || saving)
                    }
                }
            }
            .navigationTitle("New \(policyName) vault")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }

    private func addPasted() {
        let text = pasted.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        cosigners.append(text)
        pasted = ""
        builtDescriptor = nil
    }

    private func addOwn() {
        do {
            let expression = try model.ownKeyExpression(multipathSuffix: !isMuSig2)
            guard !cosigners.contains(expression) else { return }
            cosigners.append(expression)
            builtDescriptor = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func build() {
        error = nil
        do {
            let descriptor: Descriptor
            if isMuSig2 {
                descriptor = try Descriptor("tr(musig(\(cosigners.joined(separator: ",")))/<0;1>/*)")
            } else {
                descriptor = try Vault.multiADescriptor(threshold: threshold, cosigners: cosigners)
            }
            _ = try Vault(descriptor: descriptor, network: model.network) // validates the policy shape
            builtDescriptor = descriptor
        } catch {
            builtDescriptor = nil
            self.error = error.localizedDescription
        }
    }

    private func save(descriptor: Descriptor) {
        saving = true
        Task {
            do {
                _ = try await model.addVault(name: name.trimmingCharacters(in: .whitespaces),
                                             descriptor: descriptor)
                dismiss()
            } catch {
                self.error = error.localizedDescription
                saving = false
            }
        }
    }
}
