import BitcoinP2P
import LocalAuthentication
import SwiftUI
import WalletCore

/// Network, manual peers, warned external explorer links, experimental silent
/// payments, and the live peer status list.
struct SettingsView: View {
    @Environment(AppModel.self) private var model

    @State private var newPeer = ""
    @State private var peerError: String?
    @State private var connectedPeers: [PeerInfo] = []
    @State private var showSilentPaymentsWarning = false
    @State private var showReadSide = false
    @State private var showPapers = false
    @State private var showDestroyWallet = false
    @State private var destroyError: String?
    @State private var showExport = false
    @State private var revealedMnemonic: String?
    @State private var revealError: String?
    @State private var revealing = false

    struct PeerInfo: Equatable, Identifiable {
        var id: String { endpoint }
        let endpoint: String
        let userAgent: String
        let startHeight: Int32
        /// BIP133 feefilter (sat/kvB).
        let feeFilter: Int64?
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Network", selection: Binding(
                        get: { model.network },
                        set: { newValue in Task { await model.switchNetwork(to: newValue) } }
                    )) {
                        Text("Signet").tag(BitcoinNetwork.signet)
                        Text("Mainnet").tag(BitcoinNetwork.mainnet)
                    }
                    .disabled(model.e2e?.forcedNetwork != nil)
                } footer: {
                    if model.e2e?.forcedNetwork != nil {
                        Text("This reproducible story run is locked to public signet.")
                    } else {
                        Text("Each network has its own wallet on this device. Switching opens that network's wallet, or onboarding when it has none.")
                    }
                }

                Section {
                    Button("Export wallet bundle") { showExport = true }
                        .disabled(model.walletID == nil)
                        .accessibilityIdentifier("exportBundleButton")
                    Button("Show recovery phrase") { reveal() }
                        .disabled(model.walletID == nil || revealing)
                        .accessibilityIdentifier("revealPhraseButton")
                    if let revealError {
                        Text(revealError).foregroundStyle(.red).font(.footnote)
                    }
                } header: {
                    Text("Backup")
                } footer: {
                    Text("The bundle is the history. A new phone cannot recover this wallet from the 12 words alone — export this file and keep it with the words. Showing the phrase asks for device authentication first.")
                }

                Section {
                    ForEach(model.manualPeers, id: \.self) { peer in
                        Text(peer).font(.system(.footnote, design: .monospaced))
                    }
                    .onDelete { model.removeManualPeers(at: $0) }
                    HStack {
                        TextField("host:port", text: $newPeer)
                            .font(.system(.footnote, design: .monospaced))
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                        Button("Add") { addPeer() }
                            .disabled(newPeer.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                    if let peerError {
                        Text(peerError).foregroundStyle(.red).font(.footnote)
                    }
                    Button("Reconnect peers") {
                        Task { await model.reconnect() }
                    }
                } header: {
                    Text("Manual peers")
                } footer: {
                    Text("Manual peers are tried before DNS seeds. Seeds resolve over HTTPS (Cloudflare 1.1.1.1), then system DNS. The default port is 8333 (mainnet) / 38333 (signet). Peers must serve BIP157 compact filters.")
                }

                Section {
                    TextField("Explorer website URL (empty = mempool.space)", text: Binding(
                        get: { model.esploraURLString },
                        set: { model.setEsploraURL($0) }
                    ))
                    .font(.system(.footnote, design: .monospaced))
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .accessibilityIdentifier("esploraURLField")
                    Text("Selected: \(model.esploraBaseURL.absoluteString)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("What this trades away") { showReadSide = true }
                } header: {
                    Text("External block explorer")
                } footer: {
                    Text("This is a link destination only. Winnow never contacts it for balances, history, fees, synchronization, or broadcasting. Tapping an address or transaction shows a privacy warning before opening the selected website. You may enter a custom Esplora-compatible website.")
                }

                Section {
                    Toggle("Receive silent payments", isOn: Binding(
                        get: { model.spReceiveEnabled },
                        set: { enabled in
                            if enabled {
                                showSilentPaymentsWarning = true
                            } else {
                                model.setSilentPaymentsEnabled(false)
                            }
                        }
                    ))
                    .accessibilityIdentifier("spReceiveToggle")
                    if model.spReceiveEnabled {
                        TextField("Tweak-index server URL (required)", text: Binding(
                            get: { model.spIndexURLString },
                            set: { model.setSilentPaymentIndexURL($0) }
                        ))
                        .font(.system(.footnote, design: .monospaced))
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        if model.spIndexBaseURL == nil {
                            Text("Sync pauses until a server URL is set.")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                    }
                } header: {
                    Text("Experimental · Silent payments")
                } footer: {
                    Text("Experimental and off by default. Sending works without a service. Receiving currently needs per-block tweak data from a service you choose; ordinary Bitcoin compact-filter peers do not yet serve it. Matching and block verification remain on this device, but omitted tweak data can make Winnow miss a payment.")
                }

                Section {
                    Toggle("Verify the chain from genesis", isOn: Binding(
                        get: { model.verifyFromGenesis },
                        set: { enabled in Task { await model.setVerifyFromGenesis(enabled) } }
                    ))
                    .accessibilityIdentifier("verifyFromGenesisToggle")
                    if model.verifyFromGenesis {
                        Text("Turning this off later keeps the chain you already verified.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Chain verification")
                } footer: {
                    Text("Winnow normally starts from a block header built into the app, then verifies every block after it. That header was produced by syncing this same code from block 0, and anyone can reproduce it — but on your phone it begins as a value you are taking from us rather than one you computed. Turn this on to skip it and re-derive the entire chain from block 0 instead. It downloads and proof-of-work-checks every header ever mined, which takes several minutes and discards the headers already stored.")
                }

                Section("Connected peers") {
                    ForEach(connectedPeers) { peer in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(peer.endpoint)
                                .font(.system(.footnote, design: .monospaced))
                                .accessibilityIdentifier("peerEndpoint")
                            Text("\(peer.userAgent) · height \(peer.startHeight)"
                                + (peer.feeFilter.map { " · floor \($0) sat/kvB" } ?? ""))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    if connectedPeers.isEmpty {
                        Text("No peers connected.").font(.footnote).foregroundStyle(.secondary)
                    }
                    Button("Refresh") { Task { await refreshPeers() } }
                        .accessibilityIdentifier("refreshPeersButton")
                }


                Section("About") {
                    LabeledContent("WalletCore", value: WalletCore.version)
                    LabeledContent("BitcoinP2P", value: BitcoinP2P.version)
                    LabeledContent("Wallet ID", value: model.walletID ?? "—")
                    Button("Design papers") { showPapers = true }
                }

                if model.walletID != nil {
                    Section {
                        Button("Delete wallet from this device", role: .destructive) {
                            showDestroyWallet = true
                        }
                        .accessibilityIdentifier("deleteWalletButton")
                    } header: {
                        Text("Danger zone")
                    } footer: {
                        Text("Removes this \(model.network.rawValue) wallet and its vaults so you can create or import another. The key is deleted from this device — without your recovery phrase the money is gone. Block headers are kept, so the next wallet does not re-sync the chain.")
                    }
                }
            }
            .navigationTitle("Settings")
            .task { await refreshPeers() }
            .alert("Delete this wallet?", isPresented: $showDestroyWallet) {
                Button("Delete wallet", role: .destructive) {
                    Task {
                        do { try await model.destroyWallet() }
                        catch { destroyError = error.localizedDescription }
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This deletes the key from this device. Anyone holding the recovery phrase can still restore it; without that phrase, any money in this wallet is unrecoverable. Check you have the phrase written down before continuing.")
            }
            .alert("Could not delete the wallet",
                   isPresented: Binding(get: { destroyError != nil },
                                        set: { if !$0 { destroyError = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(destroyError ?? "")
            }
            .alert("Enable experimental silent-payment receive?", isPresented: $showSilentPaymentsWarning) {
                Button("Enable experimental receive") {
                    model.setSilentPaymentsEnabled(true)
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This feature is experimental. The tweak-data service sees your IP following silent-payment blocks, though it does not receive your address or balance. Matching stays on this device. Scanning is forward-only: payments sent while this is off are not detected. An unavailable service pauses sync; a service that omits data can cause a missed payment.")
            }
            .sheet(isPresented: $showReadSide) {
                ReadSideDocumentView()
            }
            .sheet(isPresented: $showPapers) {
                DesignPapersView()
            }
            .sheet(item: revealedItem) { words in
                RevealPhraseView(mnemonic: words.text)
            }
            .sheet(isPresented: $showExport) {
                ExportBundleView()
            }
        }
    }

    private struct RevealedItem: Identifiable {
        var id: String { text }
        let text: String
    }

    /// Bridges the optional revealed mnemonic to an Identifiable sheet item.
    private var revealedItem: Binding<RevealedItem?> {
        Binding(
            get: { revealedMnemonic.map(RevealedItem.init) },
            set: { revealedMnemonic = $0?.text }
        )
    }

    private func reveal() {
        revealing = true
        revealError = nil
        Task {
            do {
                revealedMnemonic = try await model.revealMnemonic()
            } catch let error as LAError where error.code == .userCancel {
                // Cancelling the auth prompt is a decision, not a failure.
            } catch {
                revealError = error.localizedDescription
            }
            revealing = false
        }
    }

    private func addPeer() {
        do {
            try model.addManualPeer(newPeer)
            newPeer = ""
            peerError = nil
        } catch {
            peerError = error.localizedDescription
        }
    }

    private func refreshPeers() async {
        guard let pool = model.stack?.pool else {
            connectedPeers = []
            return
        }
        var infos: [PeerInfo] = []
        for peer in await pool.connectedPeers() {
            infos.append(PeerInfo(endpoint: await peer.endpoint.description,
                                  userAgent: await peer.peerUserAgent,
                                  startHeight: await peer.peerStartHeight,
                                  feeFilter: await peer.feeFilter))
        }
        connectedPeers = infos
    }
}

/// Settings → Backup → Export: emit the v2 ImportBundle JSON (watch-only
/// by default; seed behind an explicit confirm).
private struct ExportBundleView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var includeMnemonic = false
    @State private var confirmSeed = false
    @State private var json: String?
    @State private var fileURL: URL?
    @State private var error: String?
    @State private var busy = false
    @State private var staging = ExportStagingFile()

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("Include recovery phrase", isOn: $includeMnemonic)
                        .accessibilityIdentifier("exportIncludeMnemonicToggle")
                        .onChange(of: includeMnemonic) { _, _ in
                            resetExport()
                        }
                    if includeMnemonic {
                        Text("A bundle with the seed is a hot backup. Anyone who has the file can spend. Share it the same way you would share the words — not through iCloud or a chat.")
                            .foregroundStyle(.orange)
                            .font(.footnote)
                    }
                } footer: {
                    Text("Off by default. Without the phrase the bundle restores history and the descriptor, not the ability to spend.")
                }
                if let error {
                    Section { Text(error).foregroundStyle(.red).font(.footnote) }
                }
                if let json {
                    Section("Bundle") {
                        CopyableTextBlock(text: includeMnemonic
                                          ? ImportBundle.redactedPreview(json) : json)
                        if includeMnemonic {
                            Text("The recovery phrase is in the shared file, not shown here.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        if let fileURL {
                            ShareLink("Share \(fileURL.lastPathComponent)", item: fileURL)
                                .accessibilityIdentifier("exportShareLink")
                        }
                    }
                } else {
                    Section {
                        Button(includeMnemonic ? "Export with recovery phrase" : "Export watch-only bundle") {
                            if includeMnemonic {
                                confirmSeed = true
                            } else {
                                export()
                            }
                        }
                        .disabled(busy)
                        .accessibilityIdentifier("exportConfirmButton")
                    }
                }
            }
            .navigationTitle("Export wallet")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") {
                        staging.remove()
                        dismiss()
                    }
                }
            }
            .alert("Include the recovery phrase?", isPresented: $confirmSeed) {
                Button("Export with phrase", role: .destructive) { export() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("The file will contain the 12 words. Treat it as cash.")
            }
            .onDisappear { staging.remove() }
        }
    }

    private func resetExport() {
        json = nil
        fileURL = nil
        error = nil
        staging.remove()
    }

    private func export() {
        busy = true
        error = nil
        Task {
            do {
                let text = try await model.exportWalletBundle(includeMnemonic: includeMnemonic)
                let name = "winnow-\(model.network.rawValue)-\(model.walletID ?? "wallet").json"
                let url = try staging.write(text, suggestedName: name)
                json = text
                fileURL = url
            } catch {
                staging.remove()
                fileURL = nil
                json = nil
                self.error = error.localizedDescription
            }
            busy = false
        }
    }
}

/// Settings → Backup → Show recovery phrase: the words and an explicit,
/// short-lived copy control, available only after device authentication.
private struct RevealPhraseView: View {
    let mnemonic: String
    @Environment(\.dismiss) private var dismiss

    private var words: [String] { mnemonic.split(separator: " ").map(String.init) }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                        ForEach(Array(words.enumerated()), id: \.offset) { index, word in
                            Text("\(index + 1). \(word)")
                                .font(.system(.body, design: .monospaced))
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .accessibilityIdentifier("revealedPhraseGrid")
                } footer: {
                    Text("These words are the wallet. Anyone who sees them can spend — keep them offline, on paper, and close this screen when done.")
                }
                Section {
                    RecoveryPhraseCopyButton(
                        phrase: mnemonic, accessibilityID: "settingsCopyPhraseButton")
                } footer: {
                    Text("Copying is less private than paper. The clipboard item stays on this device and expires after two minutes.")
                }
            }
            .navigationTitle("Recovery phrase")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
    }
}
