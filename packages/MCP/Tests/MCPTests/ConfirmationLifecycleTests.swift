// ConfirmationLifecycleTests.swift
//
// WR-02 (REVIEW 05) regression — when the broker is held only weakly
// from the presenter and the broker deallocates during a pending
// request, the Approve/Deny button handlers can no-op and the awaiter
// hangs until timeout. The fix made the presenter hold the broker
// STRONG; this test asserts that under the canonical hold-pattern
// (broker outlives the request) Approve resolves correctly.
//
// We don't try to deinit the broker mid-request — that's a structural
// fix asserted by reading source. We DO assert that the broker
// continuation always resolves: either with the actual outcome, or
// with .timeout. Never hangs.

import XCTest
@testable import JarvisMCP

final class ConfirmationLifecycleTests: XCTestCase {

    /// WR-02 invariant: under the canonical lifetime model (broker held
    /// strong by an outer owner — MCPRuntime in production), the awaiter
    /// always resolves on Approve, never hangs.
    actor StrongHoldPresenter: ConfirmationPresenting {
        // WR-02: hold broker STRONG (matching the production fix).
        var broker: ConfirmationBroker?

        func setBroker(_ b: ConfirmationBroker) { broker = b }

        nonisolated func show(id: UUID, toolName: String, argsPreview: String) async {
            try? await Task.sleep(nanoseconds: 5_000_000)
            await self.broker?.response(id: id, outcome: .approve)
        }
        nonisolated func dismiss(id: UUID) async {}
    }

    func test_brokerHeldStronglyByOwner_alwaysResolves() async {
        let presenter = StrongHoldPresenter()
        let broker = ConfirmationBroker(timeoutSeconds: 0.5, presenter: presenter)
        await presenter.setBroker(broker)

        let outcome = await broker.request(
            id: UUID(),
            toolName: "run_applescript",
            argsPreview: "{}"
        )
        XCTAssertEqual(outcome, .approve, "broker must resolve, never hang")
    }

    /// Bound-the-pathological-case: even when the presenter never resolves
    /// (simulating a wedged button handler — the WR-02 silent-no-op mode),
    /// the broker MUST eventually resolve via timeout. The awaiter never
    /// hangs; the timer is the load-bearing fallback.
    actor WedgedPresenter: ConfirmationPresenting {
        nonisolated func show(id: UUID, toolName: String, argsPreview: String) async {
            // Never call broker.response — simulates the WR-02 failure mode.
        }
        nonisolated func dismiss(id: UUID) async {}
    }

    func test_wedgedPresenter_brokerStillResolvesViaTimeout() async {
        let presenter = WedgedPresenter()
        let broker = ConfirmationBroker(timeoutSeconds: 0.05, presenter: presenter)

        let outcome = await broker.request(
            id: UUID(),
            toolName: "run_applescript",
            argsPreview: "{}"
        )
        XCTAssertEqual(outcome, .timeout, "wedged presenter must NOT hang the awaiter — timer fallback fires")
    }

    /// WR-02 source-level assertion: ConfirmationPresenter holds broker as
    /// `let broker: ConfirmationBroker` (strong), NOT `weak var broker`.
    /// This is the load-bearing structural fix.
    func test_source_presenter_holdsBrokerStrongly() throws {
        let testFile = URL(fileURLWithPath: #filePath)
        let pkgDir = testFile
            .deletingLastPathComponent()  // MCPTests/
            .deletingLastPathComponent()  // Tests/
            .deletingLastPathComponent()  // packages/MCP/
        let source = try String(
            contentsOf: pkgDir
                .appendingPathComponent("Sources")
                .appendingPathComponent("MCP")
                .appendingPathComponent("ConfirmationPresenter.swift"),
            encoding: .utf8
        )
        // Strip line + block comments before scanning so doc-comment
        // mentions of the historical pattern don't false-positive.
        let stripped = stripSwiftComments(source)
        XCTAssertFalse(
            stripped.contains("weak var broker"),
            "WR-02: ConfirmationPresenter must NOT hold broker weakly — silent-no-op risk on broker deinit"
        )
        XCTAssertTrue(
            stripped.contains("let broker: ConfirmationBroker"),
            "WR-02: ConfirmationPresenter must hold broker as a strong let"
        )
    }

    /// Minimal Swift comment stripper: removes `//` line comments and
    /// `/* */` block comments. Adequate for property-declaration scans.
    private func stripSwiftComments(_ src: String) -> String {
        var out = ""
        var i = src.startIndex
        var inLineComment = false
        var inBlockComment = false
        while i < src.endIndex {
            let c = src[i]
            let next = src.index(after: i)
            if inLineComment {
                if c == "\n" { inLineComment = false; out.append(c) }
            } else if inBlockComment {
                if c == "*", next < src.endIndex, src[next] == "/" {
                    inBlockComment = false
                    i = src.index(after: next)
                    continue
                }
            } else if c == "/", next < src.endIndex, src[next] == "/" {
                inLineComment = true
                i = src.index(after: next)
                continue
            } else if c == "/", next < src.endIndex, src[next] == "*" {
                inBlockComment = true
                i = src.index(after: next)
                continue
            } else {
                out.append(c)
            }
            i = src.index(after: i)
        }
        return out
    }
}
