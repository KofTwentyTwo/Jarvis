// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Keychain",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "Keychain", targets: ["Keychain"]),
    ],
    dependencies: [],
    targets: [
        .target(
            name: "Keychain",
            dependencies: [],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "KeychainTests",
            dependencies: ["Keychain"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
