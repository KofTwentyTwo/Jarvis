import XCTest
import AgentCore
@testable import Replay

final class ReplayLogTests: XCTestCase {
    private var dbURL: URL!

    override func setUp() {
        super.setUp()
        dbURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("replay-log-\(UUID().uuidString).db")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dbURL)
        try? FileManager.default.removeItem(atPath: dbURL.path + "-wal")
        try? FileManager.default.removeItem(atPath: dbURL.path + "-shm")
        super.tearDown()
    }

    // L1: beginSession inserts a row + returns a SessionID with valid UUID.
    func test_L1_beginSessionInsertsRow() async throws {
        let log = try ReplayLog(databaseURL: dbURL)
        let id = try await log.beginSession(appVersion: "0.1.0", buildSHA: "abc123")
        XCTAssertNotNil(UUID(uuidString: id.rawValue), "SessionID rawValue is a UUID string")

        let conn = try SQLiteConnection.open(at: dbURL)
        defer { try? conn.close() }
        let count: Int64 = try conn.query(
            "SELECT COUNT(*) FROM sessions WHERE session_id=?;",
            bindings: [.text(id.rawValue)],
            map: { $0.columnInt(at: 0) }
        ).first ?? 0
        XCTAssertEqual(count, 1)
    }

    // L2: startTurn inserts with NULL ended_at/stop_reason; retry_of and
    // turn_nonce match the bound values.
    func test_L2_startTurnInsertsWithNulls() async throws {
        let log = try ReplayLog(databaseURL: dbURL)
        let session = try await log.beginSession(appVersion: "v", buildSHA: "s")
        let originalTurn = TurnID.fresh()
        let retryTurn = TurnID.fresh()

        // Original.
        try await log.startTurn(
            turnId: originalTurn,
            sessionId: session,
            retryOf: nil,
            turnNonce: "nonce-A",
            source: .text,
            provider: "anthropic",
            modelId: "claude-opus-4-7"
        )
        // Retry referencing the original.
        try await log.startTurn(
            turnId: retryTurn,
            sessionId: session,
            retryOf: originalTurn,
            turnNonce: "nonce-B",
            source: .text,
            provider: "anthropic",
            modelId: "claude-opus-4-7"
        )

        let conn = try SQLiteConnection.open(at: dbURL)
        defer { try? conn.close() }

        // Original row: retry_of NULL, ended_at NULL, stop_reason NULL.
        let origRows: [(retryOfNull: Bool, endedNull: Bool, stopNull: Bool, nonce: String)] = try conn.query(
            "SELECT retry_of, ended_at, stop_reason, turn_nonce FROM turns WHERE turn_id=?;",
            bindings: [.text(originalTurn.rawValue)],
            map: { (
                $0.columnIsNull(at: 0),
                $0.columnIsNull(at: 1),
                $0.columnIsNull(at: 2),
                $0.columnText(at: 3) ?? ""
            ) }
        )
        XCTAssertEqual(origRows.count, 1)
        XCTAssertTrue(origRows[0].retryOfNull, "retry_of should be NULL on original")
        XCTAssertTrue(origRows[0].endedNull)
        XCTAssertTrue(origRows[0].stopNull)
        XCTAssertEqual(origRows[0].nonce, "nonce-A")

        // Retry row: retry_of points at original.
        let retryRows: [(retryOf: String, nonce: String)] = try conn.query(
            "SELECT retry_of, turn_nonce FROM turns WHERE turn_id=?;",
            bindings: [.text(retryTurn.rawValue)],
            map: { ($0.columnText(at: 0) ?? "", $0.columnText(at: 1) ?? "") }
        )
        XCTAssertEqual(retryRows.count, 1)
        XCTAssertEqual(retryRows[0].retryOf, originalTurn.rawValue)
        XCTAssertEqual(retryRows[0].nonce, "nonce-B")
    }

    // L3: 64 records, no flush trigger fires (count is exactly 64 → triggers).
    // Use 50 events instead, well under the chunk threshold and within
    // the 50ms window. Must remain unflushed.
    func test_L3_eventsBufferedBelowChunkThreshold() async throws {
        let log = try ReplayLog(databaseURL: dbURL)
        let session = try await log.beginSession(appVersion: "v", buildSHA: "s")
        let turn = TurnID.fresh()
        try await log.startTurn(
            turnId: turn, sessionId: session, retryOf: nil,
            turnNonce: "n", source: .text,
            provider: "anthropic", modelId: "claude-opus-4-7"
        )
        for _ in 0..<50 {
            await log.record(.textDelta("a"), for: turn)
        }
        // Immediately read events table from a separate connection — buffer
        // hasn't flushed yet (no chunk trigger, no 50ms timer fired).
        let conn = try SQLiteConnection.open(at: dbURL)
        defer { try? conn.close() }
        let count: Int64 = try conn.query(
            "SELECT COUNT(*) FROM events WHERE turn_id=?;",
            bindings: [.text(turn.rawValue)],
            map: { $0.columnInt(at: 0) }
        ).first ?? -1
        XCTAssertEqual(count, 0, "expected events buffered, got \(count) flushed")
    }

    // L4: endTurn forces flush + UPDATE turns + WAL checkpoint.
    func test_L4_endTurnFlushesAndStampsTurn() async throws {
        let log = try ReplayLog(databaseURL: dbURL)
        let session = try await log.beginSession(appVersion: "v", buildSHA: "s")
        let turn = TurnID.fresh()
        try await log.startTurn(
            turnId: turn, sessionId: session, retryOf: nil,
            turnNonce: "n", source: .text,
            provider: "anthropic", modelId: "claude-opus-4-7"
        )
        for _ in 0..<63 {
            await log.record(.textDelta("a"), for: turn)
        }
        await log.endTurn(turn, stopReason: "end_turn")

        let conn = try SQLiteConnection.open(at: dbURL)
        defer { try? conn.close() }

        // 63 textDelta + 1 turn_end = 64 events.
        let count: Int64 = try conn.query(
            "SELECT COUNT(*) FROM events WHERE turn_id=?;",
            bindings: [.text(turn.rawValue)],
            map: { $0.columnInt(at: 0) }
        ).first ?? 0
        XCTAssertEqual(count, 64)

        let row: [(endedNull: Bool, stop: String)] = try conn.query(
            "SELECT ended_at, stop_reason FROM turns WHERE turn_id=?;",
            bindings: [.text(turn.rawValue)],
            map: { ($0.columnIsNull(at: 0), $0.columnText(at: 1) ?? "") }
        )
        XCTAssertEqual(row.count, 1)
        XCTAssertFalse(row[0].endedNull, "ended_at should be set after endTurn")
        XCTAssertEqual(row[0].stop, "end_turn")
    }

    // L5: 50ms window flush trigger. Record 3 events, sleep 80ms, expect rows.
    func test_L5_windowedFlush() async throws {
        let log = try ReplayLog(databaseURL: dbURL)
        let session = try await log.beginSession(appVersion: "v", buildSHA: "s")
        let turn = TurnID.fresh()
        try await log.startTurn(
            turnId: turn, sessionId: session, retryOf: nil,
            turnNonce: "n", source: .text,
            provider: "anthropic", modelId: "claude-opus-4-7"
        )
        for _ in 0..<3 {
            await log.record(.textDelta("a"), for: turn)
        }
        // Wait long enough for the 50ms window task to fire + flush + commit.
        try await Task.sleep(nanoseconds: 200_000_000)

        let conn = try SQLiteConnection.open(at: dbURL)
        defer { try? conn.close() }
        let count: Int64 = try conn.query(
            "SELECT COUNT(*) FROM events WHERE turn_id=?;",
            bindings: [.text(turn.rawValue)],
            map: { $0.columnInt(at: 0) }
        ).first ?? 0
        XCTAssertEqual(count, 3, "windowed flush should drain 3 events")
    }

    // L6: Chunk-trigger flush at exactly 64 events.
    func test_L6_chunkTriggerFlush() async throws {
        let log = try ReplayLog(databaseURL: dbURL)
        let session = try await log.beginSession(appVersion: "v", buildSHA: "s")
        let turn = TurnID.fresh()
        try await log.startTurn(
            turnId: turn, sessionId: session, retryOf: nil,
            turnNonce: "n", source: .text,
            provider: "anthropic", modelId: "claude-opus-4-7"
        )
        for _ in 0..<64 {
            await log.record(.textDelta("x"), for: turn)
        }
        // No sleep — chunk trigger should have flushed synchronously.
        let conn = try SQLiteConnection.open(at: dbURL)
        defer { try? conn.close() }
        let count: Int64 = try conn.query(
            "SELECT COUNT(*) FROM events WHERE turn_id=?;",
            bindings: [.text(turn.rawValue)],
            map: { $0.columnInt(at: 0) }
        ).first ?? 0
        XCTAssertEqual(count, 64, "chunk trigger should flush at 64th event")
    }

    // L7: Full-blob toolResultFull preserves the entire payload (no truncation).
    func test_L7_largeToolResultPreserved() async throws {
        let log = try ReplayLog(databaseURL: dbURL)
        let session = try await log.beginSession(appVersion: "v", buildSHA: "s")
        let turn = TurnID.fresh()
        try await log.startTurn(
            turnId: turn, sessionId: session, retryOf: nil,
            turnNonce: "n", source: .text,
            provider: "anthropic", modelId: "claude-opus-4-7"
        )
        // 128KB payload of 0xAA bytes — well above the 8KB orchestrator cap
        // (which is the orchestrator's concern, not the replay log's).
        let big = Data(repeating: 0xAA, count: 128 * 1024)
        await log.record(.toolResultFull(toolUseId: "tu_test", bytes: big), for: turn)
        await log.endTurn(turn, stopReason: "tool_use")

        let conn = try SQLiteConnection.open(at: dbURL)
        defer { try? conn.close() }
        let blob: Data? = try conn.query(
            "SELECT payload_bytes FROM events WHERE turn_id=? AND kind='tool_result_full';",
            bindings: [.text(turn.rawValue)],
            map: { $0.columnBlob(at: 0) }
        ).first ?? nil

        XCTAssertNotNil(blob)
        // Decode the JSON envelope and base64 to recover the inner bytes.
        guard let blob else { return }
        let json = try JSONSerialization.jsonObject(with: blob) as? [String: String]
        XCTAssertEqual(json?["tool_use_id"], "tu_test")
        let recovered = Data(base64Encoded: json?["bytes"] ?? "") ?? Data()
        XCTAssertEqual(recovered.count, 128 * 1024)
        XCTAssertEqual(recovered, big, "full byte-for-byte preservation")
    }

    // L8: Nothing-masked invariant. A "secret"-shaped string round-trips
    // verbatim because redaction is the viewer's job (P8), not ours.
    func test_L8_nothingMaskedAtStorage() async throws {
        let log = try ReplayLog(databaseURL: dbURL)
        let session = try await log.beginSession(appVersion: "v", buildSHA: "s")
        let turn = TurnID.fresh()
        try await log.startTurn(
            turnId: turn, sessionId: session, retryOf: nil,
            turnNonce: "n", source: .text,
            provider: "anthropic", modelId: "claude-opus-4-7"
        )
        let secret = "sk-ant-FAKE123-not-a-real-key"
        await log.record(.textDelta(secret), for: turn)
        await log.endTurn(turn, stopReason: "end_turn")

        let conn = try SQLiteConnection.open(at: dbURL)
        defer { try? conn.close() }
        let payload: Data = try conn.query(
            "SELECT payload_bytes FROM events WHERE turn_id=? AND kind='text_delta';",
            bindings: [.text(turn.rawValue)],
            map: { $0.columnBlob(at: 0) ?? Data() }
        ).first ?? Data()
        let s = String(data: payload, encoding: .utf8)
        XCTAssertEqual(s, secret, "replay log is the authoritative byte record; redaction belongs to the viewer (P8)")
    }
}
