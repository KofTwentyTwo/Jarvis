// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Shell",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "Shell", targets: ["Shell"]),
    ],
    dependencies: [
        .package(path: "../Config"),
        .package(path: "../Logging"),
    ],
    targets: [
        .target(
            name: "Shell",
            dependencies: [
                .product(name: "Config", package: "Config"),
                .product(name: "JarvisLogging", package: "Logging"),
            ],
            swiftSettings: [.swiftLanguageMode(.v6)],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("ServiceManagement"),
                .linkedFramework("IOKit"),
                .linkedFramework("Carbon"),
            ]
        ),
        .testTarget(
            name: "ShellTests",
            dependencies: ["Shell"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
