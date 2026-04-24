import XCTest
import AgentCore
@testable import Replay

final class OrphanDetectorTests: XCTestCase {
    private var dbURL: URL!

    override func setUp() {
        super.setUp()
        dbURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("replay-orphan-\(UUID().uuidString).db")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dbURL)
        try? FileManager.default.removeItem(atPath: dbURL.path + "-wal")
        try? FileManager.default.removeItem(atPath: dbURL.path + "-shm")
        super.tearDown()
    }

    // O1: Two turns — one cleanly ended, one orphan. recoverOrphans returns
    // only the orphan; orphan row is stamped with 'orphan_recovered' +
    // recovery_marker matching `detected_at_launch:crash_count=\d+`.
    func test_O1_returnsAndMarksOrphans() async throws {
        let session = SessionID.fresh()
        let turnA = TurnID.fresh()
        let turnB = TurnID.fresh()
        try seedFixture(
            session: session,
            turns: [
                (id: turnA, ended: true, hasTurnEndEvent: true),
                (id: turnB, ended: false, hasTurnEndEvent: false),
            ]
        )

        let detector = OrphanDetector(databaseURL: dbURL)
        let recovered = try await detector.recoverOrphans()

        XCTAssertEqual(recovered.map { $0.rawValue }, [turnB.rawValue])

        let conn = try SQLiteConnection.open(at: dbURL)
        defer { try? conn.close() }
        let row: (endedNull: Bool, stop: String, marker: String) = try conn.query(
            "SELECT ended_at, stop_reason, recovery_marker FROM turns WHERE turn_id=?;",
            bindings: [.text(turnB.rawValue)],
            map: { (
                $0.columnIsNull(at: 0),
                $0.columnText(at: 1) ?? "",
                $0.columnText(at: 2) ?? ""
            ) }
        ).first ?? (true, "", "")

        XCTAssertFalse(row.endedNull)
        XCTAssertEqual(row.stop, "orphan_recovered")
        let pattern = #"^detected_at_launch:crash_count=\d+$"#
        XCTAssertNotNil(
            row.marker.range(of: pattern, options: .regularExpression),
            "recovery_marker mismatch: \(row.marker)"
        )
    }

    // O2: A turn with ended_at IS NULL but a turn_end EVENT is NOT considered
    // orphan (race window). Honors the `NOT IN (SELECT ... kind='turn_end')`
    // clause.
    func test_O2_turnEndEventDisqualifiesOrphan() async throws {
        let session = SessionID.fresh()
        let raceTurn = TurnID.fresh()
        try seedFixture(
            session: session,
            turns: [(id: raceTurn, ended: false, hasTurnEndEvent: true)]
        )

        let detector = OrphanDetector(databaseURL: dbURL)
        let recovered = try await detector.recoverOrphans()
        XCTAssertEqual(recovered, [], "turn with turn_end event must not be orphaned")
    }

    // O3: crash_count increments on every recoverOrphans call.
    func test_O3_crashCountIncrementsEachCall() async throws {
        let detector = OrphanDetector(databaseURL: dbURL)
        _ = try await detector.recoverOrphans()
        _ = try await detector.recoverOrphans()
        _ = try await detector.recoverOrphans()

        let conn = try SQLiteConnection.open(at: dbURL)
        defer { try? conn.close() }
        let v: String = try conn.query(
            "SELECT value FROM meta WHERE key='crash_count';",
            bindings: [],
            map: { $0.columnText(at: 0) ?? "" }
        ).first ?? ""
        XCTAssertEqual(v, "3", "three calls = crash_count = 3")
    }

    // O4: Crash-injection — open ReplayLog, record events, do NOT call
    // endTurn or close (SIGKILL parity). Then re-open via OrphanDetector.
    func test_O4_crashInjectionRecovery() async throws {
        let session: SessionID
        let crashedTurn = TurnID.fresh()

        do {
            let log = try ReplayLog(databaseURL: dbURL)
            session = try await log.beginSession(appVersion: "v", buildSHA: "s")
            try await log.startTurn(
                turnId: crashedTurn, sessionId: session, retryOf: nil,
                turnNonce: "n", source: .text,
                provider: "anthropic", modelId: "claude-opus-4-7"
            )
            for _ in 0..<3 {
                await log.record(.textDelta("hi"), for: crashedTurn)
            }
            await log.flush()
            // **Intentionally NOT calling endTurn or close.** The actor
            // drops with crash_count not decremented — SIGKILL parity.
        }

        let detector = OrphanDetector(databaseURL: dbURL)
        let recovered = try await detector.recoverOrphans()
        XCTAssertEqual(recovered.map { $0.rawValue }, [crashedTurn.rawValue])
    }

    // MARK: - Fixture helpers

    /// Seed the DB with a session + a list of (turn, ended-or-not, has-turn_end-event).
    private func seedFixture(
        session: SessionID,
        turns: [(id: TurnID, ended: Bool, hasTurnEndEvent: Bool)]
    ) throws {
        let conn = try SQLiteConnection.open(at: dbURL)
        defer { try? conn.close() }
        for sql in Schema.pragmas { try conn.execute(sql) }
        for sql in Schema.allStatements { try conn.execute(sql) }
        for sql in Schema.seedMeta { try conn.execute(sql) }

        try insertSession(conn: conn, session: session)
        for t in turns {
            try insertTurn(conn: conn, session: session, turn: t)
            if t.hasTurnEndEvent {
                try insertTurnEndEvent(conn: conn, turnId: t.id)
            }
        }
    }

    private func insertSession(conn: SQLiteConnection, session: SessionID) throws {
        try conn.exec(
            "INSERT INTO sessions(session_id, started_at, app_version, build_sha) VALUES (?, ?, ?, ?);",
            bindings: [
                .text(session.rawValue),
                .int(1_000_000_000_000),
                .text("v"),
                .text("s"),
            ]
        )
    }

    private func insertTurn(
        conn: SQLiteConnection,
        session: SessionID,
        turn: (id: TurnID, ended: Bool, hasTurnEndEvent: Bool)
    ) throws {
        try conn.exec(
            """
            INSERT INTO turns(
              turn_id, session_id, retry_of, started_at, monotonic_ns,
              turn_nonce, source, provider, model_id,
              ended_at, stop_reason, recovery_marker
            ) VALUES (?, ?, NULL, ?, ?, ?, ?, ?, ?, ?, ?, NULL);
            """,
            bindings: [
                .text(turn.id.rawValue),
                .text(session.rawValue),
                .int(1_000_000_000_001),
                .int(1_000_000_000_001),
                .text("nonce"),
                .text("text"),
                .text("anthropic"),
                .text("claude-opus-4-7"),
                turn.ended ? .int(1_000_000_000_002) : .null,
                turn.ended ? .text("end_turn") : .null,
            ]
        )
    }

    private func insertTurnEndEvent(conn: SQLiteConnection, turnId: TurnID) throws {
        try conn.exec(
            "INSERT INTO events(turn_id, ts, monotonic_ns, kind, payload_bytes) VALUES (?, ?, ?, 'turn_end', ?);",
            bindings: [
                .text(turnId.rawValue),
                .int(1_000_000_000_002),
                .int(1_000_000_000_002),
                .blob(Data()),
            ]
        )
    }
}
