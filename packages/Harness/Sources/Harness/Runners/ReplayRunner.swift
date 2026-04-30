import Foundation
import SQLite3
import AgentCore
import AgentOrchestrator
import Replay

/// Re-runs a recorded session through the harness substrate and returns a
/// `DriftReport`.
///
/// **Plan 08-01 scope (scaffold):** opens the recorded SQLite, verifies the
/// `meta.schema_version` against `DriftClassifier.supportedSchemaVersion`
/// (D-11), materializes the recorded `events` table into `[ReplayRow]`, and
/// runs the classifier. The "actual" side is the same recorded rows as a
/// placeholder — when curated `replay-golden/` sessions ship in 08-02 with
/// paired SSE/NDJSON fixture bytes, this runner will:
///
///  1. Construct `MockLLMProvider(fixtureURL:, kind:)` over the recorded
///     fixture bytes.
///  2. Construct `ReplayMCPAdapter(recordedSessionURL: input)` for tool
///     dispatch.
///  3. Construct an `AgentOrchestrator` whose `submit` is invoked with
///     `TurnSource.replay(sessionId: recordedSessionId)` per R4-L7. Replaying
///     through `submit(.replay(...))` is the load-bearing integration point
///     that proves the real pipeline runs against recorded inputs (R4-L7
///     suppresses HUD dispatch + TTS).
///  4. Drain the actual ReplayLog into `[ReplayRow]` for classifier input.
///
/// The substrate is in place; wiring the orchestrator drive is gated on
/// curated golden sessions (D-08 / D-09 / 08-04 promote helper).
public actor ReplayRunner {

    public struct ReplayResult: Sendable {
        public let recordedURL: URL
        /// Path to the "actual" replay log written during this run. Plan 08-01
        /// returns the recorded URL itself as a placeholder; 08-02 returns the
        /// `/tmp/jarvis-eval-{UUID}.sqlite` written by the real orchestrator.
        public let actualURL: URL
        public let report: DriftReport
    }

    public enum Error: Swift.Error, Equatable {
        case schemaVersionMismatch(found: Int, expected: Int)
        case malformedRecording(reason: String)
    }

    public init() {}

    /// Run a replay against the recorded session at `recordedSessionURL`.
    ///
    /// - Parameter exclusionsURL: optional sidecar JSON file
    ///   (`Corpora/replay-golden/exclusions.json`); falls back to
    ///   `ExclusionList.obs02Default` when nil.
    public func run(
        recordedSessionURL: URL,
        exclusionsURL: URL? = nil
    ) async throws -> ReplayResult {
        let db = try SQLiteConnection.open(
            at: recordedSessionURL,
            flags: SQLITE_OPEN_READONLY
        )
        defer { _ = try? db.close() }

        // D-11 schema-version handshake.
        let versionRows = try db.query(
            "SELECT value FROM meta WHERE key = 'schema_version' LIMIT 1;"
        ) { stmt -> String in
            stmt.columnText(at: 0) ?? ""
        }
        let found = Int(versionRows.first ?? "") ?? 0
        let expected = DriftClassifier.supportedSchemaVersion
        guard found == expected else {
            throw Error.schemaVersionMismatch(found: found, expected: expected)
        }

        // Read recording metadata (temperature, sessionId).
        let recordedSessionId = try Self.readSessionId(db: db)
        let recordingTemperature = Self.readRecordingTemperature(db: db)

        // Materialize recorded rows.
        let recordedRows = try Self.materializeRows(db: db)

        // Plan 08-01 placeholder — actual === recorded until 08-02 wires the
        // orchestrator drive. The reference to `AgentOrchestrator.submit` and
        // `TurnSource.replay(sessionId:)` below is the architectural seam:
        //
        //   let mock = MockLLMProvider(fixtureURL: ..., kind: .anthropicSSE)
        //   let mcp  = try ReplayMCPAdapter(recordedSessionURL: recordedSessionURL)
        //   let orch = AgentOrchestrator(... toolDispatcher: mcp, ...)
        //   _ = await orch.submit(TurnInput(text, source: .replay(sessionId: recordedSessionId)))
        //
        // Reading recordedSessionId here keeps the binding live so future
        // wiring can drop the orchestrator block in without re-plumbing the
        // SQLite reads. Use of `.replay(sessionId:)` is the R4-L7
        // suppression-by-construction guarantee for the replay path.
        _ = TurnSource.replay(sessionId: recordedSessionId)
        let actualRows = recordedRows

        // Load exclusions.
        let exclusions: ExclusionList
        if let url = exclusionsURL {
            exclusions = try ExclusionList.load(from: url)
        } else {
            exclusions = .obs02Default
        }

        let report = DriftClassifier.classify(
            recordedRows: recordedRows,
            actualRows: actualRows,
            exclusions: exclusions,
            recordingTemperature: recordingTemperature
        )

        return ReplayResult(
            recordedURL: recordedSessionURL,
            actualURL: recordedSessionURL,
            report: report
        )
    }

    // MARK: - SQLite read helpers

    /// Materialize every event row joined with its parent turn into a
    /// `[String: String]` field map the classifier can compare. The eight
    /// OBS-02 identity columns (`row_id`, `turn_id`, `session_id`,
    /// `tool_use_id`, `message_id`, `ts`, `monotonic_ns`, `turn_nonce`)
    /// appear as keys so `ExclusionList.alwaysExcluded` matches by name.
    private static func materializeRows(db: SQLiteConnection) throws -> [ReplayRow] {
        let sql = """
        SELECT
          e.row_id, e.turn_id, t.session_id, e.ts, e.monotonic_ns,
          t.turn_nonce, e.kind, e.payload_bytes
        FROM events e
        JOIN turns t ON t.turn_id = e.turn_id
        ORDER BY e.row_id ASC;
        """
        return try db.query(sql) { stmt -> ReplayRow in
            var fields: [String: String] = [:]
            fields["row_id"] = String(stmt.columnInt(at: 0))
            fields["turn_id"] = stmt.columnText(at: 1) ?? ""
            fields["session_id"] = stmt.columnText(at: 2) ?? ""
            fields["ts"] = String(stmt.columnInt(at: 3))
            fields["monotonic_ns"] = String(stmt.columnInt(at: 4))
            fields["turn_nonce"] = stmt.columnText(at: 5) ?? ""
            fields["kind"] = stmt.columnText(at: 6) ?? ""
            // Render payload as a printable string for the diff. Binary
            // payloads (tool_result_full) are b64-encoded already in their
            // JSON envelope; UTF-8 cases (text_delta) decode cleanly.
            if let blob = stmt.columnBlob(at: 7) {
                fields["payload_text"] = String(data: blob, encoding: .utf8)
                    ?? blob.base64EncodedString()
            } else {
                fields["payload_text"] = ""
            }
            return ReplayRow(fields: fields)
        }
    }

    private static func readSessionId(db: SQLiteConnection) throws -> UUID {
        let rows = try db.query(
            "SELECT session_id FROM sessions LIMIT 1;"
        ) { stmt -> String in
            stmt.columnText(at: 0) ?? ""
        }
        return UUID(uuidString: rows.first ?? "") ?? UUID()
    }

    /// Recorded temperature is not currently a `meta` row in the v1 schema;
    /// 08-02's `scripts/promote-replay-session.sh` writes a sidecar JSON next
    /// to the SQLite. For now (Plan 08-01 scaffold) we default to 0.0 so the
    /// classifier treats every drift as deterministic — strictest gate.
    private static func readRecordingTemperature(db: SQLiteConnection) -> Double {
        let rows = (try? db.query(
            "SELECT value FROM meta WHERE key = 'recording_temperature' LIMIT 1;"
        ) { stmt -> String in
            stmt.columnText(at: 0) ?? ""
        }) ?? []
        return Double(rows.first ?? "") ?? 0.0
    }
}
