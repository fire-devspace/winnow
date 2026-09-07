// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Winnow",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "BitcoinCore", targets: ["BitcoinCore"]),
        .library(name: "BitcoinP2P", targets: ["BitcoinP2P"]),
        .library(name: "BlockchainBackend", targets: ["BlockchainBackend"]),
        .library(name: "WalletCore", targets: ["WalletCore"]),
        // Test fixtures shared by every test target, SwiftPM and Xcode alike.
        .library(name: "TestSupport", targets: ["TestSupport"]),
        .executable(name: "btc-swift", targets: ["BtcSwiftCLI"]),
        .executable(name: "WinnowSoak", targets: ["WinnowSoak"]),
        .executable(name: "winnow-story", targets: ["WinnowStoryCLI"]),
        .executable(name: "winnow-generate", targets: ["WinnowGenerate"]),
        .executable(name: "WinnowFuzz", targets: ["WinnowFuzz"]),
    ],
    dependencies: [
        .package(url: "https://github.com/21-DOT-DEV/swift-secp256k1", exact: "0.23.2"),
    ],
    targets: [
        .target(
            name: "BitcoinCore",
            dependencies: [.product(name: "P256K", package: "swift-secp256k1")]
        ),
        .target(
            name: "BitcoinP2P",
            dependencies: ["BitcoinCore"]
        ),
        .target(
            name: "BlockchainBackend",
            dependencies: ["BitcoinCore"]
        ),
        .target(
            name: "WalletCore",
            dependencies: ["BitcoinCore", "BitcoinP2P", "BlockchainBackend"]
        ),
        .executableTarget(
            name: "BtcSwiftCLI",
            dependencies: ["BitcoinCore", "BitcoinP2P", "WalletCore"]
        ),
        .executableTarget(
            name: "WinnowSoak",
            dependencies: ["BitcoinCore", "BitcoinP2P"]
        ),
        .executableTarget(
            name: "WinnowStoryCLI",
            dependencies: ["BitcoinCore", "BitcoinP2P", "BlockchainBackend", "WalletCore"],
            path: "Tools/Story/Sources/WinnowStoryCLI"
        ),
        .target(
            name: "WinnowFuzzCore",
            dependencies: ["BitcoinCore", "BitcoinP2P", "WalletCore"],
            path: "Tools/Fuzz/Sources/WinnowFuzzCore"
        ),
        .executableTarget(
            name: "WinnowGenerate",
            dependencies: ["BitcoinCore", "BitcoinP2P"],
            path: "Tools/Generate/Sources/WinnowGenerate"
        ),
        .executableTarget(
            name: "WinnowFuzz",
            dependencies: ["BitcoinCore", "BitcoinP2P", "WinnowFuzzCore"],
            path: "Tools/Fuzz/Sources/WinnowFuzz"
        ),
        // Framework-agnostic fixtures (no Testing, no XCTest) so the
        // swift-testing targets below and the Xcode app test bundles share one
        // implementation. P256K: the signet miner signs block challenges.
        .target(
            name: "TestSupport",
            dependencies: ["BitcoinCore", "BitcoinP2P", "WalletCore",
                           .product(name: "P256K", package: "swift-secp256k1")],
            path: "Tests/Support",
            exclude: ["README.md"]
        ),
        .testTarget(
            name: "BitcoinCoreTests",
            // BitcoinP2P only for its public `Data(hex:)` / `.hex` helpers.
            dependencies: ["BitcoinCore", "BitcoinP2P", "TestSupport"],
            resources: [.copy("Vectors")]
        ),
        .testTarget(
            name: "BitcoinP2PTests",
            dependencies: ["BitcoinP2P", "BitcoinCore", "TestSupport"],
            resources: [.copy("Vectors")]
        ),
        // The esplora client and what it discloses belong to BlockchainBackend;
        // they were only ever `@testable import`ed from the WalletCore suite.
        .testTarget(
            name: "BlockchainBackendTests",
            dependencies: ["BlockchainBackend"]
        ),
        .testTarget(
            name: "WalletCoreTests",
            dependencies: ["WalletCore", "BitcoinP2P", "TestSupport"],
            resources: [.copy("Vectors")]
        ),
        .testTarget(
            name: "DifferentialTests",
            dependencies: ["BitcoinCore", "BitcoinP2P", "WalletCore", "TestSupport"],
            path: "Tests/DifferentialTests"
        ),
        // The development tools, tested together: the story runner, the
        // release-path generators, and the fuzz crash corpus replayed out of
        // `Cases`. One target, so a tool suite costs no more manifest than a
        // library one and `swift test` links the tools once.
        .testTarget(
            name: "ToolsTests",
            dependencies: ["WinnowStoryCLI", "WinnowGenerate", "WinnowFuzzCore"],
            resources: [.copy("Cases")]
        ),
    ]
)
