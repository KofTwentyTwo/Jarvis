import XCTest

/// Phase 7 cross-plan grep gates expressed as XCTest assertions.
///
/// These four tests duplicate the four standalone shell scripts under
/// `scripts/check-*.sh`. The test-suite version exists so that `swift test`
/// fails when an invariant breaks, even if a contributor never invokes the
/// scripts manually. The shell scripts are still the canonical CI gate.
///
/// A fifth test (`testAppDelegateInstallOrder`) asserts the correct call
/// order in `applicationWillFinishLaunching`: installMemory before
/// installVoice (memory ready before first voice-driven turn) and
/// installVision after installVoice (camera lifecycle is independent /
/// can be deferred).
final class PhaseSevenGrepGateTests: XCTestCase {

    // MARK: - Repo-root walker (same shape as EmbeddingDimSymbolTests)

    private static func repoRoot() throws -> URL {
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
        throw NSError(domain: "PhaseSevenGrepGateTests", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: "Could not locate repo root"])
    }

    private static func runScript(_ relativePath: String) throws -> Int32 {
        let root = try repoRoot()
        let script = root.appendingPathComponent(relativePath)
        guard FileManager.default.fileExists(atPath: script.path) else {
            throw NSError(domain: "PhaseSevenGrepGateTests", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "Script missing: \(script.path)"])
        }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/bash")
        task.arguments = [script.path]
        task.standardOutput = Pipe()
        task.standardError = Pipe()
        try task.run()
        task.waitUntilExit()
        return task.terminationStatus
    }

    // MARK: - Gates

    func testMemoryMutatedSingleEmitGate() throws {
        let rc = try Self.runScript("scripts/check-single-memory-mutated-emit.sh")
        XCTAssertEqual(rc, 0,
            "MEM-06: memory.mutated must be emitted from exactly one production site (MemoryStore.applyOp).")
    }

    func testMemoryUsedSingleEmitGate() throws {
        let rc = try Self.runScript("scripts/check-single-memory-used-emit.sh")
        XCTAssertEqual(rc, 0,
            "D-05: memory.used must be emitted from exactly one production site (MemoryStore.recordRetrieval).")
    }

    func testVisionIsolationGate() throws {
        let rc = try Self.runScript("scripts/check-presence-vision-isolation.sh")
        XCTAssertEqual(rc, 0,
            "VISION-03: PresenceSignalBus must have zero subscribers in JarvisTTS or any AgentOrchestrator submit path.")
    }

    func testEmbeddingDimLiteralGate() throws {
        let rc = try Self.runScript("scripts/check-embedding-dim-literal.sh")
        XCTAssertEqual(rc, 0,
            "MEM-02: literal 768 forbidden outside MemoryConstants.embeddingDim.")
    }

    /// Companion gate: AppDelegate calls installMemory() before installVoice()
    /// and installVision() after installVoice() in applicationWillFinishLaunching.
    /// Memory must be ready before the first voice-driven turn lands; vision is
    /// independent and may be deferred.
    func testAppDelegateInstallOrder() throws {
        let root = try Self.repoRoot()
        let appDelegate = root.appendingPathComponent("App/AppDelegate.swift")
        let src = try String(contentsOf: appDelegate, encoding: .utf8)
        let lines = src.split(separator: "\n", omittingEmptySubsequences: false)
        var memLine: Int?
        var voiceLine: Int?
        var visLine: Int?
        for (i, line) in lines.enumerated() {
            // Match the *call* (`await self?.installX()`), not the function
            // declarations. The declarations live elsewhere in the file.
            if memLine == nil && line.contains("installMemory()") && line.contains("await") {
                memLine = i
            }
            if voiceLine == nil && line.contains("installVoice()") && line.contains("await") {
                voiceLine = i
            }
            if visLine == nil && line.contains("installVision()") && line.contains("await") {
                visLine = i
            }
        }
        XCTAssertNotNil(memLine, "installMemory() call site missing from AppDelegate.swift")
        XCTAssertNotNil(voiceLine, "installVoice() call site missing from AppDelegate.swift")
        XCTAssertNotNil(visLine, "installVision() call site missing from AppDelegate.swift")
        if let m = memLine, let v = voiceLine, let vi = visLine {
            XCTAssertLessThan(m, v,
                "installMemory must be called BEFORE installVoice (memory ready before first turn).")
            XCTAssertLessThan(v, vi,
                "installVision must be called AFTER installVoice (camera lifecycle independent / deferred).")
        }
    }
}
