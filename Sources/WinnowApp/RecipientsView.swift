import WalletCore
import SwiftUI
import UIKit

struct SavedRecipientsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    var choose: (PersonRecord) -> Void
    @State private var adding = false
    @State private var editing: PersonRecord?
    @State private var error: String?

    var body: some View {
        NavigationStack {
            List {
                if let notice = model.peopleStorageNotice ?? error {
                    Text(notice).foregroundStyle(.red).accessibilityIdentifier("recipientError")
                }
                if model.savedRecipients.isEmpty {
                    Text("Save a recipient from a payment in Wallet, or add an address or card here.")
                        .foregroundStyle(.secondary)
                }
                ForEach(model.savedRecipients) { person in
                    Button(person.name) { choose(person); dismiss() }
                        .accessibilityIdentifier("chooseRecipient-\(person.name)")
                        .swipeActions(edge: .leading) {
                            Button("Rename") { editing = person }
                        }
                        .swipeActions {
                            Button("Remove", role: .destructive) { remove(person) }
                        }
                        .contextMenu {
                            Button("Rename") { editing = person }
                            Button("Remove from saved", role: .destructive) { remove(person) }
                        }
                }
            }
            .navigationTitle("Saved recipients")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    Button("Add") { adding = true }
                        .accessibilityIdentifier("addRecipientButton")
                        .disabled(model.peopleStorageNotice != nil)
                }
            }
            .sheet(isPresented: $adding) { AddPersonView() }
            .sheet(item: $editing) { AddPersonView(person: $0) }
        }
    }

    private func remove(_ person: PersonRecord) {
        Task {
            do { try await model.updateRecipient(id: person.id, saved: false) }
            catch { self.error = error.localizedDescription }
        }
    }
}

/// One editor for a saved recipient, a payment's address, or a co-owner's card.
struct AddPersonView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    var person: PersonRecord?
    var forSigning = false
    @State private var name: String
    @State private var pasted: String
    @State private var error: String?
    @State private var saving = false

    init(person: PersonRecord? = nil, address: String = "", forSigning: Bool = false) {
        self.person = person
        self.forSigning = forSigning
        _name = State(initialValue: person?.name ?? "")
        _pasted = State(initialValue: address)
    }

    private var parsed: PersonImport? { try? PersonPaste.parse(pasted, network: model.network) }
    private var effectiveName: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? parsed?.name ?? "" : trimmed
    }
    private var canSave: Bool {
        guard !saving, !effectiveName.isEmpty else { return false }
        if person != nil { return true }
        return forSigning ? parsed?.signerKey != nil : parsed?.payTo != nil
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $name).accessibilityIdentifier("personNameField")
                    if person == nil {
                        TextField(forSigning ? "Paste a card or signer key" : "Paste an address or card",
                                  text: $pasted, axis: .vertical)
                            .autocorrectionDisabled().textInputAutocapitalization(.never)
                            .accessibilityIdentifier("personPasteField")
                        Button("Paste from clipboard") { pasted = UIPasteboard.general.string ?? "" }
                            .accessibilityIdentifier("personPasteButton")
                    }
                }
                if let parsed, person == nil {
                    Section {
                        if let payTo = parsed.payTo {
                            Text(payTo.derivesFreshAddresses ? "Fresh address each payment" : "Uses this same address each time")
                                .accessibilityIdentifier("personPayToSummary")
                        }
                        if forSigning {
                            Text(parsed.signerKey != nil ? "Can approve shared payments" : "Ask for their signer key or Winnow card")
                                .accessibilityIdentifier("personSignerSummary")
                        }
                    }.font(.footnote).foregroundStyle(.secondary)
                }
                if let error { Text(error).foregroundStyle(.red).accessibilityIdentifier("personError") }
                Section {
                    Button(saving ? "Saving…" : "Save") { save() }
                        .accessibilityIdentifier("savePersonButton").disabled(!canSave)
                }
            }
            .navigationTitle(person?.isSavedRecipient == true ? "Rename recipient" : forSigning ? "Add co-owner" : "Save recipient")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
            .onChange(of: pasted) { _, text in
                error = nil
                guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
                do { _ = try PersonPaste.parse(text, network: model.network) }
                catch { self.error = error.localizedDescription }
            }
        }
    }

    private func save() {
        saving = true
        Task {
            defer { saving = false }
            do {
                if let person {
                    try await model.updateRecipient(id: person.id, name: effectiveName, saved: true)
                } else if let parsed {
                    try await model.addPerson(name: effectiveName, payTo: parsed.payTo, signerKey: parsed.signerKey)
                }
                dismiss()
            } catch { self.error = error.localizedDescription }
        }
    }
}

/// This wallet's card: public keys only, plus the name others will see.
struct ShareMyCardView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""

    private var cardText: String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return try? model.ownPersonCard(name: trimmed).serialized()
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Your name, as others will see it", text: $name)
                        .accessibilityIdentifier("ownNameField")
                }
                if let cardText {
                    Section {
                        HStack {
                            Spacer()
                            QRCodeView(content: cardText)
                                .frame(width: 200, height: 200)
                            Spacer()
                        }
                        CopyableTextBlock(text: cardText)
                            .accessibilityIdentifier("ownCardBlock")
                    } header: {
                        Text("Your card")
                    } footer: {
                        Text("This card carries public keys only. Anyone who has it can pay you and can see every address it derives, the same way your wallet does. People who pay you from their address book use the same list of addresses as your Receive screen, so two people paying at once can land on one address — a privacy detail, never a loss.")
                    }
                } else {
                    Section {
                        Text("Add a name to make your card.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Share my card")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .onAppear {
                name = model.ownDisplayName
                model.journalCardShared()
            }
            .onChange(of: name) { _, value in model.setOwnDisplayName(value) }
        }
    }
}
