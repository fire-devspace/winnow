import BitcoinP2P
import SwiftUI

@main
struct WinnowApp: App {
    @State private var model = AppModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            Group {
                switch model.stage {
                case .loading:
                    ProgressView("Opening wallet…")
                case .onboarding:
                    OnboardingView()
                case .ready:
                    MainTabView()
                case let .storageDamaged(message):
                    StorageDamagedView(message: message)
                }
            }
            .environment(model)
            .task { await model.boot() }
            .onChange(of: scenePhase) { _, phase in model.scenePhaseChanged(phase) }
        }
    }
}

struct StorageDamagedView: View {
    let message: String
    @Environment(AppModel.self) private var model

    private var otherNetwork: BitcoinNetwork {
        model.network == .mainnet ? .signet : .mainnet
    }

    var body: some View {
        ContentUnavailableView {
            Label("Wallet data needs attention", systemImage: "externaldrive.badge.exclamationmark")
        } description: {
            Text(message)
        } actions: {
            Button("Retry without changing anything") {
                Task { await model.retryWalletOpen() }
            }
            .buttonStyle(.borderedProminent)
            .accessibilityIdentifier("retryDamagedWalletButton")
            Button("Open the \(otherNetwork.rawValue) wallet instead") {
                Task { await model.switchNetwork(to: otherNetwork) }
            }
            .accessibilityIdentifier("switchFromDamagedWalletButton")
        }
        .padding()
    }
}

/// The four sections of the wallet shell.
struct MainTabView: View {
    private enum Tab: String, Hashable {
        case wallet, send, vaults, settings
    }

    @State private var selection: Tab

    init() {
        let requested = E2EMode.current?.initialTab.flatMap(Tab.init(rawValue:))
        _selection = State(initialValue: requested ?? .wallet)
    }

    var body: some View {
        TabView(selection: $selection) {
            HomeView()
                .tabItem { Label("Wallet", systemImage: "bitcoinsign.circle") }
                .tag(Tab.wallet)
            SendView()
                .tabItem { Label("Send", systemImage: "arrow.up.circle") }
                .tag(Tab.send)
            VaultsView()
                .tabItem { Label("Vaults", systemImage: "lock.shield") }
                .tag(Tab.vaults)
            SettingsView()
                .tabItem { Label("Settings", systemImage: "gear") }
                .tag(Tab.settings)
        }
    }
}
