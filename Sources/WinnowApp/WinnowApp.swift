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
                }
            }
            .environment(model)
            .task { await model.boot() }
            .onChange(of: scenePhase) { _, phase in model.scenePhaseChanged(phase) }
        }
    }
}

/// The four sections of the wallet shell.
struct MainTabView: View {
    var body: some View {
        TabView {
            HomeView()
                .tabItem { Label("Wallet", systemImage: "bitcoinsign.circle") }
            SendView()
                .tabItem { Label("Send", systemImage: "arrow.up.circle") }
            VaultsView()
                .tabItem { Label("Vaults", systemImage: "lock.shield") }
            SettingsView()
                .tabItem { Label("Settings", systemImage: "gear") }
        }
    }
}
