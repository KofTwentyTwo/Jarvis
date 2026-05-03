import XCTest
import AgentCore
@testable import Replay

/// Coverage for the FK contract between `turns.session_id` and
/// `sessions.session_id`. Closes the bug class observed in the v0.12.0
/// INT-3 smoke test (2026-05-03):
///
///   `App/AppDelegate.swift:installAgent` constructed the AgentOrchestrator
///   with `sessionId: SessionID.fresh()` but never called
///   `replayLog.beginSession(...)`. Every subsequent `startTurn` therefore
///   violated the FK and the orchestrator returned
///   `SubmitOutcome.rejected(reason: .configError)`, surfacing in the chat
///   panel as "Config error — see ~/Library/Logs/Jarvis/system.log."
///
/// `beginSession` was already exercised in isolation (ReplayLogTests L1)
/// and in `MCPRuntimeWiringTests`, but no test asserted the negative path:
/// "calling startTurn for a session that has not been inserted MUST fail."
/// That gap let the AppDelegate regression sail through unit-level
/// verification.
final class SessionForeignKeyTests: XCTestCase {
    private var dbURL: URL!

    override func setUp() {
        super.setUp()
        dbURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("replay-fk-\(UUID().uuidString).db")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dbURL)
        try? FileManager.default.removeItem(atPath: dbURL.path + "-wal")
        try? FileManager.default.removeItem(atPath: dbURL.path + "-shm")
        super.tearDown()
    }

    /// FK1: `startTurn` against a session that was never inserted MUST
    /// throw. A passing assertion here would mean the schema's FK isn't
    /// actually enforced — at which point the AppDelegate-level bug we
    /// just hit could recur silently AND replay rows could orphan from
    /// their session, breaking the OrphanDetector.
    func test_FK1_startTurn_withoutBeginSession_throws() async throws {
        let log = try ReplayLog(databaseURL: dbURL)
        let unknownSession = SessionID.fresh()
        let turnId = TurnID.fresh()

        do {
            try await log.startTurn(
                turnId: turnId,
                sessionId: unknownSession,
                retryOf: nil,
                turnNonce: "nonce-fk1",
                source: .text,
                provider: "anthropic",
                modelId: "claude-opus-4-7"
            )
            XCTFail("startTurn must throw when sessionId has no parent row in sessions")
        } catch {
            // Expected — schema's `session_id REFERENCES sessions(session_id)`
            // bites. The error type is intentionally not asserted strictly
            // because SQLite errors flow through ReplayLog's redaction path
            // (`writeRow` redacts `sqlite3_errmsg` since it can echo bound
            // values that may contain credentials). What matters is that
            // the throw happens at all — the production code path then
            // returns `SubmitOutcome.rejected(reason: .configError)`.
        }
    }

    /// FK2: After `beginSession`, the same `startTurn` succeeds. Locks in
    /// the positive path so the contract is fully nailed.
    func test_FK2_startTurn_afterBeginSession_succeeds() async throws {
        let log = try ReplayLog(databaseURL: dbURL)
        let sessionId = try await log.beginSession(appVersion: "0.1.0", buildSHA: "test")
        let turnId = TurnID.fresh()

        try await log.startTurn(
            turnId: turnId,
            sessionId: sessionId,
            retryOf: nil,
            turnNonce: "nonce-fk2",
            source: .text,
            provider: "anthropic",
            modelId: "claude-opus-4-7"
        )

        let conn = try SQLiteConnection.open(at: dbURL)
        defer { try? conn.close() }
        let count: Int64 = try conn.query(
            "SELECT COUNT(*) FROM turns WHERE turn_id=? AND session_id=?;",
            bindings: [.text(turnId.rawValue), .text(sessionId.rawValue)],
            map: { $0.columnInt(at: 0) }
        ).first ?? 0
        XCTAssertEqual(count, 1, "turn row exists with the expected session FK")
    }

    /// FK3: A second `startTurn` reusing the same session is also legal.
    /// Asserts the production install path (single `beginSession` per
    /// process, many `startTurn` calls fanning out from there).
    func test_FK3_multipleStartTurns_shareOneSession() async throws {
        let log = try ReplayLog(databaseURL: dbURL)
        let sessionId = try await log.beginSession(appVersion: "v", buildSHA: "s")
        for _ in 0..<5 {
            try await log.startTurn(
                turnId: TurnID.fresh(),
                sessionId: sessionId,
                retryOf: nil,
                turnNonce: UUID().uuidString,
                source: .text,
                provider: "anthropic",
                modelId: "claude-opus-4-7"
            )
        }
        let conn = try SQLiteConnection.open(at: dbURL)
        defer { try? conn.close() }
        let turnCount: Int64 = try conn.query(
            "SELECT COUNT(*) FROM turns WHERE session_id=?;",
            bindings: [.text(sessionId.rawValue)],
            map: { $0.columnInt(at: 0) }
        ).first ?? 0
        XCTAssertEqual(turnCount, 5)
        let sessionCount: Int64 = try conn.query(
            "SELECT COUNT(*) FROM sessions;",
            bindings: [],
            map: { $0.columnInt(at: 0) }
        ).first ?? 0
        XCTAssertEqual(sessionCount, 1)
    }
}
