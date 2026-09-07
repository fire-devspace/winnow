import WalletCore
import SwiftUI
import UIKit

/// Immutable identity of the fields that produced a send preview. Equality is
/// the authorization boundary for async preview results: a result created for
/// older text or a different network must never re-enable the signing button.
struct SendReviewInputs: Equatable {
    let destination: String
    let amountText: String
    let priority: FeePolicy.Priority
    let overrideText: String
    let network: BitcoinNetwork
    /// A payment to a person: which one, and the index its fresh address was
    /// derived at, so a review made for an earlier address is never reused.
    var personID: String?
    var paymentIndex: UInt32?

    var trimmedDestination: String {
        destination.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var amount: Int64? { Int64(amountText) }
}

/// Send to any standard address: fee
/// selection (FeePolicy presets + the peers' feefilter floor + override), a
/// review step, then sign + broadcast via TxBroadcaster. Relay status comes
/// from the broadcaster's events; confirmation arrives as a filter match
/// ("seen in block N").
struct SendView: View {
    @Environment(AppModel.self) private var model

    /// Preselected when opened from a person's screen, where the view is a
    /// sheet and needs its own way out.
    init(recipient: PersonRecord? = nil) {
        _selectedPersonID = State(initialValue: recipient?.id)
        presentedAsSheet = recipient != nil
    }

    private let presentedAsSheet: Bool
    @Environment(\.dismiss) private var dismiss
    @State private var selectedPersonID: String?
    @State private var destination = ""
    @State private var amountText = ""
    @State private var priority: FeePolicy.Priority = .medium
    @State private var overrideText = ""
    @State private var resolvedRate: Double?
    @State private var preview: AppModel.SendPreview?
    @State private var error: String?
    @State private var reviewing = false
    @State private var sending = false
    @State private var sentTxid: Data?
    /// Hex of the signed transaction, while it is still pending.
    @State private var rawTransaction: String?
    @State private var relayLog: [String] = []
    @State private var relayedPeers: Set<String> = []
    @State private var feeFloorNotice = false
    @State private var confirmedHeight: UInt32?
    private enum Field { case destination, amount, fee }
    @FocusState private var focusedField: Field?

    private var selectedPerson: PersonRecord? {
        guard let selectedPersonID else { return nil }
        return model.people.first { $0.id == selectedPersonID && $0.payTo != nil }
    }

    private var payablePeople: [PersonRecord] {
        model.people.filter { $0.payTo != nil }
    }

    private var reviewInputs: SendReviewInputs {
        SendReviewInputs(destination: selectedPerson == nil ? destination : "",
                         amountText: amountText,
                         priority: model.advancedMode ? priority : .medium,
                         overrideText: model.advancedMode ? overrideText : "",
                         network: model.network,
                         personID: selectedPerson?.id,
                         paymentIndex: selectedPerson?.nextPaymentIndex)
    }

    private var canReview: Bool {
        guard let amount = Int64(amountText), amount > 0 else { return false }
        if selectedPerson != nil { return true }
        return !destination.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                if let sentTxid {
                    paymentStatus(sentTxid)
                } else if let preview {
                    paymentReview(preview)
                } else {
                    paymentForm
                }
                if let error {
                    Section {
                        Text(error)
                            .foregroundStyle(.red)
                            .font(.footnote)
                            .accessibilityIdentifier("sendError")
                    }
                }
            }
            .disabled(sending)
            // Each step starts at the top, including after editing a long form.
            .id(sentTxid != nil ? "sent" : preview != nil ? "review" : "form")
            .navigationTitle(sentTxid != nil ? "Payment" : preview != nil ? "Review payment" : "Send")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") { focusedField = nil }
                }
                if presentedAsSheet {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Done") { dismiss() }
                            .accessibilityIdentifier("sendSheetDoneButton")
                    }
                }
            }
            .task(id: feeInputs) {
                let inputs = reviewInputs
                resolvedRate = await model.resolvedFeeRate(
                    priority: inputs.priority, override: Double(inputs.overrideText.trimmingCharacters(in: .whitespaces)))
            }
            .task(id: sentTxid) {
                await watchBroadcastEvents()
            }
            .onChange(of: reviewInputs) { _, _ in
                // Edits invalidate authorization, but never rewrite a receipt.
                if sentTxid == nil { preview = nil }
            }
            .onChange(of: model.status.history) { _, history in
                guard let sentTxid, confirmedHeight == nil,
                      let entry = history.first(where: { $0.txid == sentTxid }), entry.height > 0
                else { return }
                confirmedHeight = entry.height
            }
        }
    }

    private var paymentForm: some View {
        Group {
            Section("To") {
                if let person = selectedPerson {
                    HStack {
                        Text(person.name)
                            .accessibilityIdentifier("selectedPersonName")
                        Spacer()
                        Button("Change") { selectedPersonID = nil }
                            .accessibilityIdentifier("changeRecipientButton")
                    }
                } else {
                    HStack {
                        TextField("Bitcoin address", text: $destination)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                            .focused($focusedField, equals: .destination)
                            .accessibilityIdentifier("destinationField")
                        Button("Paste") {
                            destination = UIPasteboard.general.string ?? ""
                        }
                        .accessibilityIdentifier("pasteDestinationButton")
                    }
                    if !payablePeople.isEmpty {
                        Menu("Choose a person") {
                            ForEach(payablePeople) { person in
                                Button(person.name) {
                                    selectedPersonID = person.id
                                    destination = ""
                                }
                                .accessibilityIdentifier("choosePerson-\(person.name)")
                            }
                        }
                        .accessibilityIdentifier("choosePersonMenu")
                    }
                }
            }
            Section {
                HStack {
                    TextField("0", text: $amountText)
                        .keyboardType(.numberPad)
                        .focused($focusedField, equals: .amount)
                        .accessibilityLabel("Amount in sats")
                        .accessibilityIdentifier("amountField")
                    Text("sats").foregroundStyle(.secondary)
                }
            } header: {
                Text("Amount")
            } footer: {
                Text("You'll see the network fee before you send.")
            }
            if model.advancedMode { feeControls }
            Section {
                Button(reviewing ? "Preparing review…" : "Review payment") { review() }
                    .accessibilityIdentifier("reviewButton")
                    .disabled(!canReview || reviewing)
            }
        }
    }

    private var feeControls: some View {
        Section {
            Picker("Priority", selection: $priority) {
                Text("Low").tag(FeePolicy.Priority.low)
                Text("Medium").tag(FeePolicy.Priority.medium)
                Text("High").tag(FeePolicy.Priority.high)
            }
            .accessibilityIdentifier("feePriorityPicker")
            LabeledContent("Resolved rate", value: resolvedRate.map(feeRateText) ?? "—")
            LabeledContent("Network floor", value: model.status.feeFloorSatPerVByte.map(feeRateText) ?? "unknown")
            TextField("Override (sat/vB, optional)", text: $overrideText)
                .keyboardType(.decimalPad)
                .focused($focusedField, equals: .fee)
                .accessibilityIdentifier("feeOverrideField")
        } header: {
            Text("Fee")
        } footer: {
            Text("The rate uses your override, recent confirmed fees, or a preset, never below the peers' relay floor. It is not a live fee-market estimate.")
        }
    }

    private func paymentAmounts(_ preview: AppModel.SendPreview) -> some View {
        Section {
            LabeledContent("Amount", value: satsText(preview.amountSent))
                .accessibilityIdentifier("reviewAmount")
                .accessibilityValue(satsText(preview.amountSent))
            LabeledContent("Network fee", value: satsText(preview.fee))
                .accessibilityIdentifier("reviewFee")
                .accessibilityValue(satsText(preview.fee))
            LabeledContent("Total", value: satsText(preview.amountSent + preview.fee))
                .bold()
                .accessibilityIdentifier("reviewTotal")
                .accessibilityValue(satsText(preview.amountSent + preview.fee))
        }
    }

    private func paymentReview(_ preview: AppModel.SendPreview) -> some View {
        Group {
            Section("To") {
                if let recipient = preview.recipient {
                    Text(recipient.name)
                        .accessibilityIdentifier("reviewRecipient")
                }
                Text(preview.destination)
                    .font(.system(.footnote, design: .monospaced))
                    .textSelection(.enabled)
                    .accessibilityIdentifier("reviewDestination")
            }
            paymentAmounts(preview)
            reviewWarnings(preview)
            Section {
                Button(sending ? "Sending…" : "Send payment") { send() }
                    .accessibilityIdentifier("sendButton")
                    .disabled(sending)
                Button("Edit payment") {
                    self.preview = nil
                    error = nil
                }
                .accessibilityIdentifier("editPaymentButton")
                .disabled(sending)
            }
            if model.advancedMode {
                Section("Transaction details") {
                    LabeledContent("Rate", value: feeRateText(preview.feeRateSatPerVByte))
                    LabeledContent("Inputs", value: "\(preview.inputCount)")
                    if let change = preview.changeAmount {
                        LabeledContent("Change back", value: satsText(change))
                    }
                }
            }
        }
    }

    private func reviewWarnings(_ preview: AppModel.SendPreview) -> some View {
        Group {
            if let recipient = preview.recipient, !recipient.derivesFreshAddresses {
                Section {
                    Label("This address has been saved for reuse. Repeated payments can be linked. Ask \(recipient.name) for a fresh address or Winnow contact card.", systemImage: "eye")
                        .accessibilityIdentifier("addressReuseWarning")
                }
            }
            if let proportion = preview.feeProportion {
                Section {
                    Label(proportion.message(sats: satsText), systemImage: "exclamationmark.triangle")
                        .accessibilityIdentifier("feeProportionWarning")
                }
            }
            if preview.locktimeLagsTip {
                Section {
                    Label("Your wallet is still syncing. Sending now can reveal that on the Bitcoin network. Wait for sync to finish for better privacy.", systemImage: "clock.arrow.circlepath")
                        .accessibilityIdentifier("locktimeLagWarning")
                }
            }
        }
        .font(.footnote)
        .foregroundStyle(.orange)
    }

    private func paymentStatus(_ txid: Data) -> some View {
        Group {
            Section {
                if confirmedHeight != nil {
                    Label("Payment confirmed", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .accessibilityIdentifier("broadcastConfirmed")
                } else {
                    Label("Waiting for confirmation", systemImage: "clock")
                        .accessibilityIdentifier("broadcastPending")
                    Text("You can leave this screen. Follow this payment in Wallet.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                if feeFloorNotice {
                    Label("The network now requires a higher fee. This payment may be delayed. Advanced mode lets you raise its fee in Wallet.", systemImage: "exclamationmark.triangle")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                        .accessibilityIdentifier("feeFloorNotice")
                }
            }
            if let preview { paymentAmounts(preview) }
            Section {
                Button("New payment") { reset() }
                    .accessibilityIdentifier("newPaymentButton")
            }
            Section {
                DisclosureGroup("Transaction details") {
                    CopyableIdentifier(value: txid.displayHex,
                                       accessibilityID: "copyBroadcastTransactionIDButton")
                    // Keep signed bytes available if peer relay fails.
                    if let rawTransaction, confirmedHeight == nil {
                        CopyableIdentifier(value: rawTransaction, abbreviated: true,
                                           label: "Copy raw transaction",
                                           accessibilityID: "copyRawTransactionButton")
                    }
                    WarnedExplorerLink(
                        title: "View transaction",
                        url: model.esploraTransactionURL(txid),
                        exposedItem: "transaction ID",
                        accessibilityID: "explorerBroadcastButton")
                    if !relayedPeers.isEmpty {
                        Text("Relayed to \(relayedPeers.count) peer(s)")
                            .accessibilityIdentifier("relayedCount")
                    }
                    ForEach(Array(relayLog.enumerated()), id: \.offset) { _, line in
                        Text(line).font(.footnote)
                    }
                    if let confirmedHeight {
                        LabeledContent("Block", value: "\(confirmedHeight)")
                    }
                }
                .accessibilityIdentifier("transactionDetailsDisclosure")
            }
        }
    }

    private var feeInputs: String {
        "\(reviewInputs.priority.rawValue)|\(reviewInputs.overrideText)|\(model.status.feeFloorSatPerVByte ?? -1)"
    }

    private func review() {
        guard !reviewing else { return }
        focusedField = nil
        error = nil
        preview = nil
        let requested = reviewInputs
        guard let amount = requested.amount, amount > 0 else {
            error = "Enter an amount in sats."
            return
        }
        let person = selectedPerson
        reviewing = true
        Task {
            defer { reviewing = false }
            do {
                let override = Double(requested.overrideText.trimmingCharacters(in: .whitespaces))
                let candidate = if let person {
                    try await model.previewSend(to: person, amount: amount,
                                                priority: requested.priority, override: override)
                } else {
                    try await model.previewSend(
                        destination: requested.destination, amount: amount,
                        priority: requested.priority, override: override)
                }
                guard requested == reviewInputs else { return }
                preview = candidate
            } catch {
                guard requested == reviewInputs else { return }
                self.error = error.localizedDescription
            }
        }
    }

    private func send() {
        // The button is disabled while `sending`, but that is presentation:
        // it does not survive a double tap delivered before the disabled
        // state renders. AppModel.exclusively is the real guarantee; this
        // check just keeps an accidental second tap from surfacing an error
        // banner instead of doing nothing.
        guard let preview, !sending else { return }
        sending = true
        error = nil
        Task {
            do {
                let txid = try await model.send(preview: preview)
                sentTxid = txid
                // Paying a person advances their address index during send().
                // Keep the authorized snapshot as the receipt after that edit.
                self.preview = preview
                rawTransaction = await model.rawTransactionHex(txid)
            } catch {
                self.error = error.localizedDescription
            }
            sending = false
        }
    }

    private func reset() {
        destination = ""
        selectedPersonID = nil
        amountText = ""
        preview = nil
        sentTxid = nil
        rawTransaction = nil
        relayLog = []
        relayedPeers = []
        feeFloorNotice = false
        confirmedHeight = nil
        error = nil
    }

    /// Follows the broadcast: TxBroadcaster events (announced → a peer asked
    /// for the tx) plus mempool-window echoes (§2.8 — a peer inv'ing our txid
    /// back proves the network has it), until the filter match confirms it.
    /// The window is bounded by this send-status view.
    private func watchBroadcastEvents() async {
        guard let sentTxid, let broadcaster = model.stack?.broadcaster else { return }
        let window = model.makeMempoolWindow(watchScripts: [])
        if let window {
            await window.watchEcho(of: sentTxid)
            await window.start()
        }
        let echoTask = window.map { window in
            Task {
                for await event in await window.events() {
                    guard case let .txidEchoed(txid, peer) = event, txid == sentTxid else { continue }
                    relayedPeers.insert(peer.description)
                }
            }
        }
        for await event in await broadcaster.events() {
            if apply(event, sentTxid: sentTxid, window: window, echoTask: echoTask) {
                break
            }
        }
        echoTask?.cancel()
        await window?.stop()
    }

    /// Applies one broadcaster event to the send screen's relay narrative.
    /// Returns true when propagation tracking is finished (confirmation).
    private func apply(_ event: TxBroadcaster.Event, sentTxid: Data,
                       window: MempoolWindow?, echoTask: Task<Void, Never>?) -> Bool {
            switch event {
            case let .announced(txid, peerCount) where txid == sentTxid:
                relayLog.append("Announced to \(peerCount) peer(s)")
            case let .requested(txid, peer) where txid == sentTxid:
                if relayedPeers.insert(peer.description).inserted {
                    relayLog.append("Relayed to \(peer)")
                }
            case let .feeFloorExceeded(txid, _) where txid == sentTxid:
                feeFloorNotice = true
            case let .confirmed(txid) where txid == sentTxid:
                // The history snapshot here can still hold the pending
                // (height 0) entry — the post-sync refresh lands the real
                // height, and the onChange below then fills it in.
                if let height = model.status.history.first(where: { $0.txid == txid })?.height,
                   height > 0 {
                    confirmedHeight = height
                }
                // Propagation tracking ends at confirmation.
                echoTask?.cancel()
                if let window { Task { await window.stop() } }
                return true
            default:
                break
            }
        return false
    }
}
