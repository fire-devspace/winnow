import Foundation
import Testing
@testable import BlockchainBackend

/// Esplora model decoding + client shape. No network: the client must only
/// ever be contacted with an explicit base URL, which tests never provide.
@Suite("Esplora client")
struct EsploraClientTests {
    @Test("UTXO decoding (esplora /address/{a}/utxo shape)")
    func utxoDecoding() throws {
        let json = """
        [{
          "txid": "4a5e1e4baab89f3a32518a88c31bc87f618f76673e2cc77ab2127b7afdeda33b",
          "vout": 0,
          "status": {
            "confirmed": true,
            "block_height": 170,
            "block_hash": "00000000d1145790a8694403d4063f323d499e655c83426834d4ce2f8dd4a2ee",
            "block_time": 1231731025
          },
          "value": 5000000000
        }]
        """
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let utxos = try decoder.decode([EsploraUTXO].self, from: Data(json.utf8))
        #expect(utxos.count == 1)
        #expect(utxos[0].value == 5_000_000_000)
        #expect(utxos[0].status.confirmed)
        #expect(utxos[0].status.blockHeight == 170)
    }

    @Test("transaction decoding (esplora /address/{a}/txs shape)")
    func transactionDecoding() throws {
        let json = """
        {
          "txid": "0e3e2357e806b6cdb1f70b54c3a3a17b6714ee1f0e68bebb44a74b1efd512098",
          "version": 1,
          "locktime": 0,
          "size": 134,
          "weight": 536,
          "fee": 0,
          "vin": [{
            "txid": "4a5e1e4baab89f3a32518a88c31bc87f618f76673e2cc77ab2127b7afdeda33b",
            "vout": 0,
            "prevout": null,
            "scriptsig": "04ffff001d0104",
            "witness": []
          }],
          "vout": [{
            "scriptpubkey": "5120339ce7e165e8d6b16e6e2b5b1f7c5c1dbb3b53a4d1b44e26b6c20c31b1d4c8f7",
            "scriptpubkey_address": "bc1pxwww0ct9art3dmhz9dd37lzurkanr54y6x6yuf4kcgxrrvw50dqyhzfsjx",
            "value": 100000
          }],
          "status": { "confirmed": false }
        }
        """
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let tx = try decoder.decode(EsploraTransaction.self, from: Data(json.utf8))
        #expect(tx.vout.count == 1)
        #expect(tx.vout[0].value == 100_000)
        #expect(tx.vout[0].scriptpubkeyAddress?.hasPrefix("bc1p") == true)
        #expect(!tx.status.confirmed)
    }

    @Test("well-known presets exist but nothing is contacted without init")
    func presets() {
        #expect(EsploraClient.mempoolSpaceMainnet.host == "mempool.space")
        #expect(EsploraClient.mempoolSpaceSignet.absoluteString.contains("signet"))
        #expect(EsploraClient.blockstreamMainnet.host == "blockstream.info")
        let client = EsploraClient(baseURL: EsploraClient.mempoolSpaceSignet)
        #expect(client.baseURL == EsploraClient.mempoolSpaceSignet)
    }
}
