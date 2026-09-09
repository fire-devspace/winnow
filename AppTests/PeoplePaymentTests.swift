@testable import WinnowApp
import WalletCore
import TestSupport
import XCTest

/// How people reach the send review and how vaults become shared savings.
@MainActor
final class PeoplePaymentTests: XCTestCase {
    private var savedNetwork: String?

    override func setUp() {
        super.setUp()
        savedNetwork = UserDefaults.standard.string(forKey: AppModel.DefaultsKey.network)
        UserDefaults.standard.set(BitcoinNetwork.signet.rawValue, forKey: AppModel.DefaultsKey.network)
    }

    override func tearDown() {
        if let savedNetwork {
            UserDefaults.standard.set(savedNetwork, forKey: AppModel.DefaultsKey.network)
        } else {
            UserDefaults.standard.removeObject(forKey: AppModel.DefaultsKey.network)
        }
        super.tearDown()
    }

    @MainActor
    private final class PausedAuthenticator: DeviceAuthenticating {
        var entered: (() -> Void)?
        var continuation: CheckedContinuation<Void, Never>?
        var shouldPause = true

        func authenticate(reason: String) async throws {
            guard shouldPause else { return }
            await withCheckedContinuation { continuation in
                self.continuation = continuation
                entered?()
            }
        }
    }

    func testClosingAnApprovalCancelsAuthenticationAndAllowsAFreshRequest() async throws {
        let environment = ["WINNOW_E2E": "1", "WINNOW_E2E_RUN": "approval-\(UUID().uuidString)",
                           "WINNOW_E2E_ENTROPY": String(repeating: "a1", count: 16), "WINNOW_E2E_DEVICE_AUTH": "1"]
        guard case let .active(mode) = E2EMode.resolve(environment: environment),
              case let .active(cleanup) = E2EMode.resolve(
                environment: environment.merging(["WINNOW_E2E_RESET": "1"]) { _, reset in reset })
        else { return XCTFail("could not create isolated approval fixture") }
        defer { cleanup.wipeIfRequested() }
        let authenticator = PausedAuthenticator()
        let model = AppModel(deviceAuthenticator: authenticator, e2e: mode)
        let directory = try FileManager.default.url(for: .applicationSupportDirectory,
                                                     in: .userDomainMask, appropriateFor: nil, create: true)
            .appending(path: mode.storageDirectoryName).appending(path: "signet")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        _ = try Wallet.create(network: .signet, keyStore: model.keyStore,
                              storageURL: directory.appending(path: "wallet.json"), entropy: mode.entropy)
        await model.boot()
        let (vault, _) = try TestVaults.multiAVault()
        let descriptor = vault.descriptor.serialized()
        let coin = try TestVaults.funding(vault: vault, amount: 80_000, height: 0)
        let record = VaultRecord(id: String(descriptor.split(separator: "#").last!), name: "Savings",
                                 descriptor: descriptor, createdAtHeight: 0, nextReceiveIndex: 1, allUtxos: [coin])
        try await model.vaultStore.restore([record])
        await model.refresh()
        let proposal = try vault.createSpend(utxos: [coin], payments: [Payment(amount: 20_000, scriptPubKey: Data([0x51]))],
                                              changeIndex: 0, feeRateSatPerVByte: 2, chainTip: 0)
        let session = VaultSpendSession(model: model, recordID: record.id)
        session.add(text: proposal.base64)
        XCTAssertNotNil(session.review)
        let entered = expectation(description: "authentication suspended")
        authenticator.entered = { entered.fulfill() }
        let pending = Task { await session.approve() }
        await fulfillment(of: [entered], timeout: 5)
        session.clear()
        authenticator.continuation?.resume()
        authenticator.continuation = nil
        await pending.value
        XCTAssertNil(session.working)
        XCTAssertNil(session.output)
        XCTAssertNil(session.error)
        XCTAssertFalse(session.busy)
        XCTAssertFalse(session.canFinish)

        authenticator.shouldPause = false
        session.add(text: proposal.base64)
        await session.approve()
        XCTAssertNil(session.error)
        XCTAssertTrue(session.approvedByYou)
        XCTAssertEqual(session.approvals.count, 1)
        XCTAssertFalse(session.canFinish, "one approval must not finish two-of-three savings")
    }

    func testAReviewIsInvalidatedByTheRecipientOrTheirAddressIndex() {
        let base = SendReviewInputs(destination: "", amountText: "1000", priority: .medium,
                                    overrideText: "", network: .signet, personID: "alice", paymentIndex: 3)
        XCTAssertNotEqual(base, SendReviewInputs(destination: "", amountText: "1000", priority: .medium,
                                                 overrideText: "", network: .signet, personID: "bob", paymentIndex: 3))
        XCTAssertNotEqual(base, SendReviewInputs(destination: "", amountText: "1000", priority: .medium,
                                                 overrideText: "", network: .signet, personID: "alice", paymentIndex: 4))
        XCTAssertEqual(SendReviewInputs(destination: "tb1p", amountText: "1", priority: .low,
                                        overrideText: "", network: .signet).personID, nil)
    }

    func testSharedSavingsAreDerivedFromSignerKeysWhetherOrNotPeopleAreKnown() async throws {
        let model = AppModel(deviceAuthenticator: SilentAuthenticator())
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("people-payment-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        await model.vaultStore.configure(storageURL: directory.appendingPathComponent("vaults.json"), network: .signet)
        await model.peopleStore.configure(storageURL: directory.appendingPathComponent("people.json"), network: .signet)

        let masters = try TestVaults.masters()
        let keys = try masters.map { try TestVaults.keyExpression(master: $0) }
        let descriptor = try Vault.multiADescriptor(threshold: 2, cosigners: keys)
        let record = try await model.addVault(name: "Savings with Alice, Bob", descriptor: descriptor)
        _ = try XCTUnwrap(model.sharedSavings.first, "new savings must be visible without a sync refresh")

        // No people yet: the vault still shows, with every signer unaccounted for.
        XCTAssertEqual(model.sharedSavings.count, 1)
        XCTAssertEqual(model.sharedSavings[0].coOwners, [])
        XCTAssertEqual(model.sharedSavings[0].threshold, 2)
        XCTAssertEqual(model.sharedSavings[0].signerCount, 3)
        XCTAssertFalse(model.sharedSavings[0].includesYou, "no wallet is open, so no own key")

        // Two of the three signers become people; the vault finds them by key.
        try await model.addPerson(name: "Alice", payTo: nil, signerKey: keys[0])
        try await model.addPerson(name: "Bob", payTo: nil, signerKey: keys[2].replacingOccurrences(of: "'", with: "h"))
        XCTAssertEqual(model.sharedSavings[0].coOwners.map(\.name), ["Alice", "Bob"])
        // Hiding a payment shortcut preserves signer identity and labels.
        let alice = model.people[0]
        try await model.updateRecipient(id: alice.id, name: alice.name, saved: false)
        XCTAssertEqual(model.sharedSavings[0].coOwners.map(\.name), ["Alice", "Bob"])

        // A person needs a signer key to co-own savings; a pay-to-only person is refused.
        let payOnly = try await model.addPerson(
            name: "Carol", payTo: try PersonPayTo.descriptor("tr(\(keys[1]))", network: .signet), signerKey: nil)
        do {
            _ = try await model.createSharedSavings(name: "x", coOwners: [payOnly], threshold: 1)
            XCTFail("a person without a signer key co-owned savings")
        } catch AppModel.AppError.personCannotCoOwn(let name) {
            XCTAssertEqual(name, "Carol")
        }
        // Paying Carol peeks index 0 and never moves it on its own.
        let (address, index) = try model.nextPaymentAddress(for: payOnly)
        XCTAssertEqual(index, 0)
        XCTAssertTrue(address.hasPrefix("tb1p"))
        XCTAssertEqual(try model.nextPaymentAddress(for: payOnly).address, address)
        await model.advancePersonPaymentIndex(id: payOnly.id, past: 0)
        XCTAssertEqual(model.people.first { $0.id == payOnly.id }?.nextPaymentIndex, 1)
        XCTAssertNotEqual(try model.nextPaymentAddress(for: model.people.first { $0.id == payOnly.id }!).address, address)
        XCTAssertEqual(model.personScripts().values.filter { $0 == "Carol" }.count, Int(1 + Wallet.gapLimit))

        await model.removeVault(id: record.id)
        XCTAssertTrue(model.sharedSavings.isEmpty, "removed savings must disappear without a sync refresh")
    }

    func testAnApprovalRequestForUnknownSavingsIsRefusedByName() async throws {
        let model = AppModel(deviceAuthenticator: SilentAuthenticator())
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("people-approval-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        await model.vaultStore.configure(storageURL: directory.appendingPathComponent("vaults.json"), network: .signet)
        let masters = Array(try TestVaults.masters().prefix(2))
        let keys = try masters.map { try TestVaults.keyExpression(master: $0) }
        let record = try await model.vaultStore.add(name: "Ours", descriptor: Vault.multiADescriptor(threshold: 2, cosigners: keys),
                                                    createdAtHeight: 0)
        await model.refresh()
        let session = VaultSpendSession(model: model, recordID: record.id)
        let stray = ApprovalRequest(network: .signet, vault: "deadbeef", name: "Someone else's",
                                    psbt: PSBT(globals: [], inputs: [], outputs: []))
        session.add(text: try stray.serialized())
        XCTAssertEqual(session.working, nil)
        XCTAssertTrue(session.error?.contains("Someone else's") == true, session.error ?? "")
        XCTAssertTrue(session.error?.contains("not on this phone") == true)
        session.add(text: "garbage")
        XCTAssertNotNil(session.error)
        XCTAssertEqual(session.threshold, 2)
    }

    func testSendUsesTheChosenAccountAndOnlyReservesAnAddressAfterReview() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = AppModel(deviceAuthenticator: SilentAuthenticator())
        await model.vaultStore.configure(storageURL: directory.appending(path: "vaults.json"), network: .signet)
        await model.peopleStore.configure(storageURL: directory.appending(path: "people.json"), network: .signet)
        let vaults = [try TestVaults.multiAVault().vault, try TestVaults.muSig2Vault().vault]
        let records = try vaults.enumerated().map { index, vault in
            let descriptor = vault.descriptor.serialized()
            var coin = try TestVaults.funding(vault: vault, amount: 80_000)
            coin.txid = Data(repeating: UInt8(0x50 + index), count: 32)
            return VaultRecord(id: String(descriptor.split(separator: "#").last!), name: "Account \(index)",
                               descriptor: descriptor, createdAtHeight: 0, nextReceiveIndex: 1, allUtxos: [coin])
        }
        try await model.vaultStore.restore(records)
        await model.refresh()
        let key = try TestVaults.keyExpression(master: TestVaults.master(entropyByte: 0xD4))
        let person = try await model.addPerson(name: "Alex", payTo: PersonPayTo.descriptor("tr(\(key))", network: .signet),
                                                signerKey: nil)
        for (index, record) in records.enumerated() {
            let recipient = try XCTUnwrap(model.people.first)
            let preview = try await model.previewSend(to: recipient, amount: 20_000, priority: .medium,
                                                       override: 2, accountID: record.id)
            XCTAssertEqual(preview.selectedOutpoints.map(\.txid), record.utxos.map(\.txid))
            XCTAssertEqual(preview.amountSent + preview.fee + (preview.changeAmount ?? 0), 80_000)
            XCTAssertEqual(model.people.first?.nextPaymentIndex, UInt32(index), "preview reserved an address")
            guard case let .vault(source, psbt) = preview.source else { return XCTFail("ordinary wallet preview") }
            XCTAssertEqual(source.id, record.id)
            XCTAssertTrue(psbt.inputs.allSatisfy { $0.tapScriptSignatures.isEmpty && $0.musig2PartialSigs.isEmpty })
            do {
                _ = try await model.send(preview: preview)
                XCTFail("a shared-account preview reached the ordinary send path")
            } catch AppModel.AppError.sendReviewChanged { }
            var changed = preview
            changed.fee += 1
            do {
                try await model.prepareVaultApproval(changed)
                XCTFail("changed review accepted")
            } catch AppModel.AppError.sendReviewChanged { }
            XCTAssertEqual(model.people.first?.nextPaymentIndex, UInt32(index))
            try await model.prepareVaultApproval(preview)
            XCTAssertEqual(model.people.first?.nextPaymentIndex, UInt32(index + 1))
            do {
                try await model.prepareVaultApproval(preview)
                XCTFail("stale recipient address was offered again")
            } catch AppModel.AppError.sendReviewChanged { }
            if index == 0 {
                let session = VaultSpendSession(model: model, recordID: record.id)
                session.add(text: psbt.base64)
                XCTAssertNotNil(session.output, "unsigned request cannot be shared")
                XCTAssertTrue(session.approvals.isEmpty)
                XCTAssertFalse(session.canFinish, "preparing a request approved it")
            }
        }
        let fresh = try await model.previewSend(to: XCTUnwrap(model.people.first), amount: 20_000,
                                                 priority: .medium, override: 2, accountID: records[0].id)
        await model.removeVault(id: records[0].id)
        do {
            try await model.prepareVaultApproval(fresh)
            XCTFail("removed account still authorized a request")
        } catch AppModel.AppError.sendReviewChanged { }
        do {
            _ = try await model.previewSend(to: person, amount: 20_000, priority: .medium,
                                            override: 2, accountID: records[0].id)
            XCTFail("missing account fell back to the ordinary wallet")
        } catch AppModel.VaultSpendError.unknownVault { }
    }
}
