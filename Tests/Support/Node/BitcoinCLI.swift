import BitcoinP2P
import Foundation

/// Process-based `bitcoin-cli` runner for the dev custom-signet node
/// (default datadir ~/.bitcoin-mysignet, RPC :38400, P2P :38401 on
/// 127.0.0.1), plus the JSON accessors the differential checks lean on.
///
/// Shared by the SwiftPM differential and Xcode UI test targets through the
/// TestSupport library.
///
/// Node location is env-configurable (CI runners reach the node over
/// LAN/Tailscale, not loopback); the defaults reproduce the local dev setup
/// exactly:
/// - WINNOW_NODE_HOST — RPC/P2P host (default 127.0.0.1)
/// - WINNOW_P2P_PORT  — P2P port (default 38401)
/// - WINNOW_RPC_PORT  — RPC port (default 38400)
/// - WINNOW_DATADIR   — datadir for cookie auth (default ~/.bitcoin-mysignet)
/// - WINNOW_BITCOIN_CLI — full path to bitcoin-cli (default: the first hit
///   in `searchPaths`, which covers both Homebrew prefixes and MacPorts)
///
/// Inside the simulator the process environment is NOT inherited from
/// xcodebuild; the same keys are then read from ~/.winnow-node.env on the
/// host (see env(_:) below).
///
/// Everything here is read-only against the node EXCEPT `generatetoaddress`
/// mining on the disposable custom signet, which is expected and safe.
public enum BitcoinCLI {
    /// The node's BIP325 signet challenge (hex); its signing key lives in the
    /// "miner" wallet of the same datadir.
    public static let challengeHex =
        "512102d4d3dfe322ab358061c7e08beebb48dc06a4c175342b975ecd0d55a79e6d6cdc51ae"
    public static let challenge = Data(hex: challengeHex)!

    /// The HOST home directory: inside the iOS simulator NSHomeDirectory()
    /// is the test runner's container; the node datadir lives in the real
    /// user home.
    public static var hostHome: String {
        ProcessInfo.processInfo.environment["SIMULATOR_HOST_HOME"] ?? NSHomeDirectory()
    }

    /// An environment override; empty values count as unset. `xcodebuild
    /// test` does NOT forward its process environment into the iOS-simulator
    /// test runner, so the harness also reads KEY=VALUE lines from
    /// ~/.winnow-node.env on the host (CI writes it before the UI run).
    private static func env(_ key: String) -> String? {
        if let value = ProcessInfo.processInfo.environment[key], !value.isEmpty { return value }
        #if targetEnvironment(simulator)
        return fileOverrides[key]
        #else
        return nil
        #endif
    }

    /// The same lookup for suites that gate on an environment flag of their
    /// own (the storefront capture): process environment first, then
    /// ~/.winnow-node.env.
    public static func environmentValue(_ key: String) -> String? { env(key) }

    private static let fileOverrides: [String: String] = {
        let url = URL(fileURLWithPath: hostHome).appending(path: ".winnow-node.env")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [:] }
        var result: [String: String] = [:]
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: "=", maxSplits: 1)
            let key = String(parts[0]).trimmingCharacters(in: .whitespaces)
            let value = parts.count == 2 ? String(parts[1]).trimmingCharacters(in: .whitespaces) : ""
            if !key.isEmpty, !value.isEmpty { result[key] = value }
        }
        return result
    }()

    public static let nodeHost = env("WINNOW_NODE_HOST") ?? "127.0.0.1"
    public static let p2pPort: UInt16 = env("WINNOW_P2P_PORT").flatMap { UInt16($0) } ?? 38_401
    public static let rpcPort = env("WINNOW_RPC_PORT").flatMap { Int($0) } ?? 38_400
    public static let datadir = env("WINNOW_DATADIR") ?? "\(hostHome)/.bitcoin-mysignet"

    public struct CLIError: Error, CustomStringConvertible, Equatable {
        public let arguments: [String]
        public let status: Int32
        public let output: String

        public var description: String {
            "bitcoin-cli \(arguments.joined(separator: " ")) failed (\(status)): \(output)"
        }
    }

    /// bitcoin-util binary (same install as bitcoin-cli), used for PoW grinding.
    public static var bitcoinUtilPath: String? {
        if let cli = binaryPath {
            let util = (cli as NSString).deletingLastPathComponent + "/bitcoin-util"
            if FileManager.default.isExecutableFile(atPath: util) { return util }
        }
        return nil
    }

    /// Directories probed for the node binaries, in order: Homebrew on Apple
    /// Silicon, Homebrew on Intel, MacPorts. Both Homebrew prefixes matter —
    /// the CI runners are x86_64 (`/usr/local`) while every dev machine here
    /// is arm64 (`/opt/homebrew`), and hardcoding the arm64 one is what made
    /// the UI suite unable to find an installed bitcoin-cli on runner-1
    /// (#31). Override with WINNOW_BITCOIN_CLI (a full path to the binary).
    public static let searchPaths = ["/opt/homebrew/bin", "/usr/local/bin", "/opt/local/bin"]

    /// bitcoin-cli binary: WINNOW_BITCOIN_CLI, else the first hit in
    /// `searchPaths`.
    ///
    /// The simulator uses explicit host paths. Native macOS tests also search
    /// PATH so a locally installed node need not live in a Homebrew prefix.
    public static var binaryPath: String? {
        if let override = env("WINNOW_BITCOIN_CLI"),
           FileManager.default.isExecutableFile(atPath: override) { return override }
        var directories = searchPaths
        #if os(macOS)
        directories += (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
        #endif
        return directories
            .map { $0 + "/bitcoin-cli" }
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Runs `bitcoin-cli` with the node selection flags prepended; returns the
    /// trimmed stdout. Throws `CLIError` on a non-zero exit.
    @discardableResult
    public static func run(_ arguments: [String], wallet: String? = nil) throws -> String {
        guard let binary = binaryPath else {
            throw CLIError(arguments: arguments, status: -1,
                           output: "bitcoin-cli not found in \(searchPaths.joined(separator: ", "))"
                               + " (set WINNOW_BITCOIN_CLI to a full path, or add it to"
                               + " \(hostHome)/.winnow-node.env, to override)")
        }
        var full = ["-datadir=\(datadir)", "-rpcport=\(rpcPort)", "-rpcconnect=\(nodeHost)"]
        if let wallet { full.append("-rpcwallet=\(wallet)") }
        full.append(contentsOf: arguments)

        let result = try HostProcess.run(binary, full)
        let out = result.stdout
        guard result.status == 0 else {
            throw CLIError(arguments: arguments, status: result.status,
                           output: (out + result.stderr).trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Runs a JSON-producing command; nil for empty output, the raw string
    /// for non-JSON results (e.g. a bare `submitblock` reject reason).
    public static func runJSON(_ arguments: [String], wallet: String? = nil) throws -> Any? {
        let output = try run(arguments, wallet: wallet)
        guard !output.isEmpty else { return nil }
        // Bare scalars/unquoted text (submitblock rejections) come back raw.
        return (try? JSONSerialization.jsonObject(with: Data(output.utf8),
                                                  options: [.fragmentsAllowed])) ?? output
    }

    public static func runObject(_ arguments: [String], wallet: String? = nil) throws -> [String: Any] {
        guard let object = try runJSON(arguments, wallet: wallet) as? [String: Any] else {
            throw CLIError(arguments: arguments, status: -1, output: "expected a JSON object")
        }
        return object
    }

    // MARK: - Convenience accessors for loosely-typed RPC JSON

    public static func string(_ object: [String: Any], _ key: String) throws -> String {
        guard let value = object[key] as? String else {
            throw CLIError(arguments: [key], status: -1, output: "missing string field \(key)")
        }
        return value
    }

    public static func int(_ object: [String: Any], _ key: String) throws -> Int {
        guard let value = object[key] as? NSNumber else {
            throw CLIError(arguments: [key], status: -1, output: "missing numeric field \(key)")
        }
        return value.intValue
    }

    public static func array(_ object: [String: Any], _ key: String) throws -> [Any] {
        guard let value = object[key] as? [Any] else {
            throw CLIError(arguments: [key], status: -1, output: "missing array field \(key)")
        }
        return value
    }

    /// A BTC-amount JSON number as exact sats (Core prints 8 decimals).
    public static func sats(_ value: Any) throws -> Int64 {
        guard let number = value as? NSNumber else {
            throw CLIError(arguments: ["amount"], status: -1, output: "expected numeric amount")
        }
        return Int64((number.doubleValue * 100_000_000).rounded())
    }

    // MARK: - Node facts

    public static func blockCount() throws -> Int {
        try Int(run(["getblockcount"]))!
    }

    public static func blockHash(at height: Int) throws -> String {
        try run(["getblockhash", String(height)])
    }

    public static func bestBlockHash() throws -> String {
        try run(["getbestblockhash"])
    }

    /// The scriptPubKey (hex) paid by output `vout` of `txid` (txindex on).
    public static func spentScript(txid: String, vout: Int) throws -> String {
        let tx = try runObject(["getrawtransaction", txid, "true"])
        let vouts = try array(tx, "vout")
        let output = vouts[vout] as! [String: Any]
        let scriptPubKey = output["scriptPubKey"] as! [String: Any]
        return scriptPubKey["hex"] as! String
    }

    /// A fresh bech32m address from the node's "miner" wallet (send target).
    public static func newMinerAddress() throws -> String {
        try run(["getnewaddress", "e2e", "bech32m"], wallet: "miner")
    }

    // MARK: - A spending wallet on the node

    /// Loads or creates a keyed descriptor wallet on the node. The fixture's
    /// "miner" wallet is blank (signing key only), so a suite that wants the
    /// node to *pay* the app needs a wallet of its own.
    public static func ensureWallet(_ name: String) throws {
        if try run(["listwallets"]).contains("\"\(name)\"") { return }
        if (try? run(["loadwallet", name])) != nil { return }
        try run(["-named", "createwallet", "wallet_name=\(name)"])
    }

    /// A fresh bech32m address from `wallet`.
    public static func newAddress(wallet: String) throws -> String {
        try run(["getnewaddress", "", "bech32m"], wallet: wallet)
    }

    /// `wallet`'s trusted (spendable, confirmed) balance in sats.
    public static func trustedBalanceSats(wallet: String) throws -> Int64 {
        let balances = try runObject(["getbalances"], wallet: wallet)
        guard let mine = balances["mine"] as? [String: Any], let trusted = mine["trusted"] else { return 0 }
        return try sats(trusted)
    }

    /// Pays `sats` to `address` from `wallet` at `feeRate` sat/vB; returns
    /// the txid. Amounts are formatted from integers, never through Double.
    @discardableResult
    public static func sendToAddress(wallet: String, address: String, sats: Int64, feeRate: Int) throws -> String {
        let amount = "\(sats / 100_000_000)." + String(format: "%08d", sats % 100_000_000)
        return try run(["-named", "sendtoaddress", "address=\(address)", "amount=\(amount)",
                        "fee_rate=\(feeRate)"], wallet: wallet)
    }

    /// (txid, value in sats, scriptPubKey hex) of a transaction's output 0.
    public static func outputZero(txid: String) throws -> (txid: String, amount: Int64, scriptPubKey: String) {
        let tx = try runObject(["getrawtransaction", txid, "true"])
        let vouts = try array(tx, "vout")
        guard let output = vouts.first as? [String: Any],
              let scriptPubKey = output["scriptPubKey"] as? [String: Any],
              let hex = scriptPubKey["hex"] as? String, let value = output["value"]
        else { throw CLIError(arguments: ["getrawtransaction"], status: -1, output: "no vout 0") }
        return (txid, try sats(value), hex)
    }

    /// The coinbase txid of a block.
    public static func coinbaseTxid(blockHash: String) throws -> String {
        let block = try runObject(["getblock", blockHash])
        let txs = try array(block, "tx")
        guard let txid = txs.first as? String else {
            throw CLIError(arguments: ["getblock"], status: -1, output: "no coinbase")
        }
        return txid
    }

    /// The height a block was accepted at.
    public static func blockHeight(of blockHash: String) throws -> Int {
        try int(runObject(["getblock", blockHash]), "height")
    }

    /// Current mempool txids (display hex).
    public static func mempoolTxids() throws -> [String] {
        (try runJSON(["getrawmempool"]) as? [String]) ?? []
    }

    /// Unspent outputs paying a scriptPubKey (hex), from the node's UTXO set.
    public static func unspents(scriptHex: String) throws
        -> [(txid: String, vout: UInt32, amount: Int64, height: UInt32)] {
        let result = try runObject(["scantxoutset", "start", "[\"raw(\(scriptHex))\"]"])
        return try array(result, "unspents").compactMap { entry in
            guard let object = entry as? [String: Any], let value = object["amount"] else { return nil }
            return (try string(object, "txid"), UInt32(try int(object, "vout")),
                    try sats(value), UInt32(try int(object, "height")))
        }
    }
}
