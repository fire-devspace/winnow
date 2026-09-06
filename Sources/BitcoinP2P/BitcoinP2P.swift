/// BitcoinP2P — pure-P2P networking for Winnow (Phase 3).
///
/// - ``Protocol``: wire format (framing, varint, network addresses, inv,
///   tx/block, all message payloads incl. BIP157/158) and network params.
/// - ``PeerConnection``: one peer over `Network.framework`, handshake with
///   mandatory NODE_COMPACT_FILTERS, request/response correlation, keepalive.
/// - ``PeerPool``: discovery (DNS seeds, manual, persisted good peers),
///   N outbound connections with replacement.
/// - ``HeaderChain``: PoW-checked headers-only chain synced via getheaders.
/// - ``FilterSync``: BIP157 compact-filter scan, forward-only from a start
///   height (see docs/read-side.md).
/// - ``TxBroadcaster``: inv/getdata relay until confirmed.
public enum BitcoinP2P {
    public static let version = "0.1"
}
