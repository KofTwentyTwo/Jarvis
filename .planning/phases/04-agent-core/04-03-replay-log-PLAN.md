---
phase: 04-agent-core
plan: 03
type: execute
wave: 2
depends_on: [01]
files_modified:
  - packages/Replay/Package.swift
  - packages/Replay/Sources/Replay/ReplayLog.swift
  - packages/Replay/Sources/Replay/ReplayEvent.swift
  - packages/Replay/Sources/Replay/ReplayError.swift
  - packages/Replay/Sources/Replay/Schema.swift
  - packages/Replay/Sources/Replay/SQLiteConnection.swift
  - packages/Replay/Sources/Replay/OrphanDetector.swift
  - packages/Replay/Sources/Replay/ReplayPaths.swift
  - packages/Replay/Sources/Replay/TokenDeltaDropOldestChannel.swift
  - packages/Logging/Sources/JarvisLogging/JarvisLogChannel.swift
  - packages/Replay/Tests/ReplayTests/SchemaTests.swift
  - packages/Replay/Tests/ReplayTests/ReplayLogTests.swift
  - packages/Replay/Tests/ReplayTests/OrphanDetectorTests.swift
  - packages/Replay/Tests/ReplayTests/TokenDeltaDropOldestChannelTests.swift
  - packages/Logging/Tests/JarvisLoggingTests/ChannelTests.swift
autonomous: true
requirements: [OBS-02, OBS-07, AGENT-10]
must_haves:
  truths:
    - "packages/Replay exists as a new SPM package with a single library product (Replay)"
    - "ReplayLog actor opens ~/Library/Application Support/Jarvis/replay.db with WAL mode + synchronous=NORMAL + busy_timeout=3000 + foreign_keys=ON"
    - "Schema has exactly four tables: meta, sessions, turns, events; two indices (events_by_turn, turns_by_session)"
    - "meta.crash_count is incremented on launch BEFORE accepting new turns, decremented on clean shutdown"
    - "OrphanDetector identifies turns where ended_at IS NULL AND no event of kind='turn_end' exists; marks them with recovery_marker='detected_at_launch:crash_count=<N>' (OBS-07)"
    - "Event payloads are stored as raw BLOBs — nothing-masked; documented ID list (row_id, session_id, turn_id, tool_use_id, message_id, ts, monotonic_ns, turn_nonce) is normalized by the replay VIEWER in P8, not stripped from storage (OBS-02)"
    - "ReplayLog supports all event kinds: user_input, text_delta, thinking_delta, tool_call_requested, tool_result_full, usage, stop_reason, turn_end, hud_event, error"
    - "Writes are batched in a 50ms window OR 64-event chunks, whichever comes first; fsync only on turn_end via PRAGMA wal_checkpoint(TRUNCATE)"
    - "TokenDeltaDropOldestChannel<Tag> is an actor with PER-ELEMENT drop policy: drops oldest events matching dropTag when full, suspends on any other tag (AGENT-10 critical invariant)"
    - "Load test: 10000-tokenDelta + 1000-toolCall producer into TokenDeltaDropOldestChannel(cap=2048) - consumer receives exactly 1000 toolCall events (zero drops) AND at most 2048 tokenDelta events (drop policy enforced)"
    - "JarvisLogChannel grows two new cases: replay and devoverlay (additive; existing cases preserved)"
    - "Hand-rolled sqlite3 calls (libsqlite3.dylib); NO dependency on SQLite.swift (need load_extension for sqlite-vec in Phase 7)"
  artifacts:
    - path: "packages/Replay/Package.swift"
      provides: "SPM manifest for Replay library; depends on AgentCore, JarvisLogging, Config"
      contains: "Replay"
    - path: "packages/Replay/Sources/Replay/ReplayLog.swift"
      provides: "Actor that owns the SQLite connection, batches writes, fsyncs on turn_end (OBS-02)"
      contains: "turn_end"
    - path: "packages/Replay/Sources/Replay/Schema.swift"
      provides: "DDL for meta/sessions/turns/events + two indices + pragmas + seedMeta"
      contains: "CREATE TABLE turns"
    - path: "packages/Replay/Sources/Replay/OrphanDetector.swift"
      provides: "OBS-07 orphan-turn recovery at launch via the documented SQL from research §8"
      contains: "orphan_recovered"
    - path: "packages/Replay/Sources/Replay/TokenDeltaDropOldestChannel.swift"
      provides: "AGENT-10 per-element drop policy - oldest dropTag elements dropped on overflow; other tags never dropped"
      contains: "dropTag"
  key_links:
    - from: "packages/Replay/Sources/Replay/ReplayLog.swift"
      to: "packages/Replay/Sources/Replay/Schema.swift"
      via: "open() runs Schema.allStatements + Schema.pragmas + Schema.seedMeta"
      pattern: "Schema\\.allStatements"
    - from: "packages/Replay/Sources/Replay/OrphanDetector.swift"
      to: "packages/Replay/Sources/Replay/Schema.swift"
      via: "recoverOrphans() implements the OBS-07 query from research §8"
      pattern: "orphan_recovered"
    - from: "packages/Replay/Sources/Replay/TokenDeltaDropOldestChannel.swift"
      to: "packages/AgentCore/Sources/AgentCore/BoundedAsyncChannel.swift"
      via: "Extends the uniform-policy primitive with per-tag policy (tagged elements)"
      pattern: "dropTag"
---

<objective>
Deliver the `packages/Replay` SPM package — the on-disk turn-level audit log that ships alongside the orchestrator (not after). Provides (a) a SQLite WAL database at `~/Library/Application Support/Jarvis/replay.db` with schema per research §8, (b) the `ReplayLog` actor with batched writes + turn_end fsync, (c) the `OrphanDetector` for OBS-07 crash recovery on launch, and (d) the `TokenDeltaDropOldestChannel` primitive that enforces the AGENT-10 per-element drop policy (drops oldest `tokenDelta` events only; all other event kinds are never dropped).

Purpose: Observability is not a "P8 polish phase" — research §12 and ROADMAP execution-note land it with the orchestrator. Retroactively bolting on a replay log after turn semantics stabilize is expensive: every edge case (refusal, cache hits, cap recovery, stream truncation) has to be re-instrumented. Shipping it together forces "is this event loggable and replayable?" into the initial design.

Output: `packages/Replay` with schema DDL, orphan-detection SQL, tested under a mocked clock and a crash-injection harness. `TokenDeltaDropOldestChannel` load-tested to ensure no tool_call is ever dropped under token firehose, which is the AGENT-10 critical invariant.

**Scope note:** ~15 files, at the threshold. Three tasks: Task 1 = hand-rolled SQLite wrapper + Schema DDL; Task 2 = ReplayLog actor + OrphanDetector; Task 3 = TokenDeltaDropOldestChannel + logging channel additions. Commits atomic per task.

This plan runs in Wave 2 in parallel with Plan 04-02 (OllamaProvider). Both only depend on Plan 04-01. Files are disjoint: Plan 04-02 only touches `packages/AgentCore/Sources/OllamaProvider/` and its test directory; Plan 04-03 creates `packages/Replay/` and extends `packages/Logging/`.
</objective>

<execution_context>
@~/.claude/get-shit-done/workflows/execute-plan.md
@~/.claude/get-shit-done/templates/summary.md
</execution_context>

<context>
@CLAUDE.md
@.planning/PROJECT.md
@.planning/ROADMAP.md
@.planning/REQUIREMENTS.md
@.planning/STATE.md
@.planning/phases/04-agent-core/04-RESEARCH.md
@.planning/phases/04-agent-core/04-01-SUMMARY.md
@.planning/phases/01-foundations/01-02-SUMMARY.md

<interfaces>
From Plan 04-01 (Wave 1):

- `TurnID` (Sendable, Equatable, Hashable, RawRepresentable) with `TurnID.fresh()` static factory.
- `BoundedAsyncChannel<Element: Sendable>` actor with `.suspend`/`.dropOldest`/`.dropNewest` uniform policies (this plan builds a per-element variant on top).

This plan ESTABLISHES (consumed by Plan 04-04 orchestrator):

- `ReplayLog` actor — `init(databaseURL:clock:)`, `beginSession(appVersion:buildSHA:) -> SessionID`, `startTurn(turnId:sessionId:retryOf:turnNonce:source:provider:modelId:)`, `record(_ event:for:)`, `endTurn(_:stopReason:)`, `close()`.
- `SessionID` struct (Sendable, Hashable, RawRepresentable wrapping UUID string).
- `TurnSource` enum (`.text`, `.voice`, `.memoryExtraction`).
- `ReplayEvent` enum with ten cases: `.userInput(Data)`, `.textDelta(String)`, `.thinkingDelta(String)`, `.toolCallRequested(id:name:argsJSON:)`, `.toolResultFull(toolUseId:bytes:)`, `.usage(Data)`, `.stopReason(String)`, `.turnEnd`, `.hudEvent(Data)`, `.error(Data)`.
- `OrphanDetector` actor — `init(databaseURL:)`, `recoverOrphans() -> [TurnID]`.
- `TokenDeltaDropOldestChannel<Tag: Sendable & Equatable & Hashable>` actor — `init(capacity:dropTag:)`, `send(_ element:)`, `finish()`, `makeAsyncIterator()`. `Element` carries a tag + payload Data.
</interfaces>

<codebase_patterns>
- Hand-rolled sqlite3 via `import SQLite3` (libsqlite3.dylib is on macOS by default) — NO `SQLite.swift` dependency per research §11 rationale (we need `load_extension` for sqlite-vec in Phase 7).
- `nonisolated(unsafe)` for the sqlite3 OpaquePointer connection — pattern established in Plan 01-02 for thread-safe Foundation types. Our actor is the sole writer and we open with SQLITE_OPEN_FULLMUTEX anyway.
- Tests use `NSTemporaryDirectory()` for per-test databases; tearDown deletes them via FileManager.
- File paths: `~/Library/Application Support/Jarvis/replay.db` (NOT `~/Library/Logs/Jarvis/` — that's swift-log text channels from Plan 01-02).
- `JarvisLogChannel.replay` + `.devoverlay` — additive to the existing enum. Plan 01-02's JarvisLogHandlerFactory dispatches on `label: String`, so new labels route through the existing Multiplex (FileLogHandler + OSLogHandler) with zero handler code change.
</codebase_patterns>
</context>

<tasks>

<task type="auto" tdd="true">
  <name>Task 1: Scaffold packages/Replay + hand-rolled SQLite wrapper + schema DDL</name>
  <files>
    packages/Replay/Package.swift,
    packages/Replay/Sources/Replay/SQLiteConnection.swift,
    packages/Replay/Sources/Replay/Schema.swift,
    packages/Replay/Sources/Replay/ReplayError.swift,
    packages/Replay/Sources/Replay/ReplayPaths.swift,
    packages/Replay/Sources/Replay/ReplayEvent.swift,
    packages/Replay/Tests/ReplayTests/SchemaTests.swift
  </files>
  <behavior>
    - Test S1 (SchemaTests): `Schema.allStatements` executed sequentially on a fresh SQLite connection produces exactly four tables: meta, sessions, turns, events. Verify via `SELECT name FROM sqlite_schema WHERE type='table'`.
    - Test S2 (SchemaTests): `turns.retry_of` column exists with FOREIGN KEY REFERENCES turns(turn_id).
    - Test S3 (SchemaTests): `events.payload_bytes` column is BLOB NOT NULL.
    - Test S4 (SchemaTests): Indices `events_by_turn` and `turns_by_session` exist after DDL execution.
    - Test S5 (SchemaTests): Pragmas applied - PRAGMA journal_mode returns "wal"; synchronous returns 1 (NORMAL); foreign_keys returns 1; busy_timeout returns 3000.
    - Test S6 (SchemaTests): Initial meta rows seeded - schema_version=1, crash_count=0.
    - Test S7 (SchemaTests): Idempotent open - opening an already-initialized DB does not re-run CREATE TABLE (IF NOT EXISTS) and does not re-seed meta (INSERT OR IGNORE).
  </behavior>
  <action>
Create `packages/Replay/Package.swift` with swift-tools-version 6.0, macOS 13 platform floor, one library product `Replay`, one source target + one test target. Dependencies: `../AgentCore` (for TurnID + BoundedAsyncChannel), `../Logging` (JarvisLogging for loggers), `../Config` (future consumer). Swift language mode v6 on every target.

**`SQLiteConnection.swift`** — thin hand-rolled sqlite3 wrapper using `import SQLite3`. API:

- `final class SQLiteConnection: @unchecked Sendable` with a single `OpaquePointer` handle.
- `static func open(at url: URL, flags: Int32 = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX) throws -> SQLiteConnection` — uses `sqlite3_open_v2`.
- `func execute(_ sql: String) throws` — `sqlite3_exec` path for pragma / DDL (no bindings).
- `func exec(_ sql: String, bindings: [SQLiteValue]) throws` — `sqlite3_prepare_v2` + bind + step + finalize.
- `func query<T>(_ sql: String, bindings: [SQLiteValue], map: (SQLiteStatement) -> T) throws -> [T]` — same but iterates rows and returns a mapped array.
- `func beginTransaction() throws` / `func commit() throws` / `func rollback() throws` — plain `BEGIN` / `COMMIT` / `ROLLBACK`.
- `func close() throws` — `sqlite3_close`.

`enum SQLiteValue: Sendable`: cases `.null`, `.int(Int64)`, `.text(String)`, `.blob(Data)`, `.real(Double)`. Binding logic uses `sqlite3_bind_null/int64/text/blob/double` respectively. Note: text and blob binders need `SQLITE_TRANSIENT` so SQLite copies the buffer.

`final class SQLiteStatement`: wraps `OpaquePointer` (sqlite3_stmt*). Methods: `step() -> Bool` (true = SQLITE_ROW, false = SQLITE_DONE, else throws), `reset()`, `bindAll(_ values: [SQLiteValue])`, `columnInt(at: Int32) -> Int64`, `columnText(at:) -> String?`, `columnBlob(at:) -> Data?`. `finalize()` on deinit.

`enum SQLiteError: Error, Sendable, Equatable` with cases matching sqlite's common failure modes: `.openFailed(code:message:)`, `.prepareFailed(code:message:sql:)`, `.stepFailed(code:message:)`, `.bindFailed(code:)`, `.closeFailed(code:)`. Error messages built from `sqlite3_errmsg(handle)`.

**`Schema.swift`** — static DDL. Encode the DDL statements from research §8 AS Swift string literals (multi-line, no string interpolation). The four CREATE TABLE statements: `meta`, `sessions`, `turns`, `events`. Two CREATE INDEX statements: `events_by_turn ON events(turn_id)` and `turns_by_session ON turns(session_id)` (note: research §8 spec has turns_by_session indexing turns.session_id, NOT sessions - follow research verbatim). Pragmas: WAL / synchronous=NORMAL / busy_timeout=3000 / foreign_keys=ON. Seed meta: `INSERT OR IGNORE INTO meta(key,value) VALUES('schema_version','1')` and `INSERT OR IGNORE INTO meta(key,value) VALUES('crash_count','0')`.

Also expose `enum ReplayEventKind: String, Sendable` with rawValues matching the ten `ReplayEvent` cases: `user_input`, `text_delta`, `thinking_delta`, `tool_call_requested`, `tool_result_full`, `usage`, `stop_reason`, `turn_end`, `hud_event`, `error`.

**`ReplayError.swift`** — public enum with cases `.openFailed(reason:)`, `.schemaMigrationFailed(from:to:)`, `.writeFailed(reason:)`, `.sessionNotStarted`, `.turnAlreadyEnded(TurnID)`, `.orphanRecoveryFailed(reason:)`.

**`ReplayPaths.swift`** — `public enum ReplayPaths` with `static var defaultDatabaseURL: URL` returning `~/Library/Application Support/Jarvis/replay.db`. Creates parent dir with `createDirectory(withIntermediateDirectories: true)`.

**`ReplayEvent.swift`** — the public enum with ten cases per `<interfaces>` plus a helper extension:

- `extension ReplayEvent { public func encoded() -> (kind: String, payloadBytes: Data) }`
- For textual cases (`.textDelta`, `.thinkingDelta`, `.stopReason`), payloadBytes = UTF-8 bytes of the string.
- For binary cases (`.userInput`, `.toolResultFull`, `.usage`, `.hudEvent`, `.error`), payloadBytes = the carried Data.
- For `.toolCallRequested(id, name, argsJSON)`, serialize `{"id":id,"name":name,"args_json":<base64 of argsJSON>}` as JSON (use `JSONEncoder` + base64 string for the inner `Data`).
- For `.turnEnd`, payloadBytes = empty Data.

Write `SchemaTests.swift` with the seven tests from `<behavior>`. Use `NSTemporaryDirectory()` + UUID-suffixed DB paths; tearDown unlinks via FileManager.

Commit: `feat(04-03): scaffold Replay package with hand-rolled SQLite wrapper + schema DDL (OBS-02)`.
  </action>
  <verify>
    <automated>cd packages/Replay && swift build 2>&1 | tee /tmp/build-04-03-t1.log && swift test --filter SchemaTests 2>&1 | tee /tmp/test-04-03-t1.log && grep -c "Test Suite 'All tests' passed" /tmp/test-04-03-t1.log</automated>
  </verify>
  <done>
    - `cd packages/Replay && swift build` exits 0.
    - `cd packages/Replay && swift test --filter SchemaTests` exits 0 with 7 tests passing.
    - `grep -c 'journal_mode=WAL' packages/Replay/Sources/Replay/Schema.swift` at least 1.
    - `grep -c 'synchronous=NORMAL' packages/Replay/Sources/Replay/Schema.swift` at least 1.
    - `grep -c 'busy_timeout=3000' packages/Replay/Sources/Replay/Schema.swift` at least 1.
    - `grep -c 'foreign_keys=ON' packages/Replay/Sources/Replay/Schema.swift` at least 1.
    - `grep -c 'SQLite.swift' packages/Replay/Package.swift` equals 0 (hand-rolled per research §11 rationale).
    - `grep -c 'import SQLite3' packages/Replay/Sources/Replay/SQLiteConnection.swift` at least 1.
  </done>
</task>

<task type="auto" tdd="true">
  <name>Task 2: ReplayLog actor + OrphanDetector — batched writes + OBS-07 crash recovery</name>
  <files>
    packages/Replay/Sources/Replay/ReplayLog.swift,
    packages/Replay/Sources/Replay/OrphanDetector.swift,
    packages/Replay/Tests/ReplayTests/ReplayLogTests.swift,
    packages/Replay/Tests/ReplayTests/OrphanDetectorTests.swift
  </files>
  <behavior>
    - Test L1 (ReplayLogTests): `beginSession` inserts a row in sessions; returns a SessionID whose rawValue is a valid UUID string.
    - Test L2 (ReplayLogTests): `startTurn` inserts a row with ended_at IS NULL, stop_reason IS NULL, retry_of matching the passed value, turn_nonce matching.
    - Test L3 (ReplayLogTests): `record(.textDelta("a"), for: id)` followed by 63 more `record(.textDelta(...))` within 10ms — all buffered, 0 rows in events table until flush window elapses OR turn_end is called.
    - Test L4 (ReplayLogTests): `endTurn(id, stopReason: "end_turn")` triggers synchronous flush + fsync; immediately after, events table contains all 64 records AND turns.ended_at is non-null AND turns.stop_reason equals "end_turn".
    - Test L5 (ReplayLogTests): Batching trigger (50ms window) — record 3 events, wait 60ms, query events table - 3 rows present without calling endTurn.
    - Test L6 (ReplayLogTests): Batching trigger (64-event chunk) — record 64 events in a tight loop (no await/sleep) - events table receives the batch when the 64th lands.
    - Test L7 (ReplayLogTests): Full-blob toolResultFull — record `.toolResultFull(toolUseId: "x", bytes: <128KB Data>)` — after flush, events.payload_bytes is exactly 128KB (NOT truncated; the 8KB cap is the orchestrator concern, not the replay log's).
    - Test L8 (ReplayLogTests): Nothing-masked - record event with known byte pattern (e.g., "sk-ant-FAKE123"), flush, read back - events.payload_bytes contains the exact original bytes (replay log is the authoritative source; redaction is viewer-side in P8).
    - Test O1 (OrphanDetectorTests): Seed 1 session + 2 turns (turn_a has ended_at=ts with turn_end event, turn_b has ended_at=NULL with no turn_end event) - `recoverOrphans()` returns [turn_b.id]; after call, turn_b has ended_at not null, stop_reason='orphan_recovered', recovery_marker matching `detected_at_launch:crash_count=\d+`.
    - Test O2 (OrphanDetectorTests): A turn with ended_at IS NULL but WITH an event of kind='turn_end' - NOT considered orphan (race-window case). Recover query uses `turn_id NOT IN (SELECT turn_id FROM events WHERE kind = 'turn_end')`.
    - Test O3 (OrphanDetectorTests): `meta.crash_count` is incremented by 1 on each `recoverOrphans()` call. After three calls, value is "3". Stream_truncated retries do NOT touch crash_count (that's orchestrator's concern - documented).
    - Test O4 (OrphanDetectorTests): Crash-injection simulation — open DB, beginSession, startTurn, record 3 events, **do not call endTurn, do not call close** (simulating crash), open a fresh ReplayLog on the same DB path - run OrphanDetector.recoverOrphans() - the open turn is marked with recovery_marker.
  </behavior>
  <action>
**`ReplayLog.swift`** — actor with these responsibilities:

- Owns one `SQLiteConnection`.
- On init: open DB via `SQLiteConnection.open(at:)`, execute each pragma from `Schema.pragmas`, execute each DDL from `Schema.allStatements`, execute each seed from `Schema.seedMeta`.
- `beginSession(appVersion:buildSHA:)` — `id = SessionID(rawValue: UUID().uuidString)`; timestamp = `Int64(clock().timeIntervalSince1970 * 1_000_000_000)`; `INSERT INTO sessions(session_id, started_at, app_version, build_sha) VALUES (?,?,?,?)`.
- `startTurn(turnId:sessionId:retryOf:turnNonce:source:provider:modelId:)` — compute `now` via `clock()` and `mono` via `clock_gettime_nsec_np(CLOCK_UPTIME_RAW)` (or `DispatchTime.now().uptimeNanoseconds` fallback). Bind retry_of as .null if nil else .text. Insert into turns with ended_at/stop_reason/recovery_marker all NULL.
- `record(_ event:for turnId:)` — append to `pendingWrites` buffer. If buffer ≥ 64 → `flushPending()`. Else if flushTask is nil, schedule one via `Task { try? await Task.sleep(for: .milliseconds(50)); await windowFlushFired() }`.
- `flushPending()` — if empty, return. Else begin transaction, INSERT each pending event into events table, commit, clear buffer. On error, rollback and log via `Logger(label: JarvisLogChannel.replay.rawValue).error(...)` — do NOT propagate (replay is best-effort so a failed write does not crash a turn).
- `endTurn(_ turnId:stopReason:)` — first `record(.turnEnd, for: turnId)`, then `flushPending()` (forces everything through), then UPDATE turns SET ended_at=?, stop_reason=? WHERE turn_id=?, then `PRAGMA wal_checkpoint(TRUNCATE)` for fsync.
- `close()` — cancel flushTask, flushPending, decrement `meta.crash_count` (`UPDATE meta SET value = CAST(value AS INTEGER) - 1 WHERE key='crash_count'`), close connection.

Constants: `batchMaxEvents = 64`, `batchWindowMs = 50`.

Clock parameter `@Sendable () -> Date` defaulted to `{ Date() }` for tests.

**`OrphanDetector.swift`** — actor with `recoverOrphans() -> [TurnID]`:

Steps per research §8:

1. Open a fresh `SQLiteConnection` (the detector is separate from ReplayLog to support running before ReplayLog starts accepting writes).
2. `UPDATE meta SET value = CAST(value AS INTEGER) + 1 WHERE key='crash_count'`.
3. `SELECT value FROM meta WHERE key='crash_count'` — remember as `crashCount`.
4. Query: `SELECT turn_id FROM turns WHERE ended_at IS NULL AND turn_id NOT IN (SELECT turn_id FROM events WHERE kind='turn_end')` — collect orphan IDs.
5. For each orphan: `UPDATE turns SET ended_at = ?, stop_reason = 'orphan_recovered', recovery_marker = ? WHERE turn_id = ?` with recovery_marker = `"detected_at_launch:crash_count=\(crashCount)"`.
6. Log via `Logger(label: JarvisLogChannel.replay.rawValue).info(...)`.
7. Return the orphan TurnIDs.

Close the connection on exit (the ReplayLog opens its own; they don't share).

Tests in `ReplayLogTests.swift` and `OrphanDetectorTests.swift` per `<behavior>`. Use per-test temp directories + teardown unlink.

Commit: `feat(04-03): ReplayLog actor with batched writes + OrphanDetector for OBS-07 crash recovery`.
  </action>
  <verify>
    <automated>cd packages/Replay && swift test --filter ReplayLogTests --filter OrphanDetectorTests 2>&1 | tee /tmp/test-04-03-t2.log && grep -c "Test Suite 'All tests' passed" /tmp/test-04-03-t2.log</automated>
  </verify>
  <done>
    - `cd packages/Replay && swift test --filter ReplayLogTests --filter OrphanDetectorTests` exits 0 with 12 tests passing.
    - `grep -v '^//' packages/Replay/Sources/Replay/ReplayLog.swift | grep -c 'turn_end'` at least 2.
    - `grep -v '^//' packages/Replay/Sources/Replay/OrphanDetector.swift | grep -c 'orphan_recovered'` at least 1.
    - `grep -v '^//' packages/Replay/Sources/Replay/OrphanDetector.swift | grep -c 'recovery_marker'` at least 1.
    - `grep -v '^//' packages/Replay/Sources/Replay/OrphanDetector.swift | grep -c 'NOT IN'` at least 1 (orphan query shape is present).
    - `grep -v '^//' packages/Replay/Sources/Replay/ReplayLog.swift | grep -c 'wal_checkpoint'` at least 1 (fsync boundary on turn_end).
  </done>
</task>

<task type="auto" tdd="true">
  <name>Task 3: TokenDeltaDropOldestChannel + JarvisLogChannel additions</name>
  <files>
    packages/Replay/Sources/Replay/TokenDeltaDropOldestChannel.swift,
    packages/Logging/Sources/JarvisLogging/JarvisLogChannel.swift,
    packages/Replay/Tests/ReplayTests/TokenDeltaDropOldestChannelTests.swift,
    packages/Logging/Tests/JarvisLoggingTests/ChannelTests.swift
  </files>
  <behavior>
    - Test T1 (TokenDeltaDropOldestChannelTests): Initialize with capacity=4, dropTag=.tokenDelta. Send 3 `.tokenDelta` events. Iterator yields 3 events.
    - Test T2 (TokenDeltaDropOldestChannelTests): Initialize capacity=4, dropTag=.tokenDelta. Send 10 `.tokenDelta` events to a consumer that doesn't drain. Iterator, once drained, yields at most 4 events.
    - Test T3 (TokenDeltaDropOldestChannelTests, **critical AGENT-10 invariant**): Initialize capacity=4. Interleave sends: tokenDelta x10, then toolCall x1, then tokenDelta x10. Consumer drains all events. Assert: the toolCall event IS delivered (zero drops for non-dropTag tags). Token deltas may be lossy (fewer than 20 delivered), tool_call count is exactly 1.
    - Test T4 (TokenDeltaDropOldestChannelTests): Load test — 10000 tokenDeltas + 1000 toolCalls interleaved, capacity=2048. Assert consumer receives exactly 1000 toolCalls and at most 2048 tokenDeltas. (Research §6 load test spec.)
    - Test T5 (TokenDeltaDropOldestChannelTests): Non-dropTag sends at overflow SUSPEND the producer (backpressure) — capacity=1 channel, send 1 dropTag (OK), send 1 non-dropTag (suspends until consumer drains).
    - Test T6 (TokenDeltaDropOldestChannelTests): `finish()` terminates the AsyncSequence cleanly; consumer drains remaining buffered items before iterator exits.
    - Test C1 (ChannelTests, Logging package): `JarvisLogChannel.allCases.count == 7`.
    - Test C2 (ChannelTests): Existing channels preserved — `.agent.rawValue == "agent"`, `.tools`, `.ui`, `.system`, `.bus` unchanged.
    - Test C3 (ChannelTests): New channels added — `.replay.rawValue == "replay"`, `.devoverlay.rawValue == "devoverlay"`.
  </behavior>
  <action>
**Update `packages/Logging/Sources/JarvisLogging/JarvisLogChannel.swift`** — ADD two cases (`replay`, `devoverlay`). Keep the existing 5 cases (agent, tools, ui, system, bus) unchanged. Final enum has 7 cases with rawValue matching case name.

`JarvisLogHandlerFactory` from Plan 01-02 dispatches on `label: String`, so new labels route through the existing MultiplexLogHandler (FileLogHandler + OSLogHandler) automatically — no handler code change required.

**`TokenDeltaDropOldestChannel.swift`** — actor wrapping an `AsyncStream<Element>` with a ring buffer + pending-send continuation queue:

- Generic parameter: `Tag: Sendable & Equatable & Hashable`.
- Nested struct `Element` carrying `tag: Tag` + `payload: Data`.
- Init: `(capacity: Int, dropTag: Tag)`. Create an `AsyncStream<Element>` via `AsyncStream.makeStream(of:)` pattern; store the continuation in an actor-held property AND expose the stream as a `nonisolated(unsafe) let` property for `makeAsyncIterator` access.
- `send(_ element:)` logic:
  - If `finished`, return.
  - If `buffer.count < capacity`: append, call `drainOneIntoIterator()`.
  - Else (overflow):
    - If `element.tag == dropTag`: find index of oldest element matching `dropTag` via `buffer.firstIndex(where:)`; remove + append + drain. If no `dropTag` element is in the buffer (all elements are non-dropTag), fall through to suspend.
    - Else (non-dropTag, suspend path): `await withCheckedContinuation { cont in pendingSends.append(cont) }`, then retry `await send(element)`.
- `drainOneIntoIterator()`: if buffer non-empty and iterator continuation exists, `yield(buffer.removeFirst())`. If any pending sender, resume the oldest (`pendingSends.removeFirst().resume()`).
- `finish()`: set `finished = true`, drain remaining buffer to iterator, call `continuation.finish()`, resume any pending senders.
- `nonisolated func makeAsyncIterator() -> AsyncStream<Element>.AsyncIterator` — exposes `stream.makeAsyncIterator()`.

The `nonisolated(unsafe) let stream` pattern is the Swift 6 idiom here: `AsyncStream` is documented Sendable-safe; we just need the iterator factory without crossing actor isolation. This mirrors Plan 01-02's `ISO8601DateFormatter.jarvisShared` pattern.

**Important safety note for implementers:** The re-entrant `await send(element)` after suspension retries could recurse on pathological workloads (many non-dropTag elements waiting). Document in the code comment: "In practice the orchestrator has exactly ONE producer per turn; re-entrancy depth is bounded by consumer-drain rate. For adversarial workloads, use `BoundedAsyncChannel` directly with `.suspend` policy."

Tests per `<behavior>` T1-T6 + C1-C3. T4 uses `Task.detached` producers + `for await` in test body for the consumer.

Commit: `feat(04-03): TokenDeltaDropOldestChannel per-element drop policy + JarvisLogChannel .replay/.devoverlay (AGENT-10)`.
  </action>
  <verify>
    <automated>cd packages/Replay && swift test --filter TokenDeltaDropOldestChannelTests 2>&1 | tee /tmp/test-04-03-t3a.log && cd /Users/james.maes/Git.Local/Kof22/Jarvis/packages/Logging && swift test 2>&1 | tee /tmp/test-04-03-t3b.log && cd /Users/james.maes/Git.Local/Kof22/Jarvis/packages/Replay && swift test 2>&1 | tee /tmp/test-04-03-t3c.log && grep -c "Test Suite 'All tests' passed" /tmp/test-04-03-t3c.log</automated>
  </verify>
  <done>
    - cd packages/Replay && swift test --filter TokenDeltaDropOldestChannelTests exits 0 with 6 tests passing.
    - cd packages/Logging && swift test exits 0 overall (no regression from Plan 01-02 tests; all 13+ tests still pass + 3 new channel tests).
    - cd packages/Replay && swift test exits 0 for the entire package (schema + replay log + orphan + token-drop channel).
    - grep -v "^//" packages/Replay/Sources/Replay/TokenDeltaDropOldestChannel.swift | grep -c "dropTag" at least 2.
    - grep -v "^//" packages/Logging/Sources/JarvisLogging/JarvisLogChannel.swift | grep -c "case replay" at least 1.
    - grep -v "^//" packages/Logging/Sources/JarvisLogging/JarvisLogChannel.swift | grep -c "case devoverlay" at least 1.
  </done>
</task>

</tasks>

<threat_model>
## Trust Boundaries

| Boundary | Description |
|----------|-------------|
| Disk → ReplayLog | The replay.db file is user-readable on disk; secrets stored there would be a PII risk. |
| Orphan turn → orphan-recovery logic | Attacker (unlikely, local-only) might craft a malformed turns row to exploit the UPDATE; SQLite parameterized binding neutralizes. |

## STRIDE Threat Register

| Threat ID | Category | Component | Disposition | Mitigation Plan |
|-----------|----------|-----------|-------------|-----------------|
| T-04-03-01 | Information Disclosure | replay.db contains raw tool_result bytes (clipboard contents, AppleScript outputs) | accept | User-local-only machine; ~/Library/Application Support/Jarvis/ is per-user. Replay log is nothing-masked by design (OBS-02). Users who want to share logs redact manually. Documented; accepted. |
| T-04-03-02 | Tampering | An adversarial process modifies turns table to hide orphans | accept | Same threat model as T-04-03-01 — attacker owns the machine. Defence at this layer is pointless. |
| T-04-03-03 | Denial of Service | Unbounded growth of replay.db | mitigate | Size monitoring deferred to P8 (eval harness runs retention scans). In P4 we log size on each turn_end via Logger(label: JarvisLogChannel.replay.rawValue).debug. Retention policy deferred. |
| T-04-03-04 | Repudiation | Turn ends without a turn_end event (crash before endTurn runs) | mitigate | OBS-07 OrphanDetector. On next launch, orphan turns are identified and marked with recovery_marker — audit trail intact. Tested via O4 crash-injection. |
| T-04-03-05 | Elevation of Privilege | SQL injection via turn_nonce or stop_reason | mitigate | All DB writes use parameterized bindings (SQLiteValue enum + sqlite3_bind_*). No string interpolation into SQL. Grep gate confirms no string-interpolated execute() calls exist. |
| T-04-03-06 | Tampering | TokenDeltaDropOldestChannel — adversarial producer causes tool_call drop via timing | mitigate | AGENT-10 critical invariant. Test T3 + T4 (load test) verify tool_calls never drop regardless of tokenDelta firehose rate. |
</threat_model>

<verification>
- cd packages/Replay && swift build — clean.
- cd packages/Replay && swift test — all tests pass.
- cd packages/Logging && swift test — all tests pass (Plan 01-02 regression suite intact + 3 new channel tests).
- gsd-sdk query frontmatter.validate .planning/phases/04-agent-core/04-03-replay-log-PLAN.md --schema plan returns valid.
- SQL injection grep gate: grep -v "^//" packages/Replay/Sources/Replay/ReplayLog.swift | grep -c "execute.*\\\\(" equals 0 (no string-interp in execute() calls).
</verification>

<success_criteria>
- packages/Replay exists as a new SPM package with hand-rolled SQLite3 wrapper (no SDK).
- Schema has four tables + two indices + seeded meta rows (schema_version + crash_count) per research §8.
- ReplayLog batches writes (50ms window OR 64-event chunk, fsync on turn_end via PRAGMA wal_checkpoint(TRUNCATE)).
- OrphanDetector implements the exact OBS-07 SQL from research §8.
- TokenDeltaDropOldestChannel passes the AGENT-10 load test (1000 tool_calls delivered, ≤2048 tokenDeltas).
- JarvisLogChannel has exactly 7 cases (additive: .replay, .devoverlay); Plan 01-02 5 existing cases unchanged.
- All tests in both packages/Replay and packages/Logging pass.
</success_criteria>

<output>
After completion, create .planning/phases/04-agent-core/04-03-SUMMARY.md per the GSD summary template.
</output>
