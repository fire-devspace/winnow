// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Winnow",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "BitcoinCore", targets: ["BitcoinCore"]),
        .library(name: "WalletCore", targets: ["WalletCore"]),
        // Test fixtures shared by every test target, SwiftPM and Xcode alike.
        .library(name: "TestSupport", targets: ["TestSupport"]),
        .executable(name: "btc-swift", targets: ["BtcSwiftCLI"]),
        .executable(name: "winnow-debug", targets: ["WinnowDebug"]),
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
            name: "WalletCore",
            dependencies: ["BitcoinCore"]
        ),
        .executableTarget(
            name: "BtcSwiftCLI",
            dependencies: ["BitcoinCore", "WalletCore"]
        ),
        .executableTarget(
            name: "WinnowDebug",
            dependencies: ["BitcoinCore", "WalletCore"],
            path: "Tools/Debug/Sources/WinnowDebug"
        ),
        .target(
            name: "WinnowFuzzCore",
            dependencies: ["BitcoinCore", "WalletCore"],
            path: "Tools/Fuzz/Sources/WinnowFuzzCore"
        ),
        .executableTarget(
            name: "WinnowFuzz",
            dependencies: ["BitcoinCore", "WalletCore", "WinnowFuzzCore"],
            path: "Tools/Fuzz/Sources/WinnowFuzz"
        ),
        // Framework-agnostic fixtures (no Testing, no XCTest) so the
        // swift-testing targets below and the Xcode app test bundles share one
        // implementation. P256K: the signet miner signs block challenges.
        .target(
            name: "TestSupport",
            dependencies: ["BitcoinCore", "WalletCore",
                           .product(name: "P256K", package: "swift-secp256k1")],
            path: "Tests/Support",
            exclude: ["README.md"]
        ),
        .testTarget(
            name: "BitcoinCoreTests",
            // WalletCore supplies the shared wire/hex helpers.
            dependencies: ["BitcoinCore", "WalletCore", "TestSupport"],
            resources: [.copy("Vectors")]
        ),
        .testTarget(
            name: "WalletCoreTests",
            dependencies: ["WalletCore", "TestSupport"],
            resources: [.copy("Vectors")]
        ),
        .testTarget(
            name: "DifferentialTests",
            dependencies: ["BitcoinCore", "WalletCore", "TestSupport"],
            path: "Tests/DifferentialTests"
        ),
        // The development tools, tested together: the debugging commands, the
        // release-path generators, and the fuzz crash corpus replayed out of
        // `Cases`. One target, so a tool suite costs no more manifest than a
        // library one and `swift test` links the tools once.
        .testTarget(
            name: "ToolsTests",
            dependencies: ["WinnowDebug", "WinnowFuzzCore"],
            resources: [.copy("Cases")]
        ),
    ]
)
