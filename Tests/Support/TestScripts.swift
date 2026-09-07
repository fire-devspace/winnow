import Foundation

/// Destination scripts and addresses the suites pay to or compare against.
public enum TestScripts {
    /// An external P2TR-shaped output (`OP_1 <32 × 0x99>`): the throwaway
    /// destination of a test send. A test that needs a *different* stranger
    /// picks its own byte.
    public static let p2trDestination = Data([0x51, 0x20] + repeatElement(0x99, count: 32))

    /// The official BIP86 vector for m/86'/0'/0'/0/0 of the test mnemonic.
    public static let bip86FirstMainnetAddress = "bc1p5cyxnuxmeuwuvkwfem96lqzszd02n6xdcjrs20cac6yqjjwudpxqkedrcr"
}
