import WalletCore
import SwiftUI
import UIKit

/// Pick co-owners, choose how many must approve, name it, and then share
/// the savings card before anything else: a co-owner's phone only notices
/// coins from the moment it starts watching, and cannot approve a spend of
/// coins it has not seen.
struct SharedSavingsCreateView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var selected: Set<String> = []
    @State private var threshold = 2
    @State private var name = ""
    @State private var nameEdited = false
    @State private var error: String?
    @State private var creating = false
    @State private var created: VaultRecord?
    @State private var showAddPerson = false

    private var chosen: [PersonRecord] {
        model.people.filter { selected.contains($0.id) }
    }

    private var signerCount: Int { chosen.count + 1 }

    private var defaultName: String {
        chosen.isEmpty ? "Shared savings" : "Savings with " + chosen.map(\.name).joined(separator: ", ")
    }

    private var effectiveName: String {
        let typed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return nameEdited && !typed.isEmpty ? typed : defaultName
    }

    var body: some View {
        NavigationStack {
            Group {
                if let created {
                    SharedSavingsShareView(record: created, afterCreate: true)
                } else {
                    form
                }
            }
            .navigationTitle(created == nil ? "New shared savings" : "Share the savings")
            .sheet(isPresented: $showAddPerson) { AddPersonView(forSigning: true) }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    if created == nil {
                        Button("Cancel") { dismiss() }
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if created != nil {
                        Button("Done") { dismiss() }
                            .accessibilityIdentifier("savingsShareDoneButton")
                    }
                }
            }
        }
    }

    private var form: some View {
        Form {
            Section {
                if model.people.isEmpty {
                    Text("Add each co-owner’s Winnow card, then choose who will share control.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Button("Add a co-owner") { showAddPerson = true }
                    .accessibilityIdentifier("addSavingsCoOwnerButton")
                ForEach(model.people) { person in
                    Button {
                        toggle(person)
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(person.name).foregroundStyle(person.canCoOwnSavings ? Color.primary : Color.secondary)
                                if !person.canCoOwnSavings {
                                    Text("needs a signer key").font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            if selected.contains(person.id) {
                                Image(systemName: "checkmark").foregroundStyle(.tint)
                            }
                        }
                    }
                    .disabled(!person.canCoOwnSavings)
                    .accessibilityIdentifier("coOwnerToggle-\(person.name)")
                }
            } header: {
                Text("Co-owners, with you")
            } footer: {
                Text("You are always a co-owner. Pick at least one person.")
            }

            Section {
                Stepper(value: $threshold, in: 1 ... max(signerCount, 1)) {
                    LabeledContent("How many must approve", value: "\(threshold) of \(signerCount)")
                }
                .accessibilityIdentifier("thresholdStepper")
                .onChange(of: signerCount) { previous, count in
                    threshold = VaultThreshold.reconciled(threshold, previousKeyCount: previous, keyCount: count)
                }
                TextField(defaultName, text: $name)
                    .accessibilityIdentifier("savingsNameField")
                    .onChange(of: name) { _, _ in nameEdited = true }
            } footer: {
                Text("Any \(threshold) of these \(signerCount) keys can approve a payment. \(threshold == 1 ? "One key is enough to spend." : "One key alone is not enough to spend.") Names do not prove that the keys are held by different people.")
            }

            if let error {
                Section { Text(error).foregroundStyle(.red).font(.footnote).accessibilityIdentifier("savingsError") }
            }

            Section {
                Button(creating ? "Creating…" : "Create") { create() }
                    .accessibilityIdentifier("createSharedSavingsButton")
                    .disabled(creating || chosen.isEmpty || model.walletID == nil)
            }
        }
    }

    private func toggle(_ person: PersonRecord) {
        if selected.contains(person.id) { selected.remove(person.id) } else { selected.insert(person.id) }
    }

    private func create() {
        creating = true
        error = nil
        let people = chosen
        let savingsName = effectiveName
        let chosenThreshold = VaultThreshold.clamped(threshold, keyCount: signerCount)
        Task {
            do {
                created = try await model.createSharedSavings(name: savingsName, coOwners: people,
                                                              threshold: chosenThreshold)
            } catch {
                self.error = error.localizedDescription
            }
            creating = false
        }
    }
}

/// The savings card, with the reason it must travel before any money does.
struct SharedSavingsShareView: View {
    let record: VaultRecord
    var afterCreate = false
    @Environment(AppModel.self) private var model

    private var coOwnerNames: String {
        let names = model.sharedSavings.first { $0.id == record.id }?.coOwners.map(\.name) ?? []
        switch names.count {
        case 0: return "your co-owners"
        case 1: return names[0]
        default: return names.dropLast().joined(separator: ", ") + " and " + names.last!
        }
    }

    var body: some View {
        let text = (try? model.sharedSavingsCard(for: record).serialized()) ?? ""
        Form {
            Section {
                Text("Share with \(coOwnerNames) now. Each of them must add these savings on their phone before any money goes in — their phone only notices coins from the moment it starts watching, and it cannot approve a payment of coins it has not seen.")
                    .font(.footnote)
                    .accessibilityIdentifier("savingsShareNotice")
            }
            Section {
                HStack {
                    Spacer()
                    QRCodeView(content: text)
                        .frame(width: 200, height: 200)
                    Spacer()
                }
                CopyableTextBlock(text: text)
                    .accessibilityIdentifier("savingsCardBlock")
            } header: {
                Text(record.name)
            } footer: {
                Text(afterCreate
                     ? "Nothing here is secret; it describes who can approve, not how to spend."
                     : "Anyone with this card can watch the savings' addresses. It cannot spend.")
            }
        }
    }
}

/// Adds savings someone else created, from their card.
struct AddSharedSavingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var pasted = ""
    @State private var error: String?
    @State private var adding = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Paste the savings card", text: $pasted, axis: .vertical)
                        .font(.system(.caption, design: .monospaced))
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .accessibilityIdentifier("savingsCardField")
                    Button("Paste from clipboard") {
                        pasted = UIPasteboard.general.string ?? ""
                    }
                    .accessibilityIdentifier("savingsCardPasteButton")
                } footer: {
                    Text("Winnow starts watching these savings from now. Money sent to them earlier is not seen from this phone.")
                }
                if let error {
                    Section { Text(error).foregroundStyle(.red).font(.footnote).accessibilityIdentifier("savingsError") }
                }
                Section {
                    Button(adding ? "Adding…" : "Add") { add() }
                        .accessibilityIdentifier("addSharedSavingsConfirmButton")
                        .disabled(adding || pasted.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .navigationTitle("Add shared savings")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }

    private func add() {
        adding = true
        error = nil
        Task {
            do {
                try await model.addSharedSavings(card: pasted)
                dismiss()
            } catch {
                self.error = error.localizedDescription
            }
            adding = false
        }
    }
}

/// One shared savings: receive, balance, co-owners, and the two moves.
struct SharedSavingsDetailView: View {
    let recordID: String
    var send: () -> Void
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var showApprove = false
    @State private var showShare = false
    @State private var showSign = false
    @State private var confirmRemove = false

    private var record: VaultRecord? { model.vaults.first { $0.id == recordID } }
    private var savings: AppModel.SharedSavings? { model.sharedSavings.first { $0.id == recordID } }

    var body: some View {
        List {
            if let record, let vault = try? model.vault(for: record) {
                Section("Receive") {
                    if let address = try? vault.address(index: record.nextReceiveIndex) {
                        HStack {
                            Spacer()
                            QRCodeView(content: address)
                                .frame(width: 180, height: 180)
                            Spacer()
                        }
                        CopyableTextBlock(text: address)
                            .accessibilityIdentifier("savingsReceiveAddress")
                        Button("New address") {
                            Task { await model.advanceVaultReceiveIndex(id: record.id) }
                        }
                    }
                }

                Section("Balance · confirmed") {
                    LabeledContent("Total") {
                        // The identifier sits on the value so tests read the
                        // amount, not the row's label.
                        Text(satsText(record.balance))
                            .accessibilityIdentifier("savingsBalance")
                    }
                    if record.utxos.isEmpty {
                        Text("No money in yet. Payments to the address above appear once they confirm in a block.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }

                VaultPolicySection(vault: vault)

                Section {
                    if let savings {
                        Text(([savings.includesYou ? "you" : nil].compactMap { $0 } + savings.coOwners.map(\.name)).joined(separator: ", "))
                            .accessibilityIdentifier("savingsCoOwners")
                    }
                    Button("Share the savings card") { showShare = true }
                        .accessibilityIdentifier("shareSavingsCardButton")
                } header: {
                    Text("Co-owners")
                }

                Section {
                    Button("Send", action: send)
                        .accessibilityIdentifier("sendFromAccountButton")
                        .disabled(record.utxos.isEmpty)
                    Button("Approve a request") { showApprove = true }
                        .accessibilityIdentifier("approveRequestButton")
                } footer: {
                    Text("Send prepares a payment for the co-owners to approve. To approve a payment someone else prepared, open their request.")
                }

                if model.advancedMode {
                    Section("Details for experts") {
                        CopyableTextBlock(text: record.descriptor)
                        ForEach(Array(vault.cosignerExpressions.enumerated()), id: \.offset) { index, expression in
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Signer \(index + 1)").font(.caption).foregroundStyle(.secondary)
                                Text(expression)
                                    .font(.system(.caption2, design: .monospaced))
                                    .textSelection(.enabled)
                            }
                        }
                        Button("Continue signing") { showSign = true }
                    }
                }

                Section {
                    Button("Remove from this phone", role: .destructive) { confirmRemove = true }
                        .accessibilityIdentifier("removeSavingsButton")
                } footer: {
                    Text("Forgets these savings here. The money stays where it is; other co-owners keep their copies, and the card adds it back.")
                }
            } else {
                Text("These savings are no longer on this phone.")
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle(record?.name ?? "Shared savings")
        .sheet(isPresented: $showApprove) { ApprovalView(recordID: recordID) }
        .sheet(isPresented: $showShare) {
            if let record {
                NavigationStack {
                    SharedSavingsShareView(record: record)
                        .navigationTitle("Savings card")
                        .toolbar {
                            ToolbarItem(placement: .confirmationAction) {
                                Button("Done") { showShare = false }
                            }
                        }
                }
            }
        }
        .sheet(isPresented: $showSign) { VaultSignView(recordID: recordID) }
        .confirmationDialog("Remove these savings from this phone?", isPresented: $confirmRemove) {
            Button("Remove", role: .destructive) {
                Task {
                    await model.removeVault(id: recordID)
                    dismiss()
                }
            }
            Button("Cancel", role: .cancel) {}
        }
    }
}
