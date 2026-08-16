import BitcoinP2P
import SwiftUI
import WalletCore

/// Balance (confirmed sats), sync status, and the local transaction history.
/// History speaks in confirmed blocks only — a pending send we broadcast is
/// labeled "awaiting confirmation", never "incoming" (docs/read-side.md §3.3).
struct HomeView: View {
    @Environment(AppModel.self) private var model
    @State private var showReceive = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Balance · confirmed")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Text(satsText(model.status.balance))
                            .font(.system(.largeTitle, design: .rounded).bold())
                            .accessibilityIdentifier("balanceText")
                            .accessibilityValue(satsText(model.status.balance))
                        Text("\(model.status.utxoCount) UTXO(s)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                }

                Section("Sync") {
                    if let statusText = model.syncStatusText {
                        if case .peerDiscoveryFailed = model.syncPhase {
                            Text(statusText)
                                .font(.footnote)
                                .foregroundStyle(.red)
                            Button("Retry") {
                                Task { await model.retryPeerDiscovery() }
                            }
                            .accessibilityIdentifier("retryPeersButton")
                        } else {
                            ProgressView(statusText)
                                .accessibilityIdentifier("syncProgressText")
                        }
                    }
                    // nextScanHeight is the NEXT block to scan, so a fully
                    // scanned tip reads "tip+1 of tip" — clamp the display.
                    LabeledContent("Filter scan",
                                   value: "block \(min(model.status.nextScanHeight, model.status.tipHeight)) of \(model.status.tipHeight)")
                    LabeledContent("Peers", value: "\(model.status.peerCount)")
                    if model.status.syncing, model.syncStatusText == nil {
                        ProgressView("Scanning filters…")
                    }
                    if let error = model.status.lastSyncError {
                        Text(error)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                    Button("Sync now") {
                        Task { await model.syncNow() }
                    }
                    .accessibilityIdentifier("syncNowButton")
                    .disabled(model.status.syncing)
                }

                Section("Transactions") {
                    if model.status.history.isEmpty {
                        Text("No transactions yet. Payments appear here once they confirm in a block.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(Array(model.status.history.enumerated()), id: \.offset) { _, entry in
                        HistoryRow(entry: entry)
                    }
                }
            }
            .navigationTitle("btc-swift")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button("Receive") { showReceive = true }
                        .accessibilityIdentifier("receiveButton")
                }
            }
            .sheet(isPresented: $showReceive) {
                ReceiveView()
            }
            .refreshable {
                await model.syncNow()
            }
        }
    }
}

private struct HistoryRow: View {
    let entry: HistoryEntry

    /// Net effect on the wallet: received (incl. our own change) minus spent.
    private var net: Int64 { entry.received - entry.spent }

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(net >= 0 ? "Received" : "Sent")
                    .font(.headline)
                Text(entry.txid.displayHex.prefix(16) + "…")
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text("\(net >= 0 ? "+" : "−")\(abs(net).formatted()) sats")
                    .foregroundStyle(net >= 0 ? .green : .primary)
                if entry.height > 0 {
                    Text("block \(entry.height)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("awaiting confirmation")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                if let fee = entry.fee {
                    Text("fee \(fee.formatted()) sats")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}
