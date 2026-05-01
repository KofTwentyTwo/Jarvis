import XCTest
import Foundation

/// Phase 9 / Plan 1 — runs `scripts/check-orchestrator-events-single-consumer.sh`
/// in-process. Failing the gate (e.g. a future change adds a second
/// `for await … in orchestrator.events` consumer) trips this test before it
/// can land on develop.
final class PhaseNineGrepGateTests: XCTestCase {

    func testOrchestratorEventsSingleConsumerGate() throws {
        let scriptURL = repoRoot()
            .appendingPathComponent("scripts/check-orchestrator-events-single-consumer.sh")
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: scriptURL.path),
            "missing scripts/check-orchestrator-events-single-consumer.sh"
        )

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [scriptURL.path, repoRoot().path]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()
        let output = String(
            data: pipe.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? ""
        XCTAssertEqual(
            process.terminationStatus, 0,
            "scripts/check-orchestrator-events-single-consumer.sh failed:\n\(output)"
        )
    }

    /// Walk up from this file's path until we find the directory that holds
    /// `.planning/`. Works for swift-test runs from any cwd.
    private func repoRoot() -> URL {
        var url = URL(fileURLWithPath: #filePath)
        while url.path != "/" {
            url.deleteLastPathComponent()
            if FileManager.default.fileExists(
                atPath: url.appendingPathComponent(".planning").path
            ) {
                return url
            }
        }
        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    }
}
