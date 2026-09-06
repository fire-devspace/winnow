import BitcoinP2P
import Foundation

/// Fixtures shared across AppTests.

/// A signed transaction the broadcaster will accept, so a real relay entry can
/// be written and then damaged, confirmed or rolled back. Shaped like a signed
/// transaction rather than being one: nothing on this side checks a witness.
let signedTransactionBytes: Data = {
    var input = Transaction.Input(
        previousOutput: Transaction.Outpoint(txid: Data(repeating: 0x11, count: 32), vout: 0),
        scriptSig: Data(), sequence: 0xFFFF_FFFD)
    input.witness = [Data([0x30, 0x44, 0x02, 0x20]), Data(repeating: 0x02, count: 33)]
    let output = Transaction.Output(
        value: 50_000, scriptPubKey: Data([0x51, 0x20] + repeatElement(0x77, count: 32)))
    return Transaction(version: 2, inputs: [input], outputs: [output], locktime: 0)
        .serialized(includeWitness: true)
}()
