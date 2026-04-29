import XCTest

/// MEM-06 single-emission-site invariant. The repository contains exactly ONE
/// production location that constructs ReplayEvent.memoryMutation(...) — and
/// that location is MemoryStore.applyOp. Adding a second emission site
/// anywhere else (extractor, orchestrator, MCP tools, AppDelegate, Replay
/// internal code) fails this test.
final class SingleEmissionSiteGrepTests: XCTestCase {

    func testMemoryMutationHasSingleEmissionSite() throws {
        let repoRoot = try Self.repoRoot()

        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/grep")
        task.arguments = [
            "-rE",
            #"\.memoryMutation\("#,
            "\(repoRoot.path)/packages",
            "--include=*.swift",
        ]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()
        try task.run()
        task.waitUntilExit()

        let data = try pipe.fileHandleForReading.readToEnd() ?? Data()
        let output = String(decoding: data, as: UTF8.self)
        let allHits = output.split(separator: "\n").filter { !$0.isEmpty }

        // Exclude:
        //  - test-target hits
        //  - the enum case declaration itself (`case memoryMutation(Data)`)
        //  - the encoded() switch arm (`case .memoryMutation(let data):`)
        let production = allHits.filter { line in
            let s = String(line)
            if s.contains("/Tests/") || s.contains(".xctest/") { return false }
            // Allow the enum case declaration and switch-arm patterns to pass.
            // The "construction" hits look like `.memoryMutation(bytes)` or
            // `.memoryMutation(payload)` — i.e., a value-producing usage, not a
            // case label. The simplest discriminator: pattern-match arms start
            // with "case .memoryMutation".
            if s.contains("case .memoryMutation") { return false }
            if s.contains("case memoryMutation") { return false }
            return true
        }

        XCTAssertEqual(production.count, 1,
                       "MEM-06: exactly one production site may construct ReplayEvent.memoryMutation(...). Found \(production.count):\n\(production.joined(separator: "\n"))")

        guard let only = production.first else {
            return XCTFail("no production hits — MemoryStore.applyOp must record at least one .memoryMutation event")
        }
        XCTAssertTrue(only.contains("MemoryStore.swift"),
                      "MEM-06: the single emission site must be MemoryStore.applyOp; found at \(only)")
    }

    /// MEM-05 never-DELETE invariant on MemoryStore.swift.
    func testMemoryStoreNeverDeletes() throws {
        let repoRoot = try Self.repoRoot()
        let url = repoRoot.appendingPathComponent("packages/Memory/Sources/Memory/MemoryStore.swift")
        let body = try String(contentsOf: url, encoding: .utf8)
        // Strip line comments before regex check (// ... up to end of line).
        let stripped = body.split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> String in
                let trimmed = line.drop(while: { $0 == " " || $0 == "\t" })
                if trimmed.hasPrefix("//") { return "" }
                return String(line)
            }
            .joined(separator: "\n")
        let hasDelete = stripped.range(of: #"DELETE\s+FROM\s+facts"#, options: .regularExpression) != nil
        XCTAssertFalse(hasDelete,
                       "MEM-05: MemoryStore must never issue DELETE FROM facts. Use UPDATE valid_to + superseded_by + forgotten_at instead.")
    }

    private static func repoRoot() throws -> URL {
        // Walk up from #file looking for project.yml or Jarvis.xcodeproj
        // (this workspace doesn't use a top-level Package.swift).
        var dir = URL(fileURLWithPath: #file).deletingLastPathComponent()
        for _ in 0..<10 {
            let projectYml = dir.appendingPathComponent("project.yml")
            let xcodeproj = dir.appendingPathComponent("Jarvis.xcodeproj")
            if FileManager.default.fileExists(atPath: projectYml.path)
                || FileManager.default.fileExists(atPath: xcodeproj.path) {
                return dir
            }
            dir = dir.deletingLastPathComponent()
        }
        throw NSError(domain: "SingleEmissionSiteGrepTests", code: 1)
    }
}
