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
        .executable(name: "btc-swift", targets: ["BtcSwiftCLI"]),
        .executable(name: "WinnowSoak", targets: ["WinnowSoak"]),
        .executable(name: "winnow-story", targets: ["WinnowStoryCLI"]),
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
        .executableTarget(
            name: "WinnowFuzz",
            dependencies: ["BitcoinCore", "BitcoinP2P", "WalletCore"],
            path: "Tools/Fuzz/Sources/WinnowFuzz"
        ),
        .testTarget(
            name: "WinnowStoryCLITests",
            dependencies: ["WinnowStoryCLI"],
            path: "Tools/Story/Tests/WinnowStoryCLITests"
        ),
        .testTarget(
            name: "BitcoinCoreTests",
            dependencies: ["BitcoinCore"],
            resources: [.copy("Vectors")]
        ),
        .testTarget(
            name: "BitcoinP2PTests",
            dependencies: ["BitcoinP2P", "BitcoinCore"],
            resources: [.copy("Vectors")]
        ),
        .testTarget(
            name: "WalletCoreTests",
            dependencies: ["WalletCore", "BitcoinP2P", "BlockchainBackend"],
            resources: [.copy("Vectors")]
        ),
        .testTarget(
            name: "DifferentialTests",
            dependencies: ["BitcoinCore", "BitcoinP2P", "WalletCore"],
            path: "Tests",
            exclude: ["BitcoinCoreTests", "BitcoinP2PTests", "WalletCoreTests"],
            sources: ["DifferentialTests", "NodeSupport"]
        ),
    ]
)
