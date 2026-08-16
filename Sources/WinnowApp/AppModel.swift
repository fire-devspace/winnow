import BitcoinCore
import BitcoinP2P
import BlockchainBackend
import Foundation
import LocalAuthentication
import SwiftUI
import UIKit
import WalletCore

/// The one app model: owns the wallet, the P2P sync stack and the vault
/// store, and drives sync-while-active (docs/read-side.md: the read path is
/// BIP157/158 compact filters over P2P; nothing runs in the background, so
/// the app requests no background modes).
@MainActor
@Observable
final class AppModel {
    enum Stage: Equatable {
        case loading
        case onboarding
        case ready
    }

    enum AppError: LocalizedError {
        case noWallet
        case noStack
        case noPeers
        case mnemonicUnavailable
        case invalidPeer(String)
        case wrongNetwork(String)
        case duplicateVault
        case deviceAuthUnavailable
        case deviceAuthFailed

        var errorDescription: String? {
            switch self {
            case .noWallet: "No wallet is open."
            case .noStack: "The sync stack is not running."
            case .noPeers: "No peers reachable. Check the network connection or add a manual peer in Settings."
            case .mnemonicUnavailable: "The new wallet's mnemonic could not be read back from the Keychain."
            case let .invalidPeer(text): "Invalid peer “\(text)” — use host:port."
            case let .wrongNetwork(network): "This bundle is for \(network); switch the network in Settings first."
            case .duplicateVault: "A vault with this descriptor already exists."
            case .deviceAuthUnavailable: "Set a device passcode first — the recovery phrase only shows after device authentication."
            case .deviceAuthFailed: "Device authentication failed."
            }
        }
    }

    /// UI-facing snapshot of wallet + sync state (refreshed after syncs and
    /// mutations; the wallet itself is an actor).
    struct Status: Equatable {
        var balance: Int64 = 0
        var utxoCount = 0
        var history: [HistoryEntry] = []
        var observedFeeRates: [Double] = []
        var peerCount = 0
        var tipHeight: UInt32 = 0
        var nextScanHeight: UInt32 = 0
        var syncing = false
        var lastSyncError: String?
        /// BIP133 feefilter floor across connected peers (sat/vB).
        var feeFloorSatPerVByte: Double?
    }

    /// The per-network backend stack: peer pool, header chain, filter sync
    /// (created once a wallet exists — its start height is the wallet's) and
    /// the transaction broadcaster.
    struct SyncStack {
        let pool: PeerPool
        let chain: HeaderChain
        var filters: FilterSync?
        let broadcaster: TxBroadcaster
    }

    /// Coarse-grained live sync phase for the UI (polled from the actors once
    /// a second while active; drives the status line in Home/Onboarding).
    enum SyncPhase: Equatable {
        case idle
        case connecting(connected: Int, target: Int)
        case headers(synced: UInt32, tipEstimate: UInt32)
        case filters(scanned: UInt32, tip: UInt32)
        case synced
        /// Peer discovery ran out of candidates with zero connections.
        case peerDiscoveryFailed
    }

    /// One-line rendering of `syncPhase`; nil when there is nothing to show.
    var syncStatusText: String? {
        switch syncPhase {
        case .idle, .synced:
            nil
        case let .connecting(connected, target):
            "Connecting to peers (\(connected) of \(target))…"
        case let .headers(synced, tipEstimate):
            "Headers \(synced.formatted()) of ~\(tipEstimate.formatted())"
        case let .filters(scanned, tip):
            "Filters \(min(scanned, tip).formatted()) of \(tip.formatted())"
        case .peerDiscoveryFailed:
            "Couldn't find filter-serving peers — check your connection."
        }
    }

    /// Opens a bounded mempool window (docs/read-side.md §2.8) on the pool.
    /// The caller owns the lifecycle: `start()` when the screen appears,
    /// `stop()` when it disappears or the app backgrounds. nil without a stack.
    func makeMempoolWindow(watchScripts: Set<Data>) -> MempoolWindow? {
        guard let stack else { return nil }
        return MempoolWindow(pool: stack.pool, watchScripts: watchScripts)
    }

    private(set) var stage: Stage = .loading
    private(set) var status = Status()
    private(set) var syncPhase: SyncPhase = .idle
    private(set) var vaults: [VaultRecord] = []
    private(set) var wallet: Wallet?
    private(set) var stack: SyncStack?
    /// Copies of the wallet's id/descriptor for synchronous access (the Wallet
    /// actor's members need an await across the module boundary).
    private(set) var walletID: String?
    private var walletDescriptor: Descriptor?

    /// Secrets (the BIP39 mnemonic) live in the Keychain, this device only.
    /// E2E test mode (E2EMode) uses a separate Keychain service so test runs
    /// never touch a real wallet's secrets.
    let keyStore: any KeyStore
    let vaultStore = VaultStore()

    /// Non-nil only when launched with WINNOW_E2E=1 (XCUITest runs).
    let e2e: E2EMode?

    // Settings (UserDefaults-persisted; see the mutating methods below).
    private(set) var network: BitcoinNetwork
    private(set) var manualPeers: [String] // "host:port"
    private(set) var esploraEnabled: Bool
    private(set) var esploraURLString: String

    private var syncTask: Task<Void, Never>?
    private var phaseTask: Task<Void, Never>?
    private var esploraEstimates: [Int: Double]?
    private var isActive = false

    private enum DefaultsKey {
        static let network = "network"
        static let manualPeers = "manualPeers"
        static let esploraEnabled = "esploraEnabled"
        static let esploraURL = "esploraURL"
        /// Set at wallet creation, cleared only by the backup sheet's
        /// confirmed Done — a relaunch in between resumes the backup.
        static func backupPending(_ walletID: String) -> String { "backupPending.\(walletID)" }
    }

    init() {
        let e2e = E2EMode.current
        self.e2e = e2e
        e2e?.wipeIfRequested()
        keyStore = e2e != nil ? KeychainStore(service: E2EMode.keychainService) : KeychainStore()
        let defaults = UserDefaults.standard
        network = BitcoinNetwork(rawValue: defaults.string(forKey: DefaultsKey.network) ?? "") ?? .signet
        manualPeers = defaults.stringArray(forKey: DefaultsKey.manualPeers) ?? []
        esploraEnabled = defaults.bool(forKey: DefaultsKey.esploraEnabled)
        esploraURLString = defaults.string(forKey: DefaultsKey.esploraURL) ?? ""
        // Test mode preconfigures the local node as the (only) manual peer;
        // custom signets have no DNS seeds.
        if let peer = e2e?.peer, !manualPeers.contains(peer) {
            manualPeers = [peer]
            defaults.set(manualPeers, forKey: DefaultsKey.manualPeers)
        }
    }

    // MARK: - Lifecycle

    /// Opens the persisted wallet for the current network, if any.
    func boot() async {
        guard stage == .loading else { return }
        if let clipboard = e2e?.clipboard {
            UIPasteboard.general.string = clipboard
        }
        await vaultStore.configure(storageURL: vaultsURL())
        if let walletURL = walletURL(), let wallet = try? Wallet.open(storageURL: walletURL, keyStore: keyStore) {
            self.wallet = wallet
            walletID = await wallet.id
            walletDescriptor = await wallet.descriptor
            // A wallet whose backup was never confirmed re-enters onboarding:
            // the backup sheet resumes from the Keychain (#5).
            stage = pendingBackupMnemonic() == nil ? .ready : .onboarding
        } else {
            stage = .onboarding
        }
        await refresh()
    }

    /// Sync-while-active: the stack runs only while the scene is foreground.
    func scenePhaseChanged(_ phase: ScenePhase) {
        switch phase {
        case .active:
            isActive = true
            Task { await activate() }
        case .background:
            isActive = false
            syncTask?.cancel()
            syncTask = nil
            phaseTask?.cancel()
            phaseTask = nil
            Task { await stack?.pool.stop() }
        default:
            break // .inactive: still foreground — keep syncing
        }
    }

    private func activate() async {
        await buildStackIfNeeded()
        startPhasePolling()
        await stack?.pool.start()
        startSyncLoop()
    }

    /// Retries peer discovery after the pool reported exhaustion (the UI's
    /// Retry button). Rebuilds the stack when it never came up.
    func retryPeerDiscovery() async {
        if let stack {
            await stack.pool.retry()
        } else {
            await activate()
        }
        await refresh()
    }

    /// Polls the sync actors once a second so the UI can show live
    /// connecting/headers/filters progress instead of a bare spinner.
    private func startPhasePolling() {
        guard phaseTask == nil else { return }
        phaseTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.updateSyncPhase()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private func updateSyncPhase() async {
        guard let stack else {
            if syncPhase != .idle { syncPhase = .idle }
            return
        }
        let connection = await stack.pool.connectionStatus
        if connection.connected == 0 {
            // No peers at all: still dialing, or the round ran dry.
            syncPhase = connection.exhausted
                ? .peerDiscoveryFailed
                : .connecting(connected: 0, target: connection.target)
            return
        }
        if connection.connected < connection.target, connection.dialing {
            syncPhase = .connecting(connected: connection.connected, target: connection.target)
            return
        }
        // At least one peer: one is enough to sync — show the real progress.
        let tip = await stack.chain.height
        var estimate = tip
        for peer in await stack.pool.connectedPeers() {
            let advertised = await peer.peerStartHeight
            if advertised > 0, UInt32(advertised) > estimate { estimate = UInt32(advertised) }
        }
        if estimate > tip + 1 {
            syncPhase = .headers(synced: tip, tipEstimate: estimate)
        } else if let filters = stack.filters {
            let next = await filters.nextScanHeight
            syncPhase = next > tip ? .synced : .filters(scanned: next, tip: tip)
        } else {
            syncPhase = .synced
        }
    }

    private func buildStackIfNeeded() async {
        guard stack == nil, let dir = storageDirectory() else { return }
        do {
            let params = e2e?.networkParams ?? NetworkParams.params(for: network)
            // relayPreference: peers inv us relayed transactions so bounded
            // mempool windows (§2.8) can open on live connections without a
            // reconnect. With no window open the invs are dropped unanswered —
            // the window bounds the expensive part (getdata of every tx).
            let pool = PeerPool(params: params, manualPeers: parsedManualPeers(),
                                peersFileURL: dir.appending(path: "peers.json"),
                                relayPreference: true)
            let chain = try HeaderChain(params: params, storageURL: dir.appending(path: "headers.bin"))
            let broadcaster = TxBroadcaster(pool: pool, storageURL: dir.appending(path: "broadcast.json"))
            var newStack = SyncStack(pool: pool, chain: chain, filters: nil, broadcaster: broadcaster)
            if let wallet {
                newStack.filters = try await makeFilterSync(pool: pool, chain: chain,
                                                            startHeight: wallet.nextScanHeight)
            }
            stack = newStack
        } catch {
            status.lastSyncError = error.localizedDescription
        }
    }

    private func makeFilterSync(pool: PeerPool, chain: HeaderChain, startHeight: UInt32) throws -> FilterSync {
        try FilterSync(pool: pool, chain: chain, startHeight: startHeight,
                       storageURL: storageDirectory()?.appending(path: "filters.json"))
    }

    private func startSyncLoop() {
        guard syncTask == nil, wallet != nil, stack?.filters != nil else { return }
        syncTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.syncOnce()
                try? await Task.sleep(for: .seconds(45))
            }
        }
    }

    /// One combined scan pass: the wallet's and all vaults' scripts in a
    /// single filter stream (a vault is just more watched scripts). Matched
    /// blocks update the wallet, the vault store, and confirm pending
    /// broadcasts.
    func syncNow() async {
        await syncOnce()
    }

    private func syncOnce() async {
        guard let wallet, let stack, let filters = stack.filters else { return }
        status.syncing = true
        defer { status.syncing = false }
        do {
            var scripts = try await wallet.watchScripts()
            scripts.append(contentsOf: await vaultStore.watchScripts(network: network))
            let broadcaster = stack.broadcaster
            let network = network
            let vaultStore = vaultStore
            try await filters.sync(watchScripts: scripts) { match in
                _ = try await wallet.apply(match: match)
                try await vaultStore.apply(match: match, network: network)
                let pending = await broadcaster.pendingTxids
                for tx in match.block.transactions where pending.contains(tx.txid) {
                    await broadcaster.markConfirmed(tx.txid)
                }
            }
            // apply() does not move the wallet frontier — FilterSync is
            // authoritative here. Persist it so exportBundle() and the next
            // launch's startHeight match what the UI already shows.
            try await wallet.recordScanHeight(await filters.nextScanHeight)
            status.lastSyncError = nil
        } catch {
            // A later batch may have thrown after earlier ones persisted
            // in FilterSync. Keep WalletState from lagging that progress.
            try? await wallet.recordScanHeight(await filters.nextScanHeight)
            status.lastSyncError = error.localizedDescription
        }
        await refresh()
    }

    /// Rebuilds the UI-facing snapshot from the actors.
    func refresh() async {
        var snapshot = Status()
        if let wallet {
            snapshot.balance = await wallet.balance
            snapshot.utxoCount = await wallet.utxos.count
            // Pending (height 0) entries first, then newest block first.
            snapshot.history = await wallet.history.sorted {
                ($0.height == 0 ? UInt32.max : $0.height) > ($1.height == 0 ? UInt32.max : $1.height)
            }
            snapshot.observedFeeRates = await wallet.observedFeeRates
            snapshot.nextScanHeight = await wallet.nextScanHeight
        }
        if let stack {
            snapshot.peerCount = await stack.pool.connectedPeers().count
            snapshot.tipHeight = await stack.chain.height
            if let filters = stack.filters {
                snapshot.nextScanHeight = await filters.nextScanHeight
            }
            snapshot.feeFloorSatPerVByte = await stack.pool.feeFilterFloorSatPerVByte()
        }
        snapshot.syncing = status.syncing
        snapshot.lastSyncError = status.lastSyncError
        status = snapshot
        vaults = await vaultStore.all
    }

    // MARK: - Wallet creation / import (onboarding)

    /// Creates a fresh wallet. Headers are synced first so the creation height
    /// is the current tip — a fresh wallet scans forward from there
    /// (docs/read-side.md §3.1). Returns the new mnemonic, shown once.
    func createWallet() async throws -> String {
        await buildStackIfNeeded()
        guard let stack else { throw AppError.noStack }
        await stack.pool.start()
        let peer = try await waitForPeer(timeout: .seconds(90))
        try await stack.chain.sync(using: peer, timeout: .seconds(60))
        let tip = await stack.chain.height
        guard let walletURL = walletURL() else { throw AppError.noWallet }
        let wallet = try Wallet.create(network: network, keyStore: keyStore,
                                       storageURL: walletURL, entropy: e2e?.entropy,
                                       creationHeight: tip)
        // Flag BEFORE adopt(): the wallet is already in the Keychain, so a
        // throw below must not leave it unflagged — the next boot would land
        // on .ready with the backup silently skipped, the exact bug class #5
        // kills. A stuck-true flag merely re-presents the sheet: fail-safe.
        UserDefaults.standard.set(true, forKey: DefaultsKey.backupPending(await wallet.id))
        try await adopt(wallet: wallet)
        guard let walletID, case let .mnemonic(words) = try keyStore.load(walletID: walletID) else {
            throw AppError.mnemonicUnavailable
        }
        return words
    }

    /// Imports a wallet bundle (docs/import.md): the state starts as
    /// the bundle claims and is then verified by forward-scanning from the
    /// bundle height. Returns the verification report, or nil when no peers
    /// were reachable yet — the regular sync loop covers the same ground.
    @discardableResult
    func importWallet(bundleJSON: String) async throws -> ImportReport? {
        guard let data = bundleJSON.data(using: .utf8) else {
            throw WalletError.invalidBundle("not UTF-8")
        }
        let bundle = try JSONDecoder().decode(ImportBundle.self, from: data)
        guard bundle.network == network.rawValue else { throw AppError.wrongNetwork(bundle.network) }
        guard let walletURL = walletURL() else { throw AppError.noWallet }
        let wallet = try Wallet.importing(bundle, keyStore: keyStore, storageURL: walletURL)
        // Verification below runs its own one-shot filter sync; the regular
        // sync loop must not run concurrently with it (two sync() passes on
        // the same FilterSync/HeaderChain race — crossed getheaders/getcfilter
        // responses on the shared peer). The loop starts on the way out.
        try await adopt(wallet: wallet, startSync: false)
        defer { if isActive { startSyncLoop() } }
        await buildStackIfNeeded()
        guard let filters = stack?.filters else { return nil }
        await stack?.pool.start()
        guard (try? await waitForPeer(timeout: .seconds(60))) != nil else { return nil }
        // A verification failure (e.g. a peer serving a bad filter) is a real
        // error for the user, not the "no peers yet" soft path.
        let report = try await wallet.verifyImport(bundle, using: filters)
        await refresh()
        return report
    }

    /// Live wallet as a v1 import-bundle JSON string (docs/import.md).
    /// Watch-only unless `includeMnemonic` is set; an xprv-only wallet
    /// throws ``WalletError/mnemonicUnavailable`` rather than a fake seed.
    func exportWalletBundle(includeMnemonic: Bool) async throws -> String {
        guard let wallet else { throw AppError.noWallet }
        // The UI snapshot already prefers filters.nextScanHeight; export
        // must too, in case the last persist was skipped (failed pass).
        if let filters = stack?.filters {
            try await wallet.recordScanHeight(await filters.nextScanHeight)
        }
        return try await wallet.exportBundle(includeMnemonic: includeMnemonic).serialized()
    }

    /// Switches to a just-created/imported wallet: anything chain-facing from
    /// a previous wallet (filter progress, pending broadcasts, vault records)
    /// is that wallet's view and is reset; the new wallet's scan starts from
    /// its own scan height. The stage stays `.onboarding` until the UI calls
    /// `finishOnboarding` (the mnemonic backup must be confirmed first).
    /// `startSync: false` defers the sync loop (import verifies first).
    private func adopt(wallet: Wallet, startSync: Bool = true) async throws {
        if let dir = storageDirectory() {
            for name in ["filters.json", "broadcast.json", "vaults.json"] {
                try? FileManager.default.removeItem(at: dir.appending(path: name))
            }
        }
        await vaultStore.configure(storageURL: vaultsURL())
        self.wallet = wallet
        walletID = await wallet.id
        walletDescriptor = await wallet.descriptor
        if var stack {
            stack.filters = try await makeFilterSync(pool: stack.pool, chain: stack.chain,
                                                     startHeight: wallet.nextScanHeight)
            self.stack = stack
        }
        await refresh()
        if startSync, isActive { startSyncLoop() }
    }

    /// Leaves onboarding once the backup flow (or import report) is done.
    func finishOnboarding() {
        if let walletID {
            UserDefaults.standard.removeObject(forKey: DefaultsKey.backupPending(walletID))
        }
        if wallet != nil { stage = .ready }
    }

    /// The mnemonic of a wallet created but never backup-confirmed — non-nil
    /// only between `createWallet()` and the backup sheet's Done. Read from
    /// the Keychain on demand so a relaunch mid-backup resumes the sheet with
    /// the same words.
    func pendingBackupMnemonic() -> String? {
        guard let walletID,
              UserDefaults.standard.bool(forKey: DefaultsKey.backupPending(walletID)),
              case let .mnemonic(words) = try? keyStore.load(walletID: walletID)
        else { return nil }
        return words
    }

    /// Settings → Backup → Show recovery phrase: the words, behind
    /// device-owner authentication (passcode or biometrics). Fail-closed —
    /// no passcode set means no reveal, not a silent skip. E2E test mode
    /// bypasses the prompt (simulators have no passcode); an xprv-only wallet
    /// throws `WalletError.mnemonicUnavailable`.
    func revealMnemonic() async throws -> String {
        guard let walletID else { throw AppError.noWallet }
        if e2e == nil {
            let context = LAContext()
            var unavailable: NSError?
            guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &unavailable) else {
                throw AppError.deviceAuthUnavailable
            }
            let passed = try await context.evaluatePolicy(
                .deviceOwnerAuthentication,
                localizedReason: "Reveal this wallet's recovery phrase")
            guard passed else { throw AppError.deviceAuthFailed }
        }
        guard case let .mnemonic(words) = try keyStore.load(walletID: walletID) else {
            throw WalletError.mnemonicUnavailable
        }
        return words
    }

    /// Polls the pool until a peer completes the handshake (or the timeout
    /// fires) — onboarding's create/import flows need one peer to ask for the
    /// chain tip.
    private func waitForPeer(timeout: Duration) async throws -> PeerConnection {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            try Task.checkCancellation()
            if let peer = await stack?.pool.randomPeer() { return peer }
            try? await Task.sleep(for: .seconds(1))
        }
        throw AppError.noPeers
    }

    // MARK: - Addresses, fees, sending

    /// The receive address currently shown (peeked — marked used only when a
    /// payment to it arrives, or via `freshReceiveAddress`).
    func currentReceiveAddress() async throws -> String {
        guard let wallet else { throw AppError.noWallet }
        return try await wallet.address(chain: .receive, index: wallet.nextReceiveIndex)
    }

    /// Marks the current receive address used and returns the next one.
    func freshReceiveAddress() async throws -> String {
        guard let wallet else { throw AppError.noWallet }
        let address = try await wallet.freshReceiveAddress()
        await refresh()
        return address
    }

    /// The resolved feerate (sat/vB): user override, then the opt-in esplora
    /// estimate when enabled, then the wallet's own observed feerates, then the
    /// static presets — clamped from below by the peers' BIP133 floor
    /// (FeePolicy, docs/write-side.md §4).
    func resolvedFeeRate(priority: FeePolicy.Priority, override: Double?) async -> Double {
        let observed = await wallet?.observedFeeRates ?? []
        let serverEstimate = await esploraEstimate(for: priority)
        return FeePolicy.resolve(priority: priority, override: override ?? serverEstimate,
                                 observed: observed, floorSatPerVByte: status.feeFloorSatPerVByte)
    }

    /// What a send will look like at the resolved feerate (coin selection run
    /// without committing — `Wallet.send` itself commits on success).
    struct SendPreview: Equatable {
        var payments: [Payment]
        var silentPayments: [SilentPayment]
        var feeRateSatPerVByte: Double
        var fee: Int64
        var changeAmount: Int64?
        var inputCount: Int
    }

    /// Parses the destination (any standard address, or an sp1…/tsp1… silent
    /// payment code) and previews coin selection at the resolved feerate.
    func previewSend(destination: String, amount: Int64, priority: FeePolicy.Priority,
                     override: Double?) async throws -> SendPreview {
        guard let wallet else { throw AppError.noWallet }
        let feeRate = await resolvedFeeRate(priority: priority, override: override)
        let trimmed = destination.trimmingCharacters(in: .whitespacesAndNewlines)
        var payments: [Payment] = []
        var silentPayments: [SilentPayment] = []
        // Sizing placeholder for the fee math: silent payment outputs are
        // always P2TR; the real script is derived at signing time (BIP352).
        let sizing = Data([0x51, 0x20]) + Data(repeating: 0, count: 32)
        if trimmed.lowercased().hasPrefix("sp1") || trimmed.lowercased().hasPrefix("tsp1") {
            silentPayments.append(try SilentPayment(amount: amount, address: trimmed, network: network))
        } else {
            payments.append(try Payment(amount: amount, address: trimmed, network: network))
        }
        let sizingPayments = payments + silentPayments.map { Payment(amount: $0.amount, scriptPubKey: sizing) }
        let utxos = await wallet.utxos
        let changeScript = try await wallet.scriptPubKey(chain: .change, index: wallet.nextChangeIndex)
        let selection = try CoinSelection.select(utxos: utxos, payments: sizingPayments,
                                                 changeScriptPubKey: changeScript,
                                                 feeRateSatPerVByte: feeRate)
        return SendPreview(payments: payments, silentPayments: silentPayments,
                           feeRateSatPerVByte: feeRate, fee: selection.fee,
                           changeAmount: selection.changeAmount, inputCount: selection.selected.count)
    }

    /// Builds, signs and broadcasts the previewed send. Returns the txid
    /// (internal byte order).
    func send(preview: SendPreview) async throws -> Data {
        guard let wallet else { throw AppError.noWallet }
        // Build and sign WITHOUT touching wallet state, hand the tx to the
        // broadcaster, and only then commit the selection. If broadcast throws
        // (no stack, disk error), nothing was spent locally — no stranded UTXOs.
        let prepared = try await wallet.buildSend(payments: preview.payments,
                                                  feeRateSatPerVByte: preview.feeRateSatPerVByte,
                                                  silentPayments: preview.silentPayments)
        let txid = try await broadcast(prepared.built.transaction,
                                       feeRateSatPerVByte: preview.feeRateSatPerVByte)
        try await wallet.commit(prepared)
        await refresh()
        return txid
    }

    /// Broadcasts a fully-signed transaction via P2P relay — and additionally
    /// POSTs it to the esplora backend when the user opted in.
    /// `feeRateSatPerVByte` (known from the send preview) enables the
    /// broadcaster's BIP133 fee-floor events.
    func broadcast(_ transaction: BitcoinTransaction, feeRateSatPerVByte: Double? = nil) async throws -> Data {
        guard let broadcaster = stack?.broadcaster else { throw AppError.noStack }
        let raw = transaction.serialized(includeWitness: true)
        let txid = try await broadcaster.broadcast(raw, feeRateSatPerVByte: feeRateSatPerVByte)
        if esploraEnabled {
            _ = try? await EsploraClient(baseURL: esploraBaseURL).broadcast(raw)
        }
        return txid
    }

    // MARK: - Vaults

    /// This wallet's cosigner key expression for vault creation:
    /// `[fp/86'/coin'/0']xpub…`, with the `/<0;1>/*` multipath suffix for
    /// multi_a leaves (musig() participants carry no own suffix, BIP390).
    func ownKeyExpression(multipathSuffix: Bool) throws -> String {
        guard let walletDescriptor else { throw AppError.noWallet }
        guard case let .tr(.single(key), nil) = walletDescriptor.expression,
              let origin = key.origin,
              case let .extended(accountKey, hdNetwork) = key.base
        else { throw AppError.noWallet }
        let path = origin.path.map { step in
            step >= HDKey.hardenedOffset ? "\(step - HDKey.hardenedOffset)'" : "\(step)"
        }.joined(separator: "/")
        let base = "[\(String(format: "%08x", origin.fingerprint))/\(path)]\(accountKey.serialized(network: hdNetwork))"
        return multipathSuffix ? base + "/<0;1>/*" : base
    }

    func addVault(name: String, descriptor: Descriptor) async throws -> VaultRecord {
        var height: UInt32 = 0
        if let filters = stack?.filters {
            height = await filters.nextScanHeight
        } else if let wallet {
            height = await wallet.nextScanHeight
        }
        let record = try await vaultStore.add(name: name, descriptor: descriptor, createdAtHeight: height)
        vaults = await vaultStore.all
        return record
    }

    func removeVault(id: String) async {
        try? await vaultStore.remove(id: id)
        vaults = await vaultStore.all
    }

    func advanceVaultReceiveIndex(id: String) async {
        try? await vaultStore.advanceReceiveIndex(id: id)
        vaults = await vaultStore.all
    }

    /// Commits a broadcast vault spend to the vault's local UTXO set.
    func recordVaultSpend(id: String, transaction: BitcoinTransaction, changeScriptPubKey: Data?,
                          changeIndex: UInt32) async {
        try? await vaultStore.recordSpend(id: id, transaction: transaction,
                                          changeScriptPubKey: changeScriptPubKey, changeIndex: changeIndex)
        vaults = await vaultStore.all
    }

    /// Loads the wallet's master key for one vault signing operation.
    func withMasterKey<T>(_ body: (HDKey) throws -> T) throws -> T {
        guard let walletID else { throw AppError.noWallet }
        let master: HDKey
        switch try keyStore.load(walletID: walletID) {
        case let .mnemonic(words): master = try HDKey(seed: BIP39.seed(mnemonic: words))
        case let .masterKey(xprv): master = try HDKey.deserialize(xprv)
        }
        return try body(master)
    }

    // MARK: - Settings

    /// Per-network wallets: switching network opens that network's own state
    /// (or onboarding when it has none) with a freshly built stack.
    func switchNetwork(to newNetwork: BitcoinNetwork) async {
        guard newNetwork != network else { return }
        syncTask?.cancel()
        syncTask = nil
        await stack?.pool.stop()
        stack = nil
        wallet = nil
        walletID = nil
        walletDescriptor = nil
        network = newNetwork
        UserDefaults.standard.set(newNetwork.rawValue, forKey: DefaultsKey.network)
        esploraEstimates = nil
        await vaultStore.configure(storageURL: vaultsURL())
        if let walletURL = walletURL(), let wallet = try? Wallet.open(storageURL: walletURL, keyStore: keyStore) {
            self.wallet = wallet
            walletID = await wallet.id
            walletDescriptor = await wallet.descriptor
            // A wallet whose backup was never confirmed re-enters onboarding:
            // the backup sheet resumes from the Keychain (#5).
            stage = pendingBackupMnemonic() == nil ? .ready : .onboarding
        } else {
            stage = .onboarding
        }
        await refresh()
        if isActive { await activate() }
    }

    static func parsePeer(_ text: String) throws -> PeerEndpoint {
        let parts = text.trimmingCharacters(in: .whitespaces).split(separator: ":")
        guard parts.count == 2, !parts[0].isEmpty,
              let port = UInt16(parts[1]), port > 0
        else { throw AppError.invalidPeer(text) }
        return PeerEndpoint(host: String(parts[0]), port: port)
    }

    func addManualPeer(_ text: String) throws {
        let endpoint = try Self.parsePeer(text)
        guard !manualPeers.contains(endpoint.description) else { return }
        manualPeers.append(endpoint.description)
        UserDefaults.standard.set(manualPeers, forKey: DefaultsKey.manualPeers)
    }

    func removeManualPeers(at offsets: IndexSet) {
        manualPeers.remove(atOffsets: offsets)
        UserDefaults.standard.set(manualPeers, forKey: DefaultsKey.manualPeers)
    }

    /// Rebuilds the stack so changed peer settings take effect.
    func reconnect() async {
        syncTask?.cancel()
        syncTask = nil
        await stack?.pool.stop()
        stack = nil
        await activate()
        await refresh()
    }

    func setEsploraEnabled(_ enabled: Bool) {
        esploraEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: DefaultsKey.esploraEnabled)
        if !enabled { esploraEstimates = nil }
    }

    func setEsploraURL(_ text: String) {
        esploraURLString = text.trimmingCharacters(in: .whitespacesAndNewlines)
        UserDefaults.standard.set(esploraURLString, forKey: DefaultsKey.esploraURL)
        esploraEstimates = nil
    }

    /// The esplora base URL: the user's own instance when set, else the
    /// well-known public default for the current network. Only ever contacted
    /// when the opt-in toggle is on.
    var esploraBaseURL: URL {
        if let url = URL(string: esploraURLString), url.scheme != nil { return url }
        return network == .mainnet ? EsploraClient.mempoolSpaceMainnet : EsploraClient.mempoolSpaceSignet
    }

    /// Fee estimates from the opt-in esplora backend (cached per session);
    /// nil when the toggle is off — nothing is contacted then.
    private func esploraEstimate(for priority: FeePolicy.Priority) async -> Double? {
        guard esploraEnabled else { return nil }
        if esploraEstimates == nil {
            esploraEstimates = try? await EsploraClient(baseURL: esploraBaseURL).feeEstimates()
        }
        guard let estimates = esploraEstimates, !estimates.isEmpty else { return nil }
        let target = switch priority {
        case .low: 144
        case .medium: 6
        case .high: 1
        }
        if let rate = estimates[target] { return rate }
        return estimates.min(by: { abs($0.key - target) < abs($1.key - target) })?.value
    }

    // MARK: - Storage

    /// Application Support/BTCSwift/<network>/ — wallet state, headers, filter
    /// progress, peers, broadcasts, vaults. Excluded from backup: no secrets
    /// here (those are Keychain-only), and even the public state stays on the
    /// device.
    private func storageDirectory() -> URL? {
        guard let base = try? FileManager.default.url(for: .applicationSupportDirectory,
                                                      in: .userDomainMask,
                                                      appropriateFor: nil, create: true)
        else { return nil }
        var root = base.appending(path: e2e?.storageDirectoryName ?? "BTCSwift",
                                  directoryHint: .isDirectory)
        let dir = root.appending(path: network.rawValue, directoryHint: .isDirectory)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try root.setResourceValues(values)
            return dir
        } catch {
            return nil
        }
    }

    private func walletURL() -> URL? {
        storageDirectory()?.appending(path: "wallet.json")
    }

    private func vaultsURL() -> URL? {
        storageDirectory()?.appending(path: "vaults.json")
    }

    private func parsedManualPeers() -> [PeerEndpoint] {
        manualPeers.compactMap { try? Self.parsePeer($0) }
    }
}
