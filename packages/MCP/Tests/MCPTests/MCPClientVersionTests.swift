// MCPClientVersionTests.swift
//
// Asserts the SPM dependency on the MCP Swift SDK is pinned at exactly 0.12.0
// and that the host toolchain meets the SDK's parse-time floor (Swift 6.1).
//
// Plan: 05-01 (MCP-01)

import XCTest

final class MCPClientVersionTests: XCTestCase {
    /// Locate `Package.swift` for the JarvisMCP package by walking up from the
    /// current source file. SPM tests run from a `.build/` working dir, so we
    /// can't rely on relative paths from CWD.
    private func packageSwiftURL() -> URL? {
        // #file points at this test source. Walk up to packages/MCP/Package.swift.
        let testFileURL = URL(fileURLWithPath: #filePath)
        // Tests/MCPTests/<file> → up 3 = packages/MCP
        let pkgDir = testFileURL
            .deletingLastPathComponent()  // MCPTests/
            .deletingLastPathComponent()  // Tests/
            .deletingLastPathComponent()  // packages/MCP/
        let pkgFile = pkgDir.appendingPathComponent("Package.swift")
        return FileManager.default.fileExists(atPath: pkgFile.path) ? pkgFile : nil
    }

    func test_resolvedSwiftSDKIsExactly_0_12_0() throws {
        guard let url = packageSwiftURL() else {
            XCTFail("could not locate packages/MCP/Package.swift")
            return
        }
        let contents = try String(contentsOf: url, encoding: .utf8)
        // The literal substring is the contract. Either an exact-version range
        // or a `from:` substring would fail the regression guard.
        XCTAssertTrue(
            contents.contains(#"exact: "0.12.0""#),
            "Package.swift must pin swift-sdk at exact 0.12.0; found:\n\(contents)"
        )
        XCTAssertFalse(
            contents.contains(#"from: "0.12.0""#),
            "Package.swift must NOT use a range pin like from: \"0.12.0\" — pre-1.0 SDK can break on minor bumps."
        )
    }

    func test_swiftToolsVersionAtLeast_6_1_runtimeCheck() throws {
        // The SDK requires swift-tools-version 6.1 to PARSE its Package.swift.
        // Our targets compile at 6.0 — only the SDK manifest needs 6.1.
        // We verify the running toolchain is at least 6.1 by parsing `swift --version`.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["swift", "--version"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8) ?? ""
        // Accept shapes like:
        //   "Apple Swift version 6.3.1 (swiftlang-...)"
        //   "swift-driver version: 1.x Apple Swift version 6.3.1 ..."
        let pattern = #"Apple Swift version (\d+)\.(\d+)"#
        let regex = try NSRegularExpression(pattern: pattern)
        let range = NSRange(output.startIndex..., in: output)
        guard let match = regex.firstMatch(in: output, range: range),
              match.numberOfRanges >= 3,
              let majorRange = Range(match.range(at: 1), in: output),
              let minorRange = Range(match.range(at: 2), in: output),
              let major = Int(output[majorRange]),
              let minor = Int(output[minorRange])
        else {
            XCTFail("could not parse 'swift --version' output:\n\(output)")
            return
        }
        XCTAssertTrue(
            (major, minor) >= (6, 1),
            "swift toolchain must be >= 6.1 to parse modelcontextprotocol/swift-sdk's Package.swift; got \(major).\(minor)"
        )
    }
}
