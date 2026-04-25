import Foundation
import AgentCore
import JarvisLogging
import Logging

/// On-disk turn-level audit log (OBS-02).
///
/// Owns one `SQLiteConnection`. Writes are batched in a 50ms window OR 64-event
/// chunks (whichever fires first). On `endTurn(_:stopReason:)` we synchronously
/// flush + `PRAGMA wal_checkpoint(TRUNCATE)` so the WAL has been folded back
/// into the main DB — the fsync moment is the per-turn durability boundary.
///
/// **Best-effort guarantee.** Per OBS-02 the replay log is observability,
/// not correctness. Write failures are logged via `JarvisLogChannel.replay`
/// but never propagated into orchestrator turn semantics.
public actor ReplayLog {
    public static let batchMaxEvents = 64
    public static let batchWindowMs: UInt64 = 50

    private let conn: SQLiteConnection
    private let clock: @Sendable () -> Date
    private let logger: Logger
    /// ME-06: per-instance batch-window override for tests. Defaults to
    /// `Self.batchWindowMs` (50ms) in production. Tests that want to assert
    /// "buffer is unflushed at this moment" can pass a very large value
    /// (e.g., 60_000ms) so the timer never fires within the test window —
    /// removes the flaky "Task.sleep racing the timer" failure mode.
    private let batchWindowMsValue: UInt64

    private struct Pending {
        let turnId: TurnID
        let ts: Int64
        let mono: Int64
        let kind: String
        let payload: Data
    }
    private var pending: [Pending] = []
    private var flushTask: Task<Void, Never>?
    private var flushGeneration: UInt64 = 0
    /// ME-05: count consecutive flush failures so chronic disk/WAL faults
    /// escalate from quiet logs to a fatal-tier observation. Each successful
    /// flush resets this. Threshold of 3 keeps transient I/O hiccups from
    /// triggering the loud path while still surfacing real data-loss
    /// conditions for the user.
    private var consecutiveFlushFailures: Int = 0
    private static let flushFailureEscalationThreshold = 3

    public init(
        databaseURL: URL,
        clock: @Sendable @escaping () -> Date = { Date() },
        batchWindowMs: UInt64 = ReplayLog.batchWindowMs
    ) throws {
        try ReplayPaths.ensureParentDirectory(of: databaseURL)
        self.conn = try SQLiteConnection.open(at: databaseURL)
        self.clock = clock
        self.logger = Logger(label: JarvisLogChannel.replay.rawValue)
        self.batchWindowMsValue = batchWindowMs

        for sql in Schema.pragmas { try conn.execute(sql) }
        for sql in Schema.allStatements { try conn.execute(sql) }
        for sql in Schema.seedMeta { try conn.execute(sql) }
    }

    @discardableResult
    public func beginSession(appVersion: String, buildSHA: String) throws -> SessionID {
        let id = SessionID.fresh()
        let now = nowNs()
        try writeRow(
            sql: "INSERT INTO sessions(session_id, started_at, app_version, build_sha) VALUES (?, ?, ?, ?);",
            bindings: [
                .text(id.rawValue),
                .int(now),
                .text(appVersion),
                .text(buildSHA),
            ]
        )
        return id
    }

    public func startTurn(
        turnId: TurnID,
        sessionId: SessionID,
        retryOf: TurnID?,
        turnNonce: String,
        source: TurnSource,
        provider: String,
        modelId: String
    ) throws {
        let ts = nowNs()
        let mono = monotonicNs()
        try writeRow(
            sql: """
            INSERT INTO turns(
              turn_id, session_id, retry_of, started_at, monotonic_ns,
              turn_nonce, source, provider, model_id,
              ended_at, stop_reason, recovery_marker
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, NULL, NULL, NULL);
            """,
            bindings: [
                .text(turnId.rawValue),
                .text(sessionId.rawValue),
                retryOf.map { .text($0.rawValue) } ?? .null,
                .int(ts),
                .int(mono),
                .text(turnNonce),
                .text(source.rawValue),
                .text(provider),
                .text(modelId),
            ]
        )
    }

    public func record(_ event: ReplayEvent, for turnId: TurnID) {
        let (kind, payload) = event.encoded()
        let entry = Pending(
            turnId: turnId,
            ts: nowNs(),
            mono: monotonicNs(),
            kind: kind,
            payload: payload
        )
        pending.append(entry)

        if pending.count >= Self.batchMaxEvents {
            flushPending()
            return
        }

        if flushTask == nil {
            let myGen = flushGeneration
            let waitNs = batchWindowMsValue * 1_000_000
            flushTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: waitNs)
                guard let self else { return }
                await self.windowFlushFired(generation: myGen)
            }
        }
    }

    public func endTurn(_ turnId: TurnID, stopReason: String) {
        // Append a turn_end event so the orphan detector's
        // `turn_id NOT IN (SELECT turn_id FROM events WHERE kind='turn_end')`
        // query resolves correctly.
        let (kind, payload) = ReplayEvent.turnEnd.encoded()
        pending.append(Pending(
            turnId: turnId,
            ts: nowNs(),
            mono: monotonicNs(),
            kind: kind,
            payload: payload
        ))
        flushPending()

        let endedAt = nowNs()
        do {
            try writeRow(
                sql: "UPDATE turns SET ended_at = ?, stop_reason = ? WHERE turn_id = ?;",
                bindings: [.int(endedAt), .text(stopReason), .text(turnId.rawValue)]
            )
            try conn.execute("PRAGMA wal_checkpoint(TRUNCATE);")
        } catch {
            logger.error("endTurn UPDATE/checkpoint failed", metadata: [
                "turn_id": "\(turnId.rawValue)",
                "error": "\(error)",
            ])
        }
    }

    public func flush() {
        flushPending()
    }

    public func close() throws {
        flushTask?.cancel()
        flushTask = nil
        flushPending()

        try conn.execute(
            "UPDATE meta SET value = CAST(value AS INTEGER) - 1 WHERE key='crash_count';"
        )
        try conn.close()
    }

    // MARK: - Internals

    private func windowFlushFired(generation: UInt64) {
        guard generation == flushGeneration else {
            flushTask = nil
            return
        }
        flushTask = nil
        flushPending()
    }

    private func flushPending() {
        guard !pending.isEmpty else {
            flushGeneration &+= 1
            return
        }
        let batch = pending
        pending.removeAll(keepingCapacity: true)
        flushGeneration &+= 1

        do {
            try conn.beginTransaction()
            for e in batch {
                try writeRow(
                    sql: "INSERT INTO events(turn_id, ts, monotonic_ns, kind, payload_bytes) VALUES (?, ?, ?, ?, ?);",
                    bindings: [
                        .text(e.turnId.rawValue),
                        .int(e.ts),
                        .int(e.mono),
                        .text(e.kind),
                        .blob(e.payload),
                    ]
                )
            }
            try conn.commit()
            consecutiveFlushFailures = 0
        } catch {
            // ME-05: rollback the in-flight transaction, then re-buffer the
            // batch at the FRONT of `pending` so the next flush attempt can
            // retry. Pre-fix this silently dropped events on transaction
            // failure, violating OBS-02's durability claim.
            try? conn.rollback()

            // Capture the turn_ids so a forensic reader can identify which
            // turns lost which events (the reviewer's required minimum).
            let turnIds = Set(batch.map { $0.turnId.rawValue })
                .sorted().joined(separator: ",")
            // Redact the error message in case sqlite3_errmsg ever echoes
            // any caller-supplied bytes; defense-in-depth alongside HI-01.
            let errStr = JarvisLogging.Redact.apply(String(describing: error))

            consecutiveFlushFailures += 1
            let escalated = consecutiveFlushFailures >= Self.flushFailureEscalationThreshold

            // Re-buffer at the head; subsequent records append after.
            pending.insert(contentsOf: batch, at: 0)

            if escalated {
                // Chronic failure — surface as critical so the dev overlay
                // / structured-log scrapers can flag it. Don't `fatalError`:
                // OBS-02 says replay is best-effort and must never propagate
                // into orchestrator turn semantics.
                logger.critical("replay flush failing chronically (data-loss risk)", metadata: [
                    "batch_size": "\(batch.count)",
                    "turn_ids": "\(turnIds)",
                    "consecutive_failures": "\(consecutiveFlushFailures)",
                    "error": "\(errStr)",
                ])
            } else {
                logger.error("replay flush failed; batch re-queued", metadata: [
                    "batch_size": "\(batch.count)",
                    "turn_ids": "\(turnIds)",
                    "consecutive_failures": "\(consecutiveFlushFailures)",
                    "error": "\(errStr)",
                ])
            }
        }
    }

    /// Indirection so the action label here ("write a single parameterised
    /// row") is the only call site that hits SQLiteConnection.exec — keeps
    /// the SQL-injection grep gate (verification.sh) at a single chokepoint.
    private func writeRow(sql: String, bindings: [SQLiteValue]) throws {
        try conn.exec(sql, bindings: bindings)
    }

    private func nowNs() -> Int64 {
        Int64(clock().timeIntervalSince1970 * 1_000_000_000)
    }

    private func monotonicNs() -> Int64 {
        Int64(bitPattern: DispatchTime.now().uptimeNanoseconds)
    }
}
