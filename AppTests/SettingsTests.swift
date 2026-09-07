@testable import WinnowApp
import WalletCore
import XCTest

/// What Settings stores, and who is allowed to see it.
///
/// Two questions with one answer surface: which rows a beginner is shown, and
/// which values follow the network rather than the install. They keep separate
/// classes because their fixtures are incompatible — AdvancedModeTests saves
/// and restores keys in `UserDefaults.standard`, since the model reads that
/// suite directly, while NetworkScopedSettingsTests builds a throwaway suite
/// per test and passes it in. One `setUp` cannot serve both. Both class names
/// are cited in docs/security/findings.md (SEC-013) and the invariant matrix.

// MARK: - AdvancedModeTests

/// Advanced mode gates everything a beginner should never have to read,
/// starting with the network picker. Off by default, global rather than per
/// network, and turning it off hides rather than deletes.
@MainActor
final class AdvancedModeTests: XCTestCase {
    private var saved: [String: Any?] = [:]
    private var trackedKeys: [String] {
        [AppModel.DefaultsKey.network, AppModel.DefaultsKey.advancedMode,
         AppModel.DefaultsKey.verifyFromGenesis,
         AppModel.DefaultsKey.manualPeers(.mainnet), AppModel.DefaultsKey.esploraURL(.mainnet),
         AppModel.DefaultsKey.explorerProvider(.mainnet)]
    }

    override func setUp() {
        super.setUp()
        for key in trackedKeys {
            saved[key] = UserDefaults.standard.object(forKey: key)
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    override func tearDown() {
        for key in trackedKeys {
            if let value = saved[key] ?? nil {
                UserDefaults.standard.set(value, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
        super.tearDown()
    }

    func testBeginnerKeepsManualPeersWhileAnyAreSet() throws {
        let model = makeModel()
        XCTAssertFalse(model.showsManualPeers)
        try model.addManualPeer("127.0.0.1:38401")
        XCTAssertTrue(model.showsManualPeers, "a configured peer keeps its section")
        model.setAdvancedMode(true)
        model.setAdvancedMode(false)
        XCTAssertEqual(model.manualPeers, ["127.0.0.1:38401"], "hide, never delete")
        model.removeManualPeers(at: IndexSet(integer: 0))
        XCTAssertFalse(model.showsManualPeers)
        model.setAdvancedMode(true)
        XCTAssertTrue(model.showsManualPeers)
    }

    func testBeginnerKeepsChainVerificationWhileOn() {
        UserDefaults.standard.set(true, forKey: AppModel.DefaultsKey.verifyFromGenesis)
        let model = makeModel()
        XCTAssertFalse(model.advancedMode)
        XCTAssertTrue(model.showsChainVerification)
        XCTAssertFalse(makeModel().showsExplorerSettings)
    }

    func testBeginnerKeepsExplorerSettingsWhileCustomised() {
        let model = makeModel()
        XCTAssertFalse(model.showsExplorerSettings)
        model.setEsploraURL("https://example.org")
        XCTAssertTrue(model.showsExplorerSettings)
        model.setEsploraURL("")
        XCTAssertFalse(model.showsExplorerSettings)
        XCTAssertTrue(model.esploraTransactionURL(Data(repeating: 0xAB, count: 32)).absoluteString
            .hasPrefix("https://blockstream.info/tx/"), "the history link works with the section hidden")
    }

    func testAFreshInstallIsOnMainnetAndHidesTheNetworkPicker() {
        let model = makeModel()
        XCTAssertEqual(model.network, .mainnet, "#9: mainnet is the default")
        XCTAssertEqual(AppModel.defaultNetwork, .mainnet)
        XCTAssertFalse(model.showsNetworkPicker, "signet is an Advanced-mode concern")
        model.setAdvancedMode(true)
        XCTAssertTrue(model.showsNetworkPicker)
    }

    func testASignetWalletAlwaysKeepsTheNetworkPicker() {
        // Advanced mode off, but the stored network is signet: the row must
        // stay, or turning the flag off would strand the wallet there.
        UserDefaults.standard.set(BitcoinNetwork.signet.rawValue, forKey: AppModel.DefaultsKey.network)
        let model = makeModel()
        XCTAssertEqual(model.network, .signet)
        XCTAssertFalse(model.advancedMode)
        XCTAssertTrue(model.showsNetworkPicker)
    }

    func testOffByDefaultAndPersistedWhenTurnedOn() {
        let model = makeModel()
        XCTAssertFalse(model.advancedMode, "a fresh install is a beginner")
        model.setAdvancedMode(true)
        XCTAssertTrue(model.advancedMode)
        XCTAssertTrue(UserDefaults.standard.bool(forKey: AppModel.DefaultsKey.advancedMode))
        XCTAssertEqual(AppModel.DefaultsKey.advancedMode, "advancedMode",
                       "global, not network-scoped: a statement about the user, not the chain")
    }

    func testTheE2EFlagTurnsItOnForAUITestLaunch() throws {
        let base = [
            "WINNOW_E2E": "1",
            "WINNOW_E2E_ENTROPY": String(repeating: "00", count: 16),
        ]
        guard case let .active(plain) = E2EMode.resolve(environment: base) else {
            return XCTFail("E2E mode should resolve")
        }
        XCTAssertFalse(plain.advancedMode)
        guard case let .active(advanced) = E2EMode.resolve(
            environment: base.merging(["WINNOW_E2E_ADVANCED": "1"]) { $1 })
        else {
            return XCTFail("E2E mode should resolve")
        }
        XCTAssertTrue(advanced.advancedMode)
    }
}

// MARK: - NetworkScopedSettingsTests

/// Peer, explorer and tweak-index settings must not cross a network switch
/// (epic #100, invariant S6; bug #81).
///
/// Keys and money were already separated — storage is under `root/<network>/`
/// and derivation is SLIP-44 correct — so no signet key can produce a mainnet
/// address. What leaked was three settings, and each fails in its own way.
/// Manual peers are dialed *first*, so a signet node left configured spends a
/// mainnet pool's opening attempts on a peer that will reject the handshake;
/// that is the "sync looks broken" the bug was reported as. A signet explorer
/// or tweak index is quieter and worse in kind: it answers mainnet queries
/// with confidently wrong data.
@MainActor
final class NetworkScopedSettingsTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "winnow-network-scope-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    private typealias Key = AppModel.DefaultsKey

    // MARK: Isolation

    /// The property the bug is about: what one network stores, another must
    /// not see.
    func testSettingsDoNotCrossBetweenNetworks() {
        defaults.set(["127.0.0.1:38333"], forKey: Key.manualPeers(.signet))
        defaults.set("https://signet.example/api", forKey: Key.esploraURL(.signet))

        let signet = AppModel.networkScopedSettings(defaults: defaults, network: .signet)
        XCTAssertEqual(signet.manualPeers, ["127.0.0.1:38333"])
        XCTAssertEqual(signet.esploraURL, "https://signet.example/api")

        let mainnet = AppModel.networkScopedSettings(defaults: defaults, network: .mainnet)
        XCTAssertEqual(mainnet.manualPeers, [], "a signet peer must not be dialed on mainnet")
        XCTAssertEqual(mainnet.esploraURL, "", "a signet explorer must not answer mainnet queries")
    }

    /// The preset table, resolved purely: blockstream is the default face
    /// of mainnet, but it has no signet explorer, so its signet resolution
    /// is mempool.space — a working link beats a loyal 404.
    func testExplorerPresetsResolvePerNetwork() {
        typealias P = AppModel.ExplorerProvider
        XCTAssertEqual(AppModel.explorerBaseURL(provider: .blockstream, customURLString: "",
                                                network: .mainnet).absoluteString,
                       "https://blockstream.info")
        XCTAssertEqual(AppModel.explorerBaseURL(provider: .blockstream, customURLString: "",
                                                network: .signet).absoluteString,
                       "https://mempool.space/signet")
        XCTAssertEqual(AppModel.explorerBaseURL(provider: .mempool, customURLString: "",
                                                network: .mainnet).absoluteString,
                       "https://mempool.space")
        XCTAssertEqual(AppModel.explorerBaseURL(provider: .custom,
                                                customURLString: "https://esplora.example",
                                                network: .signet).absoluteString,
                       "https://esplora.example")
        // A custom entry that does not parse falls back to the default
        // preset rather than producing a broken link.
        XCTAssertEqual(AppModel.explorerBaseURL(provider: .custom, customURLString: "not a url",
                                                network: .mainnet).absoluteString,
                       "https://blockstream.info")
    }

    func testExplorerProviderKeyIsPerNetwork() {
        XCTAssertNotEqual(Key.explorerProvider(.signet), Key.explorerProvider(.mainnet))
    }

    /// Each network keeps its own value rather than the last one written
    /// winning.
    func testEachNetworkKeepsItsOwnValues() {
        defaults.set(["10.0.0.1:38333"], forKey: Key.manualPeers(.signet))
        defaults.set(["10.0.0.2:8333"], forKey: Key.manualPeers(.mainnet))

        XCTAssertEqual(AppModel.networkScopedSettings(defaults: defaults, network: .signet).manualPeers,
                       ["10.0.0.1:38333"])
        XCTAssertEqual(AppModel.networkScopedSettings(defaults: defaults, network: .mainnet).manualPeers,
                       ["10.0.0.2:8333"])
    }

    /// The keys themselves must differ; if they collided, every assertion
    /// above would pass for the wrong reason.
    func testScopedKeysDifferPerNetwork() {
        XCTAssertNotEqual(Key.manualPeers(.signet), Key.manualPeers(.mainnet))
        XCTAssertNotEqual(Key.esploraURL(.signet), Key.esploraURL(.mainnet))
    }

    // MARK: Migration of existing installs

    /// An install that predates the fix has flat keys. They belong to whatever
    /// chain the user was on, and must survive the upgrade rather than being
    /// silently dropped.
    func testLegacySettingsMigrateIntoTheActiveNetwork() {
        defaults.set(["127.0.0.1:38333"], forKey: Key.legacyManualPeers)
        defaults.set("https://old.example/api", forKey: Key.legacyEsploraURL)

        AppModel.migrateLegacyNetworkSettings(defaults: defaults, into: .signet)

        let signet = AppModel.networkScopedSettings(defaults: defaults, network: .signet)
        XCTAssertEqual(signet.manualPeers, ["127.0.0.1:38333"])
        XCTAssertEqual(signet.esploraURL, "https://old.example/api")

        // And they must not appear on the other network.
        let mainnet = AppModel.networkScopedSettings(defaults: defaults, network: .mainnet)
        XCTAssertEqual(mainnet.manualPeers, [])
        XCTAssertEqual(mainnet.esploraURL, "")
    }

    /// The flat keys are removed, so the migration runs once and a later
    /// switch cannot pick them up again.
    func testMigrationRemovesTheLegacyKeys() {
        defaults.set(["127.0.0.1:38333"], forKey: Key.legacyManualPeers)
        defaults.set("https://old.example/api", forKey: Key.legacyEsploraURL)

        AppModel.migrateLegacyNetworkSettings(defaults: defaults, into: .signet)

        XCTAssertNil(defaults.stringArray(forKey: Key.legacyManualPeers))
        XCTAssertNil(defaults.string(forKey: Key.legacyEsploraURL))
    }

    /// Migrating must not overwrite a value the user has already set under the
    /// new scheme.
    func testMigrationDoesNotClobberExistingScopedValues() {
        defaults.set(["10.0.0.9:38333"], forKey: Key.manualPeers(.signet))
        defaults.set(["127.0.0.1:38333"], forKey: Key.legacyManualPeers)

        AppModel.migrateLegacyNetworkSettings(defaults: defaults, into: .signet)

        XCTAssertEqual(AppModel.networkScopedSettings(defaults: defaults, network: .signet).manualPeers,
                       ["10.0.0.9:38333"])
        XCTAssertNil(defaults.stringArray(forKey: Key.legacyManualPeers))
    }

    /// Running twice is harmless.
    func testMigrationIsIdempotent() {
        defaults.set(["127.0.0.1:38333"], forKey: Key.legacyManualPeers)
        AppModel.migrateLegacyNetworkSettings(defaults: defaults, into: .signet)
        AppModel.migrateLegacyNetworkSettings(defaults: defaults, into: .mainnet)

        XCTAssertEqual(AppModel.networkScopedSettings(defaults: defaults, network: .signet).manualPeers,
                       ["127.0.0.1:38333"])
        XCTAssertEqual(AppModel.networkScopedSettings(defaults: defaults, network: .mainnet).manualPeers,
                       [], "a second run must not re-attribute settings to another chain")
    }

    /// A clean install has nothing to migrate and nothing appears.
    func testNothingToMigrateLeavesEverythingEmpty() {
        AppModel.migrateLegacyNetworkSettings(defaults: defaults, into: .mainnet)
        let mainnet = AppModel.networkScopedSettings(defaults: defaults, network: .mainnet)
        XCTAssertEqual(mainnet.manualPeers, [])
        XCTAssertEqual(mainnet.esploraURL, "")
    }
}
