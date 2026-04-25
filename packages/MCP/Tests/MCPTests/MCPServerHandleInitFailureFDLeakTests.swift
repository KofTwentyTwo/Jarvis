// MCPServerHandleInitFailureFDLeakTests.swift
//
// CR-01 (REVIEW 05) regression — `MCPServerHandle.start()` must close the
// three parent-side pipe ends (stdin write, stdout read, stderr read) on
// the post-spawn initialize-failure paths. The 100-cycle FD-leak test in
// MCPRestartTests covers the happy-restart-cycle path; this suite asserts
// the source-level fix exists.
//
// Why source-level instead of runtime: ChildSpawnGate's DEBUG fatalError
// fires on the NEXT spawn cycle after a real FD leak, which makes a runtime
// FD-count loop crash before it can assert. The fix-pattern is small enough
// that grep + structural assertions on the source are decisive — the cleanup
// helper is the load-bearing primitive and the catch arms must call it.

import XCTest

final class MCPServerHandleInitFailureFDLeakTests: XCTestCase {
    private func mcpServerHandleSource() throws -> String {
        // Walk from this file: Tests/MCPTests/<file> → packages/MCP/Sources/MCP/MCPServerHandle.swift
        let testFile = URL(fileURLWithPath: #filePath)
        let pkgDir = testFile
            .deletingLastPathComponent()  // MCPTests/
            .deletingLastPathComponent()  // Tests/
            .deletingLastPathComponent()  // packages/MCP/
        let source = pkgDir
            .appendingPathComponent("Sources")
            .appendingPathComponent("MCP")
            .appendingPathComponent("MCPServerHandle.swift")
        return try String(contentsOf: source, encoding: .utf8)
    }

    /// CR-01 invariant 1: a `closeParentPipeEnds` helper exists.
    func test_closeParentPipeEnds_helper_isDefined() throws {
        let source = try mcpServerHandleSource()
        XCTAssertTrue(
            source.contains("func closeParentPipeEnds("),
            "MCPServerHandle must define a closeParentPipeEnds helper for CR-01 cleanup"
        )
    }

    /// CR-01 invariant 2: the helper closes all three retained pipe ends.
    /// (parent's write of stdin; parent's read of stdout; parent's read of stderr)
    func test_closeParentPipeEnds_helper_closesAll3Ends() throws {
        let source = try mcpServerHandleSource()
        // Pull just the helper body to avoid matching the lines around 4a where
        // the CHILD-SIDE ends are closed (different file handles than the
        // parent retains).
        guard let helperRange = source.range(of: "func closeParentPipeEnds(") else {
            XCTFail("closeParentPipeEnds helper not found")
            return
        }
        // Pick the helper body (next ~400 chars after the func decl). The
        // file is small enough that this windowing is safe.
        let bodyStart = helperRange.upperBound
        let bodyEnd = source.index(bodyStart, offsetBy: 600, limitedBy: source.endIndex) ?? source.endIndex
        let body = String(source[bodyStart..<bodyEnd])

        XCTAssertTrue(
            body.contains("stdinPipe.fileHandleForWriting.close"),
            "closeParentPipeEnds must close stdinPipe.fileHandleForWriting"
        )
        XCTAssertTrue(
            body.contains("stdoutPipe.fileHandleForReading.close"),
            "closeParentPipeEnds must close stdoutPipe.fileHandleForReading"
        )
        XCTAssertTrue(
            body.contains("stderrPipe.fileHandleForReading.close"),
            "closeParentPipeEnds must close stderrPipe.fileHandleForReading"
        )
        XCTAssertTrue(
            body.contains("readabilityHandler = nil"),
            "closeParentPipeEnds must detach the stderr readabilityHandler before close"
        )
    }

    /// CR-01 invariant 3: BOTH initialize-failure throw arms call the helper
    /// before throwing — the connect() catch arm and the
    /// helperMissingToolsCapability arm.
    func test_initFailure_throwArms_callCloseParentPipeEnds() throws {
        let source = try mcpServerHandleSource()
        let occurrences = source.components(separatedBy: "Self.closeParentPipeEnds(").count - 1
        XCTAssertGreaterThanOrEqual(
            occurrences, 2,
            "CR-01: Self.closeParentPipeEnds must be called from BOTH initialize-failure paths (connect-throw + missing-tools); found \(occurrences) call site(s)"
        )
    }

    /// CR-01 invariant 4: cleanup is wired BEFORE the throw, not after, on
    /// both paths. Otherwise the throw would skip the cleanup.
    func test_initFailure_cleanupHappensBeforeThrow_onBothArms() throws {
        let source = try mcpServerHandleSource()

        // For each call site, check that on the same arm, the throw line
        // comes AFTER the helper call. Search by-position: look for
        // "closeParentPipeEnds(" then within the next 200 chars, look for
        // "throw JarvisMCPError.".
        var searchStart = source.startIndex
        var siteCount = 0
        while let callRange = source.range(of: "Self.closeParentPipeEnds(", range: searchStart..<source.endIndex) {
            siteCount += 1
            let windowEnd = source.index(callRange.upperBound, offsetBy: 250, limitedBy: source.endIndex) ?? source.endIndex
            let window = String(source[callRange.upperBound..<windowEnd])
            XCTAssertTrue(
                window.contains("throw JarvisMCPError."),
                "CR-01 site #\(siteCount): close must precede throw on its arm"
            )
            searchStart = callRange.upperBound
        }
        XCTAssertGreaterThanOrEqual(siteCount, 2, "expected ≥2 close-then-throw sites")
    }
}
