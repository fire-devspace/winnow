@testable import WinnowApp
import WalletCore
import XCTest

/// Beginner controls and persisted preferences, with a fresh settings suite per test.
@MainActor
final class AdvancedModeTests: XCTestCase {
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        defaults = makeDefaults()
    }

    func testBeginnerKeepsManualPeersWhileAnyAreSet() throws {
        let model = makeModel(defaults: defaults)
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
        defaults.set(true, forKey: AppModel.DefaultsKey.verifyFromGenesis)
        let model = makeModel(defaults: defaults)
        XCTAssertFalse(model.advancedMode)
        XCTAssertTrue(model.showsChainVerification)
        XCTAssertFalse(makeModel(defaults: defaults).showsExplorerSettings)
    }

    func testBeginnerKeepsExplorerSettingsWhileCustomised() {
        let model = makeModel(defaults: defaults)
        XCTAssertFalse(model.showsExplorerSettings)
        model.setEsploraURL("https://example.org")
        XCTAssertTrue(model.showsExplorerSettings)
        model.setEsploraURL("")
        XCTAssertFalse(model.showsExplorerSettings)
        XCTAssertTrue(model.esploraTransactionURL(Data(repeating: 0xAB, count: 32)).absoluteString
            .hasPrefix("https://blockstream.info/tx/"), "the history link works with the section hidden")
    }

    func testAFreshInstallIsOnMainnetAndHidesTheNetworkPicker() {
        let model = makeModel(defaults: defaults)
        XCTAssertEqual(model.network, .mainnet, "#9: mainnet is the default")
        XCTAssertEqual(AppModel.defaultNetwork, .mainnet)
        XCTAssertFalse(model.showsNetworkPicker, "signet is an Advanced-mode concern")
        model.setAdvancedMode(true)
        XCTAssertTrue(model.showsNetworkPicker)
    }

    func testASignetWalletAlwaysKeepsTheNetworkPicker() {
        // Advanced mode off, but the stored network is signet: the row must
        // stay, or turning the flag off would strand the wallet there.
        defaults.set(BitcoinNetwork.signet.rawValue, forKey: AppModel.DefaultsKey.network)
        let model = makeModel(defaults: defaults)
        XCTAssertEqual(model.network, .signet)
        XCTAssertFalse(model.advancedMode)
        XCTAssertTrue(model.showsNetworkPicker)
    }

    func testOffByDefaultAndPersistedWhenTurnedOn() {
        let model = makeModel(defaults: defaults)
        XCTAssertFalse(model.advancedMode, "a fresh install is a beginner")
        model.setAdvancedMode(true)
        XCTAssertTrue(model.advancedMode)
        XCTAssertTrue(defaults.bool(forKey: AppModel.DefaultsKey.advancedMode))
        XCTAssertTrue(makeModel(defaults: defaults).advancedMode, "reopening keeps the preference")
        XCTAssertFalse(makeModel().advancedMode, "a separate install still starts in beginner mode")
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

/// Peer and explorer preferences stay with their network, including after migration.
@MainActor
final class NetworkScopedSettingsTests: XCTestCase {
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        defaults = makeDefaults()
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
