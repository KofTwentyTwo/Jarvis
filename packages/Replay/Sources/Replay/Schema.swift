import Foundation

/// On-disk replay schema. DDL is verbatim from research §8 — keep this file
/// in sync with `.planning/phases/04-agent-core/04-RESEARCH.md` §8.
///
/// All CREATE statements use IF NOT EXISTS so re-opening an existing DB is a
/// no-op. Seed rows use INSERT OR IGNORE for the same reason.
public enum Schema {
    /// Pragmas applied on every open. Order matters: `journal_mode=WAL` must
    /// run before any write transaction can be started in WAL mode.
    public static let pragmas: [String] = [
        "PRAGMA journal_mode=WAL;",
        "PRAGMA synchronous=NORMAL;",
        "PRAGMA busy_timeout=3000;",
        "PRAGMA foreign_keys=ON;",
        "PRAGMA temp_store=MEMORY;",
    ]

    /// DDL: tables + indices. Executed in order. All statements are idempotent.
    public static let allStatements: [String] = [
        """
        CREATE TABLE IF NOT EXISTS meta (
          key TEXT PRIMARY KEY,
          value TEXT NOT NULL
        );
        """,

        """
        CREATE TABLE IF NOT EXISTS sessions (
          session_id TEXT PRIMARY KEY,
          started_at INTEGER NOT NULL,
          app_version TEXT NOT NULL,
          build_sha TEXT NOT NULL
        );
        """,

        """
        CREATE TABLE IF NOT EXISTS turns (
          turn_id TEXT PRIMARY KEY,
          session_id TEXT NOT NULL REFERENCES sessions(session_id),
          retry_of TEXT REFERENCES turns(turn_id),
          started_at INTEGER NOT NULL,
          monotonic_ns INTEGER NOT NULL,
          turn_nonce TEXT NOT NULL,
          source TEXT NOT NULL,
          provider TEXT NOT NULL,
          model_id TEXT NOT NULL,
          ended_at INTEGER,
          stop_reason TEXT,
          recovery_marker TEXT
        );
        """,

        """
        CREATE TABLE IF NOT EXISTS events (
          row_id INTEGER PRIMARY KEY AUTOINCREMENT,
          turn_id TEXT NOT NULL REFERENCES turns(turn_id),
          ts INTEGER NOT NULL,
          monotonic_ns INTEGER NOT NULL,
          kind TEXT NOT NULL,
          payload_bytes BLOB NOT NULL
        );
        """,

        "CREATE INDEX IF NOT EXISTS events_by_turn ON events(turn_id);",
        "CREATE INDEX IF NOT EXISTS turns_by_session ON turns(session_id);",
    ]

    /// Initial meta rows. INSERT OR IGNORE means re-opening an existing DB
    /// preserves the existing crash_count.
    public static let seedMeta: [String] = [
        "INSERT OR IGNORE INTO meta(key, value) VALUES ('schema_version', '1');",
        "INSERT OR IGNORE INTO meta(key, value) VALUES ('crash_count', '0');",
    ]
}

/// Rawvalues match the `kind` column values written by `ReplayLog`. Stable —
/// changing a rawValue is a schema migration.
public enum ReplayEventKind: String, Sendable {
    case userInput = "user_input"
    case textDelta = "text_delta"
    case thinkingDelta = "thinking_delta"
    case toolCallRequested = "tool_call_requested"
    case toolResultFull = "tool_result_full"
    case usage = "usage"
    case stopReason = "stop_reason"
    case turnEnd = "turn_end"
    case hudEvent = "hud_event"
    case error = "error"
    /// Added in Plan 07-02 — single-emission-site memory mutation event
    /// recorded only by `MemoryStore.applyOp`.
    case memoryMutation = "memory_mutation"
    /// Added in Plan 07-03 — single-emission-site memory retrieval event
    /// recorded only by `MemoryStore.recordRetrieval`.
    case memoryRetrieval = "memory_retrieval"
}
