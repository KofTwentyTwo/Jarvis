import Foundation
import SQLite3
import AgentCore
import AgentOrchestrator
import Replay

/// `ToolDispatcher` conformance that returns recorded `tool_result_full`
/// payloads from a session SQLite file instead of spawning live MCP helpers.
///
/// Plan 08-01 Task 3. Used by `ReplayRunner` to drive the real
/// `AgentOrchestrator` against a recorded session — every tool dispatch is
/// resolved by `(toolUseId)` lookup against the recorded `events` table.
///
/// **D-11 schema-version handshake:** the adapter rejects logs whose
/// `meta.schema_version` is below `DriftClassifier.supportedSchemaVersion`
/// with `Error.schemaVersionMismatch` rather than silently misclassifying.
public actor ReplayMCPAdapter: ToolDispatcher {

    public enum Error: Swift.Error, Equatable {
        case recordedResultNotFound(toolUseId: String)
        case schemaVersionMismatch(found: Int, expected: Int)
        case malformedToolResultPayload(toolUseId: String)
    }

    private let db: SQLiteConnection
    /// Cache of (toolUseId → recorded result bytes). Populated lazily on
    /// first access — recorded sessions are small (<= a few MB), so a full
    /// preload is fine and avoids SQLite re-entrancy across the actor hop.
    private var resultsByToolUseId: [String: Data] = [:]
    private var didPreload = false

    public init(recordedSessionURL: URL) throws {
        let connection = try SQLiteConnection.open(
            at: recordedSessionURL,
            flags: SQLITE_OPEN_READONLY
        )
        self.db = connection

        // Verify schema_version handshake (D-11).
        let versionRows = try connection.query(
            "SELECT value FROM meta WHERE key = 'schema_version' LIMIT 1;"
        ) { stmt -> String in
            stmt.columnText(at: 0) ?? ""
        }
        let foundVersion = Int(versionRows.first ?? "") ?? 0
        let expected = DriftClassifier.supportedSchemaVersion
        guard foundVersion == expected else {
            throw Error.schemaVersionMismatch(found: foundVersion, expected: expected)
        }
    }

    // MARK: - ToolDispatcher

    public func dispatch(toolUse: ToolUseRequest) async throws -> Data {
        try preloadIfNeeded()
        guard let bytes = resultsByToolUseId[toolUse.id] else {
            throw Error.recordedResultNotFound(toolUseId: toolUse.id)
        }
        return bytes
    }

    public nonisolated func requiresConfirmation(toolName: String) -> Bool {
        // Replay never asks for confirmation — the recorded session has
        // already locked in whatever decision the operator made at record
        // time. Treating every tool as non-confirming during replay matches
        // the recorded behavior because the orchestrator only sees the
        // recorded `tool_result_full` payload.
        false
    }

    // MARK: - SQLite preload

    private func preloadIfNeeded() throws {
        guard !didPreload else { return }
        didPreload = true

        // The replay log writes `tool_result_full` as a JSON envelope:
        //   {"tool_use_id": "...", "bytes": "<base64>"}
        // (See packages/Replay/Sources/Replay/ReplayEvent.swift `encoded()`.)
        let kind = ReplayEventKind.toolResultFull.rawValue
        let rows = try db.query(
            "SELECT payload_bytes FROM events WHERE kind = ? ORDER BY row_id ASC;",
            bindings: [.text(kind)]
        ) { stmt -> Data in
            stmt.columnBlob(at: 0) ?? Data()
        }

        for envelope in rows {
            guard
                let json = try? JSONSerialization.jsonObject(with: envelope) as? [String: Any],
                let toolUseId = json["tool_use_id"] as? String,
                let bytesB64 = json["bytes"] as? String,
                let bytes = Data(base64Encoded: bytesB64)
            else {
                continue
            }
            resultsByToolUseId[toolUseId] = bytes
        }
    }
}
