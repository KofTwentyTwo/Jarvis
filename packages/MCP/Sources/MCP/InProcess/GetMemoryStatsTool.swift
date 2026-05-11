import Foundation

/// D-5/D-6 closure (2026-05-11) follow-up: introspection tool exposing
/// Jarvis's own memory DB to the model. Lets the user ask "how many
/// turns do you have?" / "how big is your memory?" / "what version of
/// vec0 are you using?" without giving Jarvis raw SQL or filesystem
/// access. Read-only, no confirmation.
///
/// Pattern matches `GetActiveAudioRouteTool` and `GetSelfStateTool`
/// (Plan 10-01 SELF-02 / SELF-03): protocol seam keeps JarvisMCP
/// unaware of MemoryStore internals; the App-side adapter does the
/// MemoryStore actor hop.
public protocol MemoryStatsDispatching: Sendable {
    func getMemoryStats() async throws -> MemoryStats
}

/// Tool-boundary projection of the memory DB's current state. All counts
/// are exact (SELECT COUNT(*)) rather than estimated. Bytes are the
/// jarvis.db file size as the kernel sees it (includes WAL pages if WAL
/// is checkpointing).
public struct MemoryStats: Sendable, Codable, Equatable {
    /// Total rows in the `turns` table (every user/assistant/tool row,
    /// across all sessions, including superseded).
    public let turnsCount: Int
    /// Total rows in the `facts` table including superseded and forgotten.
    public let factsTotal: Int
    /// Active facts: `valid_to IS NULL AND forgotten_at IS NULL`. This is
    /// what hybrid search would return.
    public let factsActive: Int
    /// `SELECT COUNT(DISTINCT session_id) FROM turns`. A "session" is one
    /// app process lifetime — restart bumps this.
    public let sessionsCount: Int
    /// File size of jarvis.db on disk (bytes). WAL/SHM not included.
    public let dbFileBytes: Int64
    /// `vec_version()` — the sqlite-vec build's tagged version string,
    /// e.g. `"v0.1.6"`. Sanity-proves the vec0 auto-extension fired.
    public let vecVersion: String
    /// `sqlite_version()` — the build of SQLite we statically linked.
    public let sqliteVersion: String
    /// Max `created_at` (unix-ms) across turns, or nil if the table is
    /// empty. Lets the model report "your last conversation was N
    /// minutes ago".
    public let lastTurnAtUnixMs: Int64?
    /// Max `created_at` (unix-ms) across facts, or nil if the table is
    /// empty.
    public let lastFactAtUnixMs: Int64?

    public init(
        turnsCount: Int,
        factsTotal: Int,
        factsActive: Int,
        sessionsCount: Int,
        dbFileBytes: Int64,
        vecVersion: String,
        sqliteVersion: String,
        lastTurnAtUnixMs: Int64?,
        lastFactAtUnixMs: Int64?
    ) {
        self.turnsCount = turnsCount
        self.factsTotal = factsTotal
        self.factsActive = factsActive
        self.sessionsCount = sessionsCount
        self.dbFileBytes = dbFileBytes
        self.vecVersion = vecVersion
        self.sqliteVersion = sqliteVersion
        self.lastTurnAtUnixMs = lastTurnAtUnixMs
        self.lastFactAtUnixMs = lastFactAtUnixMs
    }
}

/// `get_memory_stats` MCP in-process tool. Read-only; no confirmation
/// required (D-10).
public struct GetMemoryStatsTool: InProcessTool {

    public let name: String = "get_memory_stats"
    public let toolDescription: String = """
    Returns statistics about Jarvis's local memory database (the SQLite \
    file at ~/Library/Application Support/Jarvis/jarvis.db). Includes: \
    total turn rows (full conversation history), active vs total facts \
    (extracted memories), distinct session count, database file size in \
    bytes, vec_version and sqlite_version, and timestamps of the last \
    turn and last fact written. Call this tool when the user asks about \
    your own memory state — "how much do you remember", "how big is your \
    database", "when did we last talk", "what version of sqlite-vec are \
    you using".
    """
    public let requiresConfirmation: Bool = false

    public var schemaJSON: Data { Self.schema }

    private static let schema: Data = {
        let s: [String: Any] = [
            "type": "object",
            "properties": [:] as [String: Any],
            "required": [] as [String],
        ]
        return (try? JSONSerialization.data(withJSONObject: s, options: [.sortedKeys])) ?? Data()
    }()

    private let dispatcher: any MemoryStatsDispatching

    public init(dispatcher: any MemoryStatsDispatching) {
        self.dispatcher = dispatcher
    }

    public func call(args _: Data) async throws -> Data {
        let stats = try await dispatcher.getMemoryStats()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(stats)
    }
}
