import BitcoinP2P
import LocalAuthentication
import SwiftUI
import WalletCore

/// Network, manual peers, the opt-in esplora fast path (off by default,
/// behind an explicit warning), and the live peer status list.
struct SettingsView: View {
    @Environment(AppModel.self) private var model

    @State private var newPeer = ""
    @State private var peerError: String?
    @State private var connectedPeers: [PeerInfo] = []
    @State private var showEsploraWarning = false
    @State private var showReadSide = false
    @State private var showPapers = false
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
                } footer: {
                    Text("Each network has its own wallet on this device. Switching opens that network's wallet, or onboarding when it has none.")
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
                    Toggle("Esplora fast path", isOn: Binding(
                        get: { model.esploraEnabled },
                        set: { enabled in
                            if enabled {
                                showEsploraWarning = true
                            } else {
                                model.setEsploraEnabled(false)
                            }
                        }
                    ))
                    .accessibilityIdentifier("esploraToggle")
                    if model.esploraEnabled {
                        TextField("Server URL (empty = public default)", text: Binding(
                            get: { model.esploraURLString },
                            set: { model.setEsploraURL($0) }
                        ))
                        .font(.system(.footnote, design: .monospaced))
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        Text("Active server: \(model.esploraBaseURL.absoluteString)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Button("What this trades away") { showReadSide = true }
                } header: {
                    Text("Server backend (opt-in)")
                } footer: {
                    Text("Off by default. When on, the app queries a server for fee estimates and broadcasts through it too — the default P2P filter sync needs and contacts no server.")
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
            }
            .navigationTitle("Settings")
            .task { await refreshPeers() }
            .alert("Enable the esplora fast path?", isPresented: $showEsploraWarning) {
                Button("Enable — I understand the trade") {
                    model.setEsploraEnabled(true)
                }
                Button("Read the design paper") { showReadSide = true }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("With esplora on, the server sees your IP address and every transaction you broadcast through it, linking the two. It is not asked about your addresses, so your balances and history stay on-device. What you gain today is server fee estimates and a second broadcast path — not mempool-stage visibility; incoming payments still appear only at block confirmation. The default P2P compact-filter sync contacts no server at all.")
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

/// Settings → Backup → Export: emit the v1 ImportBundle JSON (watch-only
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

/// Settings → Backup → Show recovery phrase: the words, read-only, after
/// device authentication. No copy control on purpose — the phrase belongs on
/// paper, not on the pasteboard.
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
