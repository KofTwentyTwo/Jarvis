import XCTest
import Foundation
@testable import Memory

/// **B-02 carry-forward bug — turn-row writer unit test.**
///
/// Exercises the new `MemoryStore.appendTurn` writer that backs the
/// orchestrator's `sessionHistoryLookup` path. Without a writer, the
/// `turns` table stays empty and B-02's `recentTurnsForSession` read
/// returns []. This suite proves the writer round-trips through the
/// schema's FTS5 trigger correctly.
///
/// Tests are env-gated (`JARVIS_VEC0_STUB_PATH`) because `MemoryStore.init`
/// requires vec0.dylib loaded; without the env var the suite skips —
/// matching the existing MemoryStore test corpus convention.
final class MemoryStoreAppendTurnTests: XCTestCase {

    // MARK: - AT-1

    /// AT-1: appendTurn writes one row that recentTurnsForSession surfaces.
    /// Round-trips role/content/source verbatim and increments the row count.
    func testAT1_appendTurnRoundTripsViaRecentTurnsForSession() async throws {
        let tmp = try Self.tempDB()
        let store = try MemoryStore(databaseURL: tmp)

        let sessionId = "S-AT1"
        try await store.appendTurn(
            sessionId: sessionId,
            role: "user",
            content: "hello jarvis",
            source: "userText",
            createdAt: 1_000
        )

        let rows = try await store.recentTurnsForSession(sessionId: sessionId, limit: 10)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].sessionId, sessionId)
        XCTAssertEqual(rows[0].role, "user")
        XCTAssertEqual(rows[0].content, "hello jarvis")
        XCTAssertEqual(rows[0].source, "userText")
        XCTAssertEqual(rows[0].createdAt, 1_000)
    }

    // MARK: - AT-2

    /// AT-2: appendTurn for a (user, assistant) pair produces DESC ordering by
    /// created_at + id-tiebreaker that, when reversed, reconstructs
    /// chronological user→assistant order — the contract the AppDelegate
    /// production wiring relies on.
    func testAT2_userAssistantPairReversesToChronological() async throws {
        let tmp = try Self.tempDB()
        let store = try MemoryStore(databaseURL: tmp)

        let sessionId = "S-AT2"
        // Production callers offset assistant by +1 ms so the DESC ordering
        // is unambiguous; pin that contract here too.
        try await store.appendTurn(
            sessionId: sessionId, role: "user",
            content: "hi", source: "userText", createdAt: 100
        )
        try await store.appendTurn(
            sessionId: sessionId, role: "assistant",
            content: "hello back", source: "assistant", createdAt: 101
        )

        let descRows = try await store.recentTurnsForSession(sessionId: sessionId, limit: 10)
        XCTAssertEqual(descRows.count, 2)
        // DESC: assistant first, user second.
        XCTAssertEqual(descRows[0].role, "assistant")
        XCTAssertEqual(descRows[1].role, "user")

        // Reverse to chronological — the orchestrator's sessionHistoryLookup
        // contract.
        let chrono = Array(descRows.reversed())
        XCTAssertEqual(chrono.map(\.role), ["user", "assistant"])
        XCTAssertEqual(chrono.map(\.content), ["hi", "hello back"])
    }

    // MARK: - AT-3

    /// AT-3: appendTurn is scoped by session_id. Two sessions don't bleed.
    func testAT3_sessionScopingIsolatesRows() async throws {
        let tmp = try Self.tempDB()
        let store = try MemoryStore(databaseURL: tmp)

        try await store.appendTurn(
            sessionId: "S-A", role: "user", content: "a-content",
            source: "userText", createdAt: 1
        )
        try await store.appendTurn(
            sessionId: "S-B", role: "user", content: "b-content",
            source: "userText", createdAt: 2
        )

        let rowsA = try await store.recentTurnsForSession(sessionId: "S-A", limit: 10)
        let rowsB = try await store.recentTurnsForSession(sessionId: "S-B", limit: 10)
        XCTAssertEqual(rowsA.count, 1)
        XCTAssertEqual(rowsB.count, 1)
        XCTAssertEqual(rowsA[0].content, "a-content")
        XCTAssertEqual(rowsB[0].content, "b-content")
    }

    // MARK: - AT-4 (FTS5 trigger sanity)

    /// AT-4: the schema's `INSERT INTO turns_fts(rowid, content)` trigger
    /// fires on appendTurn so the FTS5 index is populated. Verifies the
    /// trigger isn't dormant — without this, future chat-search features
    /// on `turns` would silently return empty results.
    func testAT4_turnsFtsTriggerFiresOnAppend() async throws {
        let tmp = try Self.tempDB()
        let store = try MemoryStore(databaseURL: tmp)

        try await store.appendTurn(
            sessionId: "S-AT4", role: "user", content: "the rain in spain",
            source: "userText", createdAt: 1
        )

        // FTS5 MATCH should find the row by content token.
        let count = try await store.queryRowCount(
            "SELECT 1 FROM turns_fts WHERE turns_fts MATCH 'spain'"
        )
        XCTAssertEqual(count, 1, "turns_fts trigger must mirror content from inserts")
    }

    // MARK: - Helpers

    private static func tempDB() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("appendturn-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("jarvis.db")
    }
}
