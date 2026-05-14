import Foundation
// D-5/D-6 closure (2026-05-11): SQLite + vec0 statically linked via
// CSQLiteVec (jkrukowski/SQLiteVec). All sqlite3_* symbols + SQLITE_OK
// resolve through this module. Replay re-exports the same so consumers
// don't have to know which package the symbols come from.
import CSQLiteVec
import Darwin
import AgentCore
import JarvisLogging
import Logging
import Replay

/// Test seam over `Replay.ReplayLog`. The Memory module deliberately does NOT
/// depend on a concrete `ReplayLog` instance — `AppDelegate.installMemory`
/// hands a wrapper through `setReplayLog` at startup. Tests inject a
/// mock conforming to this protocol.
public protocol MemoryReplaySink: Sendable {
    func record(_ event: ReplayEvent, forTriggerTurnId triggerTurnId: Int64)
}

/// Actor-owned SQLite handle for the memory subsystem (jarvis.db).
///
/// On init, opens (or creates) the DB at databaseURL, applies WAL +
/// pragmas, and runs the full schema migration. vec0 is registered as a
/// process-global SQLite auto-extension on first MemoryStore construction
/// (D-5/D-6 closure, 2026-05-11 — `CSQLiteVec.core_vec_init()` via
/// jkrukowski/SQLiteVec). Every subsequent `sqlite3_open` in the process
/// auto-loads vec0, so the old runtime extension-loading dlsym pathway
/// is gone.
///
/// **Boot policy (changed 2026-05-11 — reverses Track-D D-1):**
/// MemoryStore.init failures are now FATAL at the AppDelegate level.
/// `installMemory` no longer swallows the throw — without a working
/// memory store the app refuses to launch. This eliminates the silent
/// dormancy that hid B-02 / B-04-class substrate failures.
///
/// The actor is the only writer. The bounded extraction channel writes
/// here via `applyOp`; the hybrid (FTS5 + vec0) search path reads through
/// `MemoryReadStore` conformance and emits `ReplayEvent.memoryRetrieval`
/// via `recordRetrieval`.
public actor MemoryStore {

    public static let logChannel = "memory"

    /// Process-global one-shot: register vec0 as a SQLite auto-extension
    /// the FIRST time any MemoryStore is constructed. Idempotent — Swift's
    /// `static let` initializer fires exactly once per process lifetime.
    /// `core_vec_init()` calls `sqlite3_auto_extension(sqlite3_vec_init)`
    /// which queues vec0 init on every future `sqlite3_open`. Connections
    /// opened BEFORE this point (e.g., ReplayLog at app boot) do not have
    /// vec0 — but ReplayLog doesn't need it, and MemoryStore opens its
    /// connection AFTER this fires.
    private static let _vecAutoExtensionRegistered: Bool = {
        let rc = core_vec_init()
        // SQLITE_OK = 0. Non-zero would mean sqlite3_auto_extension itself
        // failed — extraordinarily rare; usually only on memory exhaustion.
        if rc != SQLITE_OK {
            // We can't easily throw from a static-let initializer; record
            // the failure and let MemoryStore.init catch it via the
            // companion `vecAutoExtensionStatus`.
            return false
        }
        return true
    }()

    private let conn: SQLiteConnection
    private let logger: Logger

    /// Audit 2026-05-12 / M-1 (Issue #12): writer-side embedder. When
    /// non-nil, `insertNewFact` runs the embedder against the subject/
    /// predicate/object triple and writes a matching `facts_vec` row after
    /// the facts row is committed. When nil, the writer skips the vec
    /// insert entirely — degraded-but-searchable mode (FTS5 still works).
    /// Embedder failures during the vec write are logged but never roll
    /// back the facts row, per audit recommendation: "log + leave the FTS
    /// row (degraded but searchable) rather than rolling back the fact row."
    private let embedder: (any EmbeddingProviding)?

    /// Open jarvis.db at databaseURL. Creates parent dir if absent.
    /// Registers vec0 as auto-extension (once per process). Applies pragmas
    /// + schema migration + vec_version sanity probe. Throws on any failure.
    ///
    /// `embedder` (audit 2026-05-12 / Issue #12): optional embedding
    /// provider used by `applyOp` to populate `facts_vec` alongside `facts`.
    /// When nil, facts_vec is never written; hybrid search degrades to
    /// FTS5-only ranking (no semantic recall). Production wires
    /// `OllamaEmbeddingClient` here in `installMemory`; tests inject stubs.
    public init(databaseURL: URL, embedder: (any EmbeddingProviding)? = nil) throws {
        // Ensure parent directory exists.
        let parent = databaseURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)

        // Trigger the process-global vec0 registration BEFORE opening the
        // connection so vec0 fires during sqlite3_open's auto-extension
        // pass. (Reading the static let is what runs the initializer.)
        guard MemoryStore._vecAutoExtensionRegistered else {
            throw MemoryError.vecLoadFailed("CSQLiteVec.core_vec_init() returned non-OK during process-global auto-extension registration")
        }

        self.conn = try SQLiteConnection.open(at: databaseURL)
        self.logger = Logger(label: Self.logChannel)
        self.embedder = embedder

        // 1. Pragmas (WAL + synchronous + busy_timeout + foreign_keys + temp_store).
        for sql in MemorySchema.pragmas {
            try conn.execute(sql)
        }

        // 2. Run schema DDL (idempotent CREATE IF NOT EXISTS).
        for sql in MemorySchema.allStatements {
            try conn.execute(sql)
        }

        // 3. Sanity probe — assert vec_version() reads back. Failure here
        //    means the auto-extension registration didn't take, which would
        //    be a serious build-time invariant violation.
        try Self.assertVecVersion(on: conn, logger: logger)

        logger.info("MemoryStore opened at \(databaseURL.path) (vec0 statically linked via CSQLiteVec)")
    }

    /// Test seam: introspect raw SQLite via the connection (read-only).
    public func querySingleString(_ sql: String) throws -> String? {
        try conn.query(sql, bindings: []) { stmt in
            stmt.columnText(at: 0)
        }.first.flatMap { $0 }
    }

    /// Test seam: count rows.
    public func queryRowCount(_ sql: String) throws -> Int {
        try conn.query(sql, bindings: []) { _ in () }.count
    }

    /// Direct connection access for downstream Memory plans (07-02 supersede transaction,
    /// 07-03 hybrid search). Internal — leaks ConnHandle access only within Memory module.
    internal var connection: SQLiteConnection { conn }

    // MARK: - Replay log injection (set by AppDelegate.installMemory in 07-06)

    private var replayLog: (any MemoryReplaySink)?

    public func setReplayLog(_ sink: any MemoryReplaySink) {
        self.replayLog = sink
    }

    // MARK: - applyOp (MEM-05 + MEM-06 single emission site)

    /// Apply a single mem0 operation. The ONLY emission site for
    /// `ReplayEvent.memoryMutation` (MEM-06).
    ///
    /// Audit 2026-05-12 / M-1 (Issue #12): now `async` because `insertNewFact`
    /// awaits the optional embedder to populate `facts_vec` alongside `facts`.
    /// Pre-fix this was sync and `facts_vec` was never written.
    @discardableResult
    public func applyOp(_ op: MemoryOp, sourceTurnId: Int64) async throws -> Fact? {
        switch op {
        case .noop:
            logger.debug("memory NOOP for turnId=\(sourceTurnId)")
            return nil
        case .add(let subject, let predicate, let object, _):
            return try await insertNewFact(
                subject: subject,
                predicate: predicate,
                object: object,
                supersedesFactId: nil,
                sourceTurnId: sourceTurnId
            )
        case .update(let supersedes, let subject, let predicate, let object, _):
            return try await insertNewFact(
                subject: subject,
                predicate: predicate,
                object: object,
                supersedesFactId: supersedes,
                sourceTurnId: sourceTurnId
            )
        }
    }

    /// RESEARCH §6 supersede transaction. NEVER calls DELETE.
    private func insertNewFact(
        subject: String,
        predicate: String,
        object: String,
        supersedesFactId: Int64?,
        sourceTurnId: Int64
    ) async throws -> Fact {
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        do {
            try conn.beginTransaction()

            try conn.exec("""
                INSERT INTO facts(
                    subject, predicate, object, source_turn_id,
                    valid_from, valid_to, superseded_by, forgotten_at, created_at
                ) VALUES (?, ?, ?, ?, ?, NULL, NULL, NULL, ?);
                """,
                bindings: [
                    .text(subject),
                    .text(predicate),
                    .text(object),
                    .int(sourceTurnId),
                    .int(now),
                    .int(now),
                ]
            )
            let newId = try conn.query("SELECT last_insert_rowid();", bindings: []) { stmt in
                stmt.columnInt(at: 0)
            }.first ?? 0
            guard newId > 0 else {
                throw MemoryError.applyOpFailed(underlying: NSError(
                    domain: "MemoryStore", code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "last_insert_rowid returned 0"]
                ))
            }

            if let priorId = supersedesFactId {
                try conn.exec("""
                    UPDATE facts
                       SET valid_to = ?, superseded_by = ?
                     WHERE id = ? AND valid_to IS NULL;
                    """,
                    bindings: [
                        .int(now),
                        .int(newId),
                        .int(priorId),
                    ]
                )
                let changes = try conn.query("SELECT changes();", bindings: []) { stmt in
                    stmt.columnInt(at: 0)
                }.first ?? 0
                guard changes == 1 else {
                    throw MemoryError.applyOpFailed(underlying: NSError(
                        domain: "MemoryStore", code: 2,
                        userInfo: [NSLocalizedDescriptionKey: "UPDATE supersede affected \(changes) rows (expected 1) for priorId=\(priorId)"]
                    ))
                }
            }

            try conn.commit()

            let fact = Fact(
                id: newId,
                subject: subject,
                predicate: predicate,
                object: object,
                sourceTurnId: sourceTurnId,
                validFrom: now,
                validTo: nil,
                supersededBy: nil,
                forgottenAt: nil,
                createdAt: now
            )

            // Audit 2026-05-12 / M-1 (Issue #12): write the matching
            // facts_vec row so semantic search has a cohort. Done AFTER
            // commit so embedder failure (network, model unavailable,
            // dimension mismatch) leaves the facts row + FTS5 row intact —
            // degraded-but-searchable per audit recommendation.
            await writeFactsVecRow(for: fact)

            recordMemoryMutation(
                op: supersedesFactId == nil ? "ADD" : "UPDATE",
                fact: fact,
                supersedesFactId: supersedesFactId,
                triggerTurnId: sourceTurnId
            )

            return fact
        } catch let mem as MemoryError {
            try? conn.rollback()
            throw mem
        } catch {
            try? conn.rollback()
            throw MemoryError.applyOpFailed(underlying: error)
        }
    }

    /// Audit 2026-05-12 / M-1 (Issue #12): populate `facts_vec` with the
    /// embedding for a freshly-inserted fact. Best-effort — embedder errors
    /// and SQLite errors are logged but never thrown; the facts row stays
    /// (FTS5 search still works, vec cohort is empty for this fact).
    ///
    /// No-op when the store was constructed without an embedder (the test
    /// surface for that path is `MemoryStoreVecWriteTests`).
    private func writeFactsVecRow(for fact: Fact) async {
        guard let embedder else { return }
        let text = "\(fact.subject) \(fact.predicate) \(fact.object)"
        let embedding: [Float]
        do {
            embedding = try await embedder.embed(text)
        } catch {
            logger.warning("writeFactsVecRow: embedder failed for factId=\(fact.id): \(error). facts_vec row absent; FTS5 row remains.")
            return
        }
        guard embedding.count == MemoryConstants.embeddingDim else {
            logger.warning("writeFactsVecRow: embedder returned wrong dim (\(embedding.count) vs expected \(MemoryConstants.embeddingDim)) for factId=\(fact.id); skipping vec insert.")
            return
        }
        let blob = embedding.withUnsafeBufferPointer { Data(buffer: $0) }
        do {
            try conn.exec(
                "INSERT INTO facts_vec(fact_id, embedding) VALUES (?, ?);",
                bindings: [.int(fact.id), .blob(blob)]
            )
        } catch {
            logger.warning("writeFactsVecRow: facts_vec insert failed for factId=\(fact.id): \(error). FTS5 row remains.")
        }
    }

    private func recordMemoryMutation(
        op: String,
        fact: Fact,
        supersedesFactId: Int64?,
        triggerTurnId: Int64
    ) {
        guard let sink = replayLog else { return }
        var payload: [String: Any] = [
            "op": op,
            "subject": fact.subject,
            "predicate": fact.predicate,
            "object": fact.object,
            "factId": fact.id,
            "triggerTurnId": triggerTurnId,
            "triggerSource": "memoryExtraction",
            "timestamp": fact.validFrom,
        ]
        if let sup = supersedesFactId {
            payload["supersedesFactId"] = sup
        } else {
            payload["supersedesFactId"] = NSNull()
        }
        let bytes = (try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])) ?? Data()
        sink.record(.memoryMutation(bytes), forTriggerTurnId: triggerTurnId)
    }

    // MARK: - Read path (MEM-07 + TEXT-03 + D-02 + D-05)

    /// SOLE production emission site for ReplayEvent.memoryRetrieval (D-05).
    /// Mirrors `recordMemoryMutation` on the write path. Best-effort; if no
    /// replay sink has been injected, the call is a silent no-op.
    public func recordRetrieval(_ ref: FactRef, triggerTurnId: Int64) {
        guard let sink = replayLog else { return }
        let stamp: Int64 = ref.timestamp == 0
            ? Int64(Date().timeIntervalSince1970 * 1000)
            : ref.timestamp
        var payload: [String: Any] = [
            "factId": ref.factId,
            "summary": ref.summary,
            "triggerTurnId": triggerTurnId,
            "timestamp": stamp,
        ]
        if let s = ref.score {
            payload["score"] = s
        } else {
            payload["score"] = NSNull()
        }
        guard let bytes = try? JSONSerialization.data(
            withJSONObject: payload,
            options: [.sortedKeys]
        ) else {
            logger.error("recordRetrieval: JSON serialization failed for factId=\(ref.factId)")
            return
        }
        sink.record(.memoryRetrieval(bytes), forTriggerTurnId: triggerTurnId)
    }

    /// MEM-07 hybrid search execution. Runs the RESEARCH section 8 RRF SQL
    /// and returns (Fact, rrfScore) tuples ordered by score DESC.
    ///
    /// Caller (HybridSearch actor) is responsible for emitting one
    /// recordRetrieval call per result — splitting SQL execution from
    /// emission keeps the single-emission-site grep gate clean.
    public func runHybridSearchSQL(query: String, embedding: [Float], k: Int) throws -> [(Fact, Double)] {
        let sql = MemoryQueries.hybridSearchSQL(k: k)
        let qvBytes = embedding.withUnsafeBufferPointer { Data(buffer: $0) }
        return try conn.query(sql, bindings: [
            .text(query),
            .blob(qvBytes),
        ]) { stmt in
            let id = stmt.columnInt(at: 0)
            let subject = stmt.columnText(at: 1) ?? ""
            let predicate = stmt.columnText(at: 2) ?? ""
            let object = stmt.columnText(at: 3) ?? ""
            let validFrom = stmt.columnInt(at: 4)
            let validTo: Int64? = stmt.columnIsNull(at: 5) ? nil : stmt.columnInt(at: 5)
            let rrf = stmt.columnDouble(at: 6)
            let fact = Fact(
                id: id,
                subject: subject,
                predicate: predicate,
                object: object,
                sourceTurnId: nil,
                validFrom: validFrom,
                validTo: validTo,
                supersededBy: nil,
                forgottenAt: nil,
                createdAt: validFrom
            )
            return (fact, rrf)
        }
    }

    /// Track-D D-3: recent active facts (most-recently-created first), capped
    /// at `limit`. Source for the mem0 extractor's priorFacts context so the
    /// model can decide UPDATE-vs-ADD against an existing fact rather than
    /// silently duplicating it on every turn. D-02 forgotten facts excluded.
    /// Cap is enforced server-side in SQL — never returns more than `limit`
    /// rows even with a misbehaving caller.
    public func recentActiveFacts(limit: Int) throws -> [Fact] {
        try conn.query(MemoryQueries.recentActiveFactsSQL, bindings: [
            .int(Int64(max(0, limit))),
        ]) { stmt in
            Fact(
                id: stmt.columnInt(at: 0),
                subject: stmt.columnText(at: 1) ?? "",
                predicate: stmt.columnText(at: 2) ?? "",
                object: stmt.columnText(at: 3) ?? "",
                sourceTurnId: stmt.columnIsNull(at: 4) ? nil : stmt.columnInt(at: 4),
                validFrom: stmt.columnInt(at: 5),
                validTo: stmt.columnIsNull(at: 6) ? nil : stmt.columnInt(at: 6),
                supersededBy: stmt.columnIsNull(at: 7) ? nil : stmt.columnInt(at: 7),
                forgottenAt: stmt.columnIsNull(at: 8) ? nil : stmt.columnInt(at: 8),
                createdAt: stmt.columnInt(at: 9)
            )
        }
    }

    /// Active facts (valid_to IS NULL AND forgotten_at IS NULL) for a given
    /// subject. D-02 forgotten facts excluded.
    public func queryActiveFacts(matching subject: String) throws -> [Fact] {
        try conn.query(MemoryQueries.activeFactsBySubjectSQL, bindings: [.text(subject)]) { stmt in
            Fact(
                id: stmt.columnInt(at: 0),
                subject: stmt.columnText(at: 1) ?? "",
                predicate: stmt.columnText(at: 2) ?? "",
                object: stmt.columnText(at: 3) ?? "",
                sourceTurnId: stmt.columnIsNull(at: 4) ? nil : stmt.columnInt(at: 4),
                validFrom: stmt.columnInt(at: 5),
                validTo: stmt.columnIsNull(at: 6) ? nil : stmt.columnInt(at: 6),
                supersededBy: stmt.columnIsNull(at: 7) ? nil : stmt.columnInt(at: 7),
                forgottenAt: stmt.columnIsNull(at: 8) ? nil : stmt.columnInt(at: 8),
                createdAt: stmt.columnInt(at: 9)
            )
        }
    }

    /// B-02 turn-row writer. Appends a single row to the `turns` table.
    /// The schema's FTS5 trigger mirrors `content` into `turns_fts`
    /// automatically; no separate FTS insert is needed.
    ///
    /// `role` is "user" | "assistant" | "tool" (matches TurnRow.role).
    /// `source` is the TurnSource rawValue ("userText", "wakeWord",
    /// "assistant", etc.); arbitrary string — the schema doesn't enforce
    /// an enum and consumers treat it as informational.
    /// `createdAt` is unix-ms; callers MUST pass distinct timestamps for
    /// user vs assistant rows of the same turn so the DESC + id-tiebreaker
    /// ordering in `sessionHistorySQL` reconstructs chronological order
    /// correctly.
    ///
    /// T-06-05-03: this function MUST NOT log `content` — turn text is
    /// user-bearing and may contain PII.
    public func appendTurn(
        sessionId: String,
        role: String,
        content: String,
        source: String,
        createdAt: Int64
    ) throws {
        try conn.exec(MemoryQueries.turnInsertSQL, bindings: [
            .text(sessionId),
            .text(role),
            .text(content),
            .text(source),
            .int(createdAt),
        ])
    }

    /// TEXT-03 chat-panel hydration source. Returns the most recent `limit`
    /// turns for the given session, ordered by created_at DESC.
    public func recentTurnsForSession(sessionId: String, limit: Int) throws -> [TurnRow] {
        try conn.query(MemoryQueries.sessionHistorySQL, bindings: [
            .text(sessionId),
            .int(Int64(max(0, limit))),
        ]) { stmt in
            TurnRow(
                id: stmt.columnInt(at: 0),
                sessionId: stmt.columnText(at: 1) ?? "",
                role: stmt.columnText(at: 2) ?? "",
                content: stmt.columnText(at: 3) ?? "",
                source: stmt.columnText(at: 4) ?? "",
                createdAt: stmt.columnInt(at: 5)
            )
        }
    }

    /// D-02 forget tool dispatch target. Closes valid_to and sets
    /// forgotten_at on the active row only. NEVER DELETEs. Returns true if a
    /// row was forgotten, false if no active row matched (already forgotten,
    /// or unknown id). Idempotent: a second call matches 0 rows because the
    /// WHERE clause requires both valid_to IS NULL and forgotten_at IS NULL.
    @discardableResult
    public func forgetFact(id: Int64, triggerTurnId: Int64) throws -> Bool {
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        do {
            try conn.exec(MemoryQueries.forgetFactSQL, bindings: [
                .int(now),
                .int(now),
                .int(id),
            ])
            let changes = try conn.query("SELECT changes();", bindings: []) { stmt in
                stmt.columnInt(at: 0)
            }.first ?? 0
            if changes == 1 {
                logger.info("forgetFact: closed valid_to and set forgotten_at on factId=\(id) (triggerTurnId=\(triggerTurnId))")
                return true
            }
            logger.debug("forgetFact: no active row matched factId=\(id) — already forgotten or unknown")
            return false
        } catch {
            throw MemoryError.applyOpFailed(underlying: error)
        }
    }

    // MARK: - vec0 sanity

    // NB: the prior `loadVecExtension(on:)` was retired 2026-05-11 (D-5/D-6
    // closure). vec0 is now statically linked into CSQLiteVec and registered
    // process-globally via `core_vec_init()` in the `_vecAutoExtensionRegistered`
    // static-let above. The dlsym pathway is gone. `assertVecVersion` remains
    // as the runtime sanity probe.

    private static func assertVecVersion(on conn: SQLiteConnection, logger: Logger) throws {
        let v = try conn.query("SELECT vec_version();", bindings: []) { stmt in
            stmt.columnText(at: 0)
        }.first.flatMap { $0 }
        guard let v else {
            throw MemoryError.vecVersionMissing
        }
        logger.info("vec_version: \(v)")
    }
}

// MARK: - HybridSearch + SessionHistory conformance

extension MemoryStore: MemoryReadStore {}
extension MemoryStore: SessionHistoryReading {}
extension OllamaEmbeddingClient: EmbeddingProviding {}

// MARK: - Regression corpus test seams
//
// These small read-only seams are exercised exclusively by the env-gated
// MemoryRegressionCorpusTests suite (JARVIS_REAL_MODELS=1). They wrap raw
// SQL queries that the regression scenarios need to assert on. Each is
// idempotent and side-effect-free.

extension MemoryStore {

    /// Convenience facade over `runHybridSearchSQL` that supplies its own
    /// embedding via the injected embedder. Used by the regression corpus
    /// to drive a single query end-to-end without the test having to wire
    /// the embedder explicitly.
    public func searchFacts(
        query: String,
        k: Int = 10,
        embedder: any EmbeddingProviding
    ) async throws -> [Fact] {
        let embedding = try await embedder.embed(query)
        let pairs = try runHybridSearchSQL(query: query, embedding: embedding, k: k)
        return pairs.map { $0.0 }
    }

    /// Fetch a fact by id (regardless of valid_to / forgotten_at state).
    /// Used by the regression corpus to verify the never-DELETE invariant.
    public func factById(_ id: Int64) throws -> Fact? {
        let sql = """
            SELECT id, subject, predicate, object, source_turn_id, valid_from,
                   valid_to, superseded_by, forgotten_at, created_at
            FROM facts
            WHERE id = ?
            LIMIT 1;
            """
        let rows = try conn.query(sql, bindings: [.int(id)]) { stmt in
            Fact(
                id: stmt.columnInt(at: 0),
                subject: stmt.columnText(at: 1) ?? "",
                predicate: stmt.columnText(at: 2) ?? "",
                object: stmt.columnText(at: 3) ?? "",
                sourceTurnId: stmt.columnIsNull(at: 4) ? nil : stmt.columnInt(at: 4),
                validFrom: stmt.columnInt(at: 5),
                validTo: stmt.columnIsNull(at: 6) ? nil : stmt.columnInt(at: 6),
                supersededBy: stmt.columnIsNull(at: 7) ? nil : stmt.columnInt(at: 7),
                forgottenAt: stmt.columnIsNull(at: 8) ? nil : stmt.columnInt(at: 8),
                createdAt: stmt.columnInt(at: 9)
            )
        }
        return rows.first
    }

    /// Count facts (regardless of state) matching a predicate. Used by the
    /// regression corpus to assert MEM-05 never-DELETE: `SELECT COUNT(*)`
    /// should rise on supersede, never stay flat.
    public func rawCountFacts(predicate: String) throws -> Int {
        let sql = "SELECT COUNT(*) FROM facts WHERE predicate = ?;"
        let rows = try conn.query(sql, bindings: [.text(predicate)]) { stmt in
            Int(stmt.columnInt(at: 0))
        }
        return rows.first ?? 0
    }

    /// Active facts (valid_to IS NULL AND forgotten_at IS NULL) matching
    /// (subject, predicate). Returns 0 or more rows; the partial index
    /// `idx_facts_active` is the natural query plan.
    public func activeFacts(subject: String, predicate: String) throws -> [Fact] {
        let sql = """
            SELECT id, subject, predicate, object, source_turn_id, valid_from,
                   valid_to, superseded_by, forgotten_at, created_at
            FROM facts
            WHERE subject = ?
              AND predicate = ?
              AND valid_to IS NULL
              AND forgotten_at IS NULL;
            """
        return try conn.query(sql, bindings: [.text(subject), .text(predicate)]) { stmt in
            Fact(
                id: stmt.columnInt(at: 0),
                subject: stmt.columnText(at: 1) ?? "",
                predicate: stmt.columnText(at: 2) ?? "",
                object: stmt.columnText(at: 3) ?? "",
                sourceTurnId: stmt.columnIsNull(at: 4) ? nil : stmt.columnInt(at: 4),
                validFrom: stmt.columnInt(at: 5),
                validTo: stmt.columnIsNull(at: 6) ? nil : stmt.columnInt(at: 6),
                supersededBy: stmt.columnIsNull(at: 7) ? nil : stmt.columnInt(at: 7),
                forgottenAt: stmt.columnIsNull(at: 8) ? nil : stmt.columnInt(at: 8),
                createdAt: stmt.columnInt(at: 9)
            )
        }
    }
}
