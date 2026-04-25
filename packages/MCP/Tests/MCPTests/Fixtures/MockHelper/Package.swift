// swift-tools-version:6.1
//
// MockHelper — internal test fixture for the JarvisMCP package's spawn-side
// tests. Builds an executable that uses the official MCP Swift SDK as a
// helper-side `Server`, exposing a single `mock_echo` tool plus a `mock_slow`
// tool used by the restart-mutex test.
//
// The fixture is built at test setUp time (`swift build -c release`) and the
// resulting binary is launched as a child process of the JarvisMCP test
// process. Not consumed by any other phase or plan.

import PackageDescription

let package = Package(
    name: "MockHelper",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk", exact: "0.12.0"),
    ],
    targets: [
        .executableTarget(
            name: "MockHelper",
            dependencies: [
                .product(name: "MCP", package: "swift-sdk"),
            ]
        )
    ]
)
