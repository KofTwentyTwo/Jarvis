// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Logging",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "JarvisLogging", targets: ["JarvisLogging"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-log.git", from: "1.5.3"),
    ],
    targets: [
        .target(
            name: "JarvisLogging",
            dependencies: [
                .product(name: "Logging", package: "swift-log"),
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "JarvisLoggingTests",
            dependencies: ["JarvisLogging"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
