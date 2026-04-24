import Foundation
import AgentCore
import JarvisLogging
import Logging

/// Crash-recovery scanner (OBS-07).
///
/// Run BEFORE accepting new turns at app launch:
/// 1. Increment `meta.crash_count`.
/// 2. Find turns with `ended_at IS NULL` AND no `turn_end` event — these are
///    orphans (the app died mid-turn).
/// 3. Stamp each orphan with `stop_reason='orphan_recovered'` and a
///    `recovery_marker` carrying the new crash_count.
///
/// Opens its own SQLiteConnection so it can run before `ReplayLog.init`.
public actor OrphanDetector {
    private let databaseURL: URL
    private let clock: @Sendable () -> Date
    private let logger: Logger

    public init(databaseURL: URL, clock: @Sendable @escaping () -> Date = { Date() }) {
        self.databaseURL = databaseURL
        self.clock = clock
        self.logger = Logger(label: JarvisLogChannel.replay.rawValue)
    }

    /// Run the recovery scan. Returns the IDs of turns that were marked as
    /// orphans (empty array on a clean shutdown).
    public func recoverOrphans() throws -> [TurnID] {
        try ReplayPaths.ensureParentDirectory(of: databaseURL)
        let conn = try SQLiteConnection.open(at: databaseURL)
        defer { try? conn.close() }

        // Same pragmas + DDL + seed as ReplayLog so a never-launched DB
        // can still be scanned. Idempotent.
        for sql in Schema.pragmas { try conn.execute(sql) }
        for sql in Schema.allStatements { try conn.execute(sql) }
        for sql in Schema.seedMeta { try conn.execute(sql) }

        // Step 1: bump crash_count.
        try conn.execute(
            "UPDATE meta SET value = CAST(value AS INTEGER) + 1 WHERE key='crash_count';"
        )
        let crashCount = try readCrashCount(conn)

        // Step 2: find orphans. The `turn_id NOT IN (...)` shape covers the
        // race where ended_at has not been UPDATEd yet but a turn_end event
        // already landed.
        let orphanIDs: [TurnID] = try conn.query(
            """
            SELECT turn_id FROM turns
            WHERE ended_at IS NULL
              AND turn_id NOT IN (SELECT turn_id FROM events WHERE kind='turn_end');
            """,
            bindings: [],
            map: { stmt in
                TurnID(rawValue: stmt.columnText(at: 0) ?? "")
            }
        )

        guard !orphanIDs.isEmpty else {
            logger.info("orphan scan clean", metadata: [
                "crash_count": "\(crashCount)",
            ])
            return []
        }

        // Step 3: mark each orphan. recovery_marker carries the crash_count
        // that detected it — useful for post-mortem (a single launch can
        // recover multiple orphans).
        let endedAt = Int64(clock().timeIntervalSince1970 * 1_000_000_000)
        let marker = "detected_at_launch:crash_count=\(crashCount)"

        for id in orphanIDs {
            try writeOrphanMarker(conn: conn, turnId: id, endedAt: endedAt, marker: marker)
        }

        logger.warning("orphan turns recovered", metadata: [
            "count": "\(orphanIDs.count)",
            "crash_count": "\(crashCount)",
        ])
        return orphanIDs
    }

    private func writeOrphanMarker(
        conn: SQLiteConnection,
        turnId: TurnID,
        endedAt: Int64,
        marker: String
    ) throws {
        try conn.exec(
            """
            UPDATE turns SET
              ended_at = ?,
              stop_reason = 'orphan_recovered',
              recovery_marker = ?
            WHERE turn_id = ?;
            """,
            bindings: [
                .int(endedAt),
                .text(marker),
                .text(turnId.rawValue),
            ]
        )
    }

    private func readCrashCount(_ conn: SQLiteConnection) throws -> String {
        let rows: [String] = try conn.query(
            "SELECT value FROM meta WHERE key='crash_count';",
            bindings: [],
            map: { $0.columnText(at: 0) ?? "" }
        )
        return rows.first ?? "0"
    }
}
