// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Bus",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "Bus", targets: ["Bus"]),
    ],
    dependencies: [
        .package(path: "../Logging"),
    ],
    targets: [
        .target(
            name: "Bus",
            dependencies: [
                .product(name: "JarvisLogging", package: "Logging"),
            ],
            swiftSettings: [.swiftLanguageMode(.v6)],
            linkerSettings: [
                .linkedFramework("WebKit"),
            ]
        ),
        .testTarget(
            name: "BusTests",
            dependencies: ["Bus"],
            resources: [.process("Fixtures")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
