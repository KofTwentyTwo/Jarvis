// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Config",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "Config", targets: ["Config"]),
    ],
    dependencies: [
        .package(path: "../Keychain"),
        .package(path: "../Logging"),
    ],
    targets: [
        .target(
            name: "Config",
            dependencies: [
                .product(name: "Keychain", package: "Keychain"),
                .product(name: "JarvisLogging", package: "Logging"),
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "ConfigTests",
            dependencies: ["Config"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
