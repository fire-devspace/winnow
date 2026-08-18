import BitcoinCore
import BitcoinP2P
import SwiftUI
import UIKit
import WalletCore

/// Signer/combiner/finalizer roles for vault spends (BIP370/371/373).
///
/// multi_a k-of-n: collect partial-signed PSBTs, sign with this device's key,
/// combine when every input carries k signatures, finalize → broadcast.
///
/// MuSig2 n-of-n: round 1 attaches this device's public nonce (the secret
/// nonces stay in this screen's memory — leaving before round 2 abandons the
/// session), cosigners' nonce-bearing PSBTs are combined, round 2 signs,
/// partials are combined, aggregated → broadcast.
struct VaultSignView: View {
    let recordID: String
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    enum SignError: LocalizedError {
        case unknownInput
        case noWorkingPSBT

        var errorDescription: String? {
            switch self {
            case .unknownInput: "An input of this PSBT is not a known UTXO of the vault."
            case .noWorkingPSBT: "Add a PSBT first."
            }
        }
    }

    @State private var pasted = ""
    @State private var working: PSBT?
    @State private var output: String?
    @State private var error: String?
    @State private var broadcastTxid: Data?
    @State private var broadcasting = false
    /// MuSig2 round-1 secret nonces per input (participant pubkey → secnonce).
    /// Never persisted, never shown — zeroed by round 2.
    @State private var secretNonces: [Int: [Data: Data]] = [:]
    /// Round transitions are explicit so a completed signer cannot attach a
    /// second nonce or sign twice while this sheet remains open.
    @State private var nonceSessionStarted = false
    @State private var signedMuSig2ThisSession = false

    private var record: VaultRecord? { model.vaults.first { $0.id == recordID } }
    private var vault: Vault? { record.flatMap { try? Vault($0.descriptor, network: model.network) } }

    private var threshold: Int? {
        guard case let .multiA(k, _, _, _) = vault?.policy else { return nil }
        return k
    }

    private var participantCount: Int? {
        guard case let .muSig2(participants, _) = vault?.policy else { return nil }
        return participants.count
    }

    /// The lowest per-input count — the spend is ready only when every input is.
    private var minSignatures: Int { working?.inputs.map(\.tapScriptSignatures.count).min() ?? 0 }
    private var minNonces: Int { working?.inputs.map(\.musig2PubNonces.count).min() ?? 0 }
    private var minPartialSigs: Int { working?.inputs.map(\.musig2PartialSigs.count).min() ?? 0 }
    private var workingInputsRemainAvailable: Bool {
        guard let working, let record else { return false }
        return working.inputs.allSatisfy { input in
            guard let txid = input.previousTxid, let vout = input.outputIndex else { return false }
            return record.utxos.contains { $0.txid == txid && $0.vout == vout }
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Paste a PSBT (Base64)", text: $pasted)
                        .font(.system(.caption, design: .monospaced))
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .accessibilityIdentifier("psbtField")
                    Button("Paste from clipboard") {
                        pasted = UIPasteboard.general.string ?? ""
                    }
                    .accessibilityIdentifier("psbtPasteButton")
                    Button("Add / combine PSBT") { addPasted() }
                        .accessibilityIdentifier("addPSBTButton")
                        .disabled(pasted.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                } footer: {
                    Text("The first PSBT becomes the working copy; further PSBTs are combined into it (BIP174 combiner role).")
                }

                if working != nil {
                    reviewSection
                    progressSection
                    actionsSection
                }

                if let error {
                    Section { Text(error).foregroundStyle(.red).font(.footnote) }
                }

                if let output {
                    Section("PSBT to share") {
                        CopyableTextBlock(text: output)
                    }
                }

                if let broadcastTxid {
                    Section {
                        Label("Broadcast", systemImage: "checkmark.seal")
                            .foregroundStyle(.green)
                        Text(broadcastTxid.displayHex)
                            .font(.system(.caption2, design: .monospaced))
                            .textSelection(.enabled)
                        Text("A filter match will confirm it in a block; the vault's balance updates then.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Sign / combine")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    // MARK: - Review (what you are signing)

    private struct OutputLine {
        let destination: String
        let amount: Int64
        let isChange: Bool
    }

    private var hrp: String { model.network == .mainnet ? "bc" : "tb" }

    /// Best-effort scriptPubKey → address; falls back to hex for non-standard
    /// scripts so an unrecognized destination is shown, never hidden.
    private func destination(forScript script: Data) -> String {
        guard script.count >= 4, let first = script.first else { return script.hex }
        let version: Int? = first == 0x00 ? 0 : (first >= 0x51 && first <= 0x60 ? Int(first) - 0x50 : nil)
        guard let version else { return script.hex }
        let pushLength = Int(script[script.index(script.startIndex, offsetBy: 1)])
        let program = Data(script.dropFirst(2))
        guard program.count == pushLength, (2 ... 40).contains(program.count),
              let address = try? SegwitAddress.encode(hrp: hrp, version: version, program: program)
        else { return script.hex }
        return address
    }

    /// Outputs the spend pays. A non-empty output key-derivation marks the
    /// vault's own change; everything else is money leaving the vault.
    private var outputLines: [OutputLine] {
        guard let working else { return [] }
        return working.outputs.map {
            OutputLine(destination: destination(forScript: $0.script ?? Data()),
                       amount: $0.amount ?? 0,
                       isChange: !$0.tapBIP32Derivation.isEmpty)
        }
    }

    /// Fee is known only when every input carries its witnessUTXO amount.
    private var inputAmountsKnown: Bool {
        (working?.inputs.allSatisfy { $0.witnessUTXO != nil }) ?? false
    }

    private var feeAmount: Int64? {
        guard let working, inputAmountsKnown else { return nil }
        let inputs = working.inputs.compactMap { $0.witnessUTXO?.amount }.reduce(0, +)
        let outputs = outputLines.reduce(0) { $0 + $1.amount }
        return inputs - outputs
    }

    private var sighashRaw: UInt32 { working?.inputs.first?.sighashType ?? 0 }
    private var sighashSafe: Bool { sighashRaw == 0 || sighashRaw == 1 }
    private var sighashLabel: String {
        switch sighashRaw {
        case 0: "DEFAULT — commits to all outputs"
        case 1: "ALL — commits to all outputs"
        default: "UNUSUAL (0x\(String(sighashRaw, radix: 16))) — does not commit to all outputs"
        }
    }

    @ViewBuilder
    private var reviewSection: some View {
        Section {
            ForEach(outputLines.indices, id: \.self) { index in
                let line = outputLines[index]
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text(line.isChange ? "Change (this vault)" : "Pays")
                            .font(.caption)
                            .foregroundStyle(line.isChange ? Color.secondary : Color.primary)
                        Spacer()
                        Text("\(line.amount) sat")
                            .font(.system(.callout, design: .monospaced))
                    }
                    Text(line.destination)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                .padding(.vertical, 1)
            }
            if let feeAmount {
                LabeledContent("Fee", value: "\(feeAmount) sat")
            } else {
                LabeledContent("Fee", value: "unavailable (missing input amounts)")
            }
            LabeledContent("Sighash") {
                Text(sighashLabel)
                    .font(.footnote)
                    .foregroundStyle(sighashSafe ? Color.secondary : Color.red)
                    .multilineTextAlignment(.trailing)
            }
        } header: {
            Text("Review — what you are signing")
        } footer: {
            Text("A cosigner can propose any transaction. Your signature authorizes exactly these outputs — verify every destination and the fee before signing.")
        }
    }

    @ViewBuilder
    private var progressSection: some View {
        if let threshold {
            Section("Progress") {
                LabeledContent("Signatures", value: "\(minSignatures) of \(threshold) per input")
            }
        } else if let participantCount {
            Section("Progress") {
                LabeledContent("Public nonces", value: "\(minNonces) of \(participantCount) per input")
                LabeledContent("Partial signatures", value: "\(minPartialSigs) of \(participantCount) per input")
                if !secretNonces.isEmpty {
                    Text("This device's secret nonces live only on this screen — leaving before round 2 abandons the session.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
        }
    }

    @ViewBuilder
    private var actionsSection: some View {
        if let threshold {
            Section("Actions") {
                Button("Sign with this device") { signMultiA() }
                    .disabled(!workingInputsRemainAvailable || broadcastTxid != nil)
                Button(broadcasting ? "Broadcasting…" : "Finalize & broadcast") {
                    finalizeAndBroadcast()
                }
                .disabled(minSignatures < threshold || !workingInputsRemainAvailable
                    || broadcasting || broadcastTxid != nil)
                if !workingInputsRemainAvailable {
                    stalePSBTMessage
                }
            }
        } else if let participantCount {
            Section("Actions") {
                Button("Round 1 — attach this device's nonce") { attachNonces() }
                    .disabled(nonceSessionStarted || minNonces >= participantCount
                        || minPartialSigs > 0 || !workingInputsRemainAvailable
                        || broadcastTxid != nil)
                Button("Round 2 — sign with this device") { signMuSig2() }
                    .disabled(!nonceSessionStarted || signedMuSig2ThisSession
                        || secretNonces.isEmpty || minNonces < participantCount
                        || minPartialSigs >= participantCount || !workingInputsRemainAvailable)
                Button(broadcasting ? "Broadcasting…" : "Aggregate & broadcast") {
                    aggregateAndBroadcast()
                }
                .disabled(minPartialSigs < participantCount || !workingInputsRemainAvailable
                    || broadcasting || broadcastTxid != nil)
                if !workingInputsRemainAvailable {
                    stalePSBTMessage
                }
            }
        }
    }

    private var stalePSBTMessage: some View {
        Text("This PSBT's input is no longer available. It may already have been spent; create a new PSBT instead.")
            .font(.footnote)
            .foregroundStyle(.orange)
    }

    private func addPasted() {
        error = nil
        do {
            let incoming = try PSBT(base64: pasted.trimmingCharacters(in: .whitespacesAndNewlines))
            working = try working?.combined(with: [incoming]) ?? incoming
            if let working { model.journalPSBT(stage: "vault-psbt-combined", psbt: working) }
            pasted = ""
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// The vault coordinates (multipath choice, index) of a PSBT input, found
    /// via the vault's UTXO set — the PSBT itself carries only the outpoint.
    private func context(for input: PSBT.Input, vault: Vault, record: VaultRecord) throws -> Vault.MuSig2Context {
        guard let txid = input.previousTxid, let vout = input.outputIndex,
              let utxo = record.utxos.first(where: { $0.txid == txid && $0.vout == vout })
        else { throw SignError.unknownInput }
        return try vault.muSig2Context(choice: utxo.chain.rawValue, index: utxo.index)
    }

    // MARK: - multi_a

    private func signMultiA() {
        guard var psbt = working, let vault else { error = SignError.noWorkingPSBT.localizedDescription; return }
        do {
            try model.withMasterKey { try vault.partialSign(&psbt, master: $0) }
            working = psbt
            output = psbt.base64
            model.journalPSBT(stage: "multi-a-partial-signed", psbt: psbt)
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func finalizeAndBroadcast() {
        guard !broadcasting, broadcastTxid == nil,
              var psbt = working, let vault, let record else { return }
        broadcasting = true
        Task {
            defer { broadcasting = false }
            do {
                let transaction = try vault.finalizeSpend(&psbt)
                try await commitAndBroadcast(transaction, vault: vault, record: record)
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    // MARK: - MuSig2

    private func attachNonces() {
        guard var psbt = working, let vault, let record else { error = SignError.noWorkingPSBT.localizedDescription; return }
        do {
            var nonces: [Int: [Data: Data]] = [:]
            for index in psbt.inputs.indices {
                let context = try context(for: psbt.inputs[index], vault: vault, record: record)
                nonces[index] = try model.withMasterKey {
                    try vault.muSig2AttachNonce(&psbt, input: index, context: context, master: $0)
                }
            }
            secretNonces = nonces
            nonceSessionStarted = true
            working = psbt
            output = psbt.base64
            model.journalPSBT(stage: "musig2-public-nonces", psbt: psbt)
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func signMuSig2() {
        guard var psbt = working, let vault, let record else { return }
        do {
            // Stage the nonce mutations alongside the PSBT. If a later input
            // fails, the visible working copy and the in-memory nonce session
            // both remain retryable instead of becoming half-consumed.
            var stagedNonces = secretNonces
            for index in psbt.inputs.indices {
                let context = try context(for: psbt.inputs[index], vault: vault, record: record)
                var nonces = stagedNonces[index] ?? [:]
                try model.withMasterKey {
                    try vault.muSig2Sign(&psbt, input: index, context: context, master: $0,
                                         secretNonces: &nonces)
                }
                stagedNonces[index] = nonces // zeroed by partialSign
            }
            working = psbt
            output = psbt.base64
            secretNonces.removeAll(keepingCapacity: false)
            signedMuSig2ThisSession = true
            model.journalPSBT(stage: "musig2-partial-signed", psbt: psbt)
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func aggregateAndBroadcast() {
        guard !broadcasting, broadcastTxid == nil,
              var psbt = working, let vault, let record else { return }
        broadcasting = true
        Task {
            defer { broadcasting = false }
            do {
                for index in psbt.inputs.indices {
                    let context = try context(for: psbt.inputs[index], vault: vault, record: record)
                    try vault.muSig2Aggregate(&psbt, input: index, context: context)
                }
                model.journalPSBT(stage: "musig2-aggregated", psbt: psbt)
                let transaction = try vault.finalizeSpend(&psbt)
                try await commitAndBroadcast(transaction, vault: vault, record: record)
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    // MARK: - Broadcast

    /// Broadcasts the finalized spend and commits it to the vault's local
    /// UTXO set (inputs out, change in pending — the `Wallet.send` rule).
    private func commitAndBroadcast(_ transaction: BitcoinTransaction, vault: Vault,
                                    record: VaultRecord) async throws {
        let txid = try await model.broadcast(transaction)
        let changeIndex = record.nextChangeIndex
        let changeScript = try? vault.scriptPubKey(index: changeIndex, choice: AddressChain.change.rawValue)
        _ = await model.recordVaultSpend(id: record.id, transaction: transaction,
                                         changeScriptPubKey: changeScript, changeIndex: changeIndex)
        broadcastTxid = txid
    }
}
