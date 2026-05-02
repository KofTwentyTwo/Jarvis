import XCTest

/// Phase 7 cross-plan grep gates expressed as XCTest assertions.
///
/// These four tests duplicate the four standalone shell scripts under
/// `scripts/check-*.sh`. The test-suite version exists so that `swift test`
/// fails when an invariant breaks, even if a contributor never invokes the
/// scripts manually. The shell scripts are still the canonical CI gate.
///
/// A fifth test (`testAppDelegateInstallOrder`) asserts the correct call
/// order in `applicationWillFinishLaunching`. Phase 9 / Plan 4 (WARNING-5)
/// LOCKED the order to vision → agent → voice because installAgent's
/// orchestrator constructor consumes self.visionRouter (Plan 2) and the
/// broadcaster's frame-attach release subscriber needs frameAttachController,
/// while installVoice's adapters require self.agentOrchestrator +
/// self.turnTranscriptStore (both constructed in installAgent). The
/// canonical structural gate is `scripts/check-install-order.sh`; this test
/// is the swift-test mirror, scoped to the assertions Memory cares about:
/// installMemory must precede installVoice (memory ready before first
/// voice-driven turn) and installVision must precede installVoice (so the
/// orchestrator that voice adapters bridge to has a real visionRouter).
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

    /// Companion gate: AppDelegate's install order in applicationWillFinishLaunching
    /// is vision → agent → voice (Phase 9 / Plan 4 / WARNING-5). Memory's invariants
    /// against that fixed sequence: installMemory before installVoice (memory ready
    /// before first voice-driven turn) and installVision before installVoice (so the
    /// orchestrator the voice adapters bridge to has a real visionRouter).
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
            XCTAssertLessThan(vi, v,
                "installVision must be called BEFORE installVoice (Phase 9 Plan 4 WARNING-5: voice adapters depend on the orchestrator's visionRouter, set during installAgent which runs after installVision and before installVoice). See scripts/check-install-order.sh for the canonical structural gate.")
        }
    }
}
