import BitcoinP2P
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
                    Text("Manual peers are tried before DNS seeds. The default port is 8333 (mainnet) / 38333 (signet). Peers must serve BIP157 compact filters.")
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
