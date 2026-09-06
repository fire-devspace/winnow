// swift-tools-version: 6.0
import PackageDescription

// App-owned acceptance tooling, kept outside the shipping app target.
// Use the same published library version as project.yml.
let package = Package(
    name: "winnow-story",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "winnow-story", targets: ["WinnowStoryCLI"]),
    ],
    dependencies: [
        .package(url: "https://github.com/winnowwallet/btc-swift", exact: "0.1.0"),
    ],
    targets: [
        .executableTarget(
            name: "WinnowStoryCLI",
            dependencies: [
                .product(name: "BitcoinCore", package: "btc-swift"),
                .product(name: "BitcoinP2P", package: "btc-swift"),
                .product(name: "BlockchainBackend", package: "btc-swift"),
                .product(name: "WalletCore", package: "btc-swift"),
            ]
        ),
        .testTarget(
            name: "WinnowStoryCLITests",
            dependencies: ["WinnowStoryCLI"]
        ),
    ]
)
