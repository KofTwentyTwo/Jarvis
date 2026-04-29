import XCTest
import Replay
@testable import Memory

/// Plan 07-03 Task 1 — unit tests for the new SQL constants and value types.
///
/// These tests do NOT touch SQLite. They exercise the static SQL strings,
/// the Codable conformance for FactRef and TurnRow, and the
/// ReplayEvent.memoryRetrieval round-trip.
final class MemoryQueriesAndModelTests: XCTestCase {

    func testHybridSearchSQLContainsRRFExpression() {
        let sql = MemoryQueries.hybridSearchSQL(k: 50)
        XCTAssertTrue(sql.contains("SUM(1.0/(60+rank))"),
                      "RRF expression must use rrfK=60")
        XCTAssertTrue(sql.contains("f.valid_to IS NULL AND f.forgotten_at IS NULL"))
        XCTAssertTrue(sql.contains("AND k = 50"),
                      "vec0 cohort must template k as a literal (RESEARCH P9)")
        XCTAssertTrue(sql.contains("bm25(facts_fts)"))
        XCTAssertTrue(sql.contains("embedding MATCH"))
        XCTAssertTrue(sql.contains("ORDER BY fused.rrf DESC"))
    }

    func testHybridSearchSQLRRFKConstant() {
        XCTAssertEqual(MemoryQueries.rrfK, 60)
    }

    func testHybridSearchSQLHasNoSessionIdPredicate() {
        let sql = MemoryQueries.hybridSearchSQL(k: 10)
        XCTAssertFalse(sql.contains("session_id"),
                       "D-07 invariant: search_memory must be unscoped.")
    }

    func testForgetFactSQLUsesUpdateNotDelete() {
        let sql = MemoryQueries.forgetFactSQL
        XCTAssertTrue(sql.contains("UPDATE facts"))
        XCTAssertFalse(sql.contains("DELETE FROM facts"))
    }

    func testFactRefIsCodable() throws {
        let ref = FactRef(factId: 42, summary: "S P O", score: 0.5,
                          triggerTurnId: 7, timestamp: 1000)
        let encoded = try JSONEncoder().encode(ref)
        let decoded = try JSONDecoder().decode(FactRef.self, from: encoded)
        XCTAssertEqual(decoded, ref)
    }

    func testTurnRowIsCodable() throws {
        let row = TurnRow(id: 1, sessionId: "A", role: "user",
                          content: "hi", source: "userText", createdAt: 100)
        let encoded = try JSONEncoder().encode(row)
        let decoded = try JSONDecoder().decode(TurnRow.self, from: encoded)
        XCTAssertEqual(decoded, row)
    }

    func testReplayEventMemoryRetrievalRoundtrip() {
        let bytes = "{\"factId\":1}".data(using: .utf8)!
        let ev: ReplayEvent = .memoryRetrieval(bytes)
        let (kind, payload) = ev.encoded()
        XCTAssertEqual(kind, "memory_retrieval")
        XCTAssertEqual(payload, bytes)
    }
}
