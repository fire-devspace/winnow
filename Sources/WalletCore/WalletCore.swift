/// WalletCore — the single-sig Taproot wallet (Phase 4), end-to-end on top of
/// BitcoinCore (keys/scripts/descriptors) and BitcoinP2P (wire model, filter
/// sync, broadcast). Design papers in docs/ (mobile, read, write, vaults, import).
///
/// - ``KeyStore`` / ``InMemoryKeyStore`` / ``KeychainStore``: secret storage
///   (BIP39 mnemonic or master xprv), this-device-only.
/// - ``SighashBIP341``: the BIP341 signature hash for key-path spends.
/// - ``TransactionBuilder`` / ``AddressDecoder`` / ``Payment``: unsigned tx
///   construction paying any standard address type.
/// - ``Signer``: BIP86 tweaked-key BIP340 signing → fully-signed raw txs.
/// - ``PSBT``: PSBTv2 (BIP370) + BIP371 Taproot fields; creator/signer/
///   finalizer/extractor roles.
/// - ``Wallet``: the aggregate — BIP86 multipath descriptor, gap-limited
///   watch list, forward-only ``FilterSync`` scanning → UTXO set + history,
///   JSON persistence, send pipeline.
/// - ``ImportBundle`` / ``ImportReport``: export and import with history,
///   verified by forward-scanning from the bundle height (docs/import.md).
/// - ``CoinSelection`` / ``FeePolicy``: largest-first selection with dust
///   guard; feefilter-floor/observed/preset/override feerate resolution.
public enum WalletCore {
    public static let version = "0.1"
}
