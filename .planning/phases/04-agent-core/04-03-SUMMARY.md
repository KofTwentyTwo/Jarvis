---
phase: 04-agent-core
plan: 03
subsystem: replay-log
tags: [replay, sqlite, observability, agent-10, obs-02, obs-07]
requirements-completed: [OBS-02, OBS-07, AGENT-10]
dependency-graph:
  requires: [04-01]
  provides:
    - "ReplayLog actor (consumed by Plan 04-04 orchestrator)"
    - "OrphanDetector (consumed by Plan 04-04 launch path)"
    - "TokenDeltaDropOldestChannel<Tag> (consumed by Plan 04-04 fan-out)"
    - "JarvisLogChannel.replay + .devoverlay (consumed by Plan 04-05 DevOverlay)"
  affects: [04-04, 04-05, 07-memory-vision]
tech-stack:
  added:
    - "libsqlite3 via `import SQLite3` (hand-rolled — Phase 7 sqlite-vec needs load_extension)"
  patterns:
    - "SPM package depending on AgentCore + JarvisLogging + Config"
    - "Hand-rolled SQLite wrapper with parameterised SQLiteValue enum bindings (no string interpolation)"
    - "Actor-owned single SQLite connection (FULLMUTEX)"
    - "Idempotent open: pragmas + IF NOT EXISTS DDL + INSERT OR IGNORE seed"
    - "Generation-counter pattern to coordinate timer-flush vs chunk-flush"
key-files:
  created:
    - "packages/Replay/Package.swift"
    - "packages/Replay/Sources/Replay/SQLiteConnection.swift"
    - "packages/Replay/Sources/Replay/Schema.swift"
    - "packages/Replay/Sources/Replay/ReplayError.swift"
    - "packages/Replay/Sources/Replay/ReplayPaths.swift"
    - "packages/Replay/Sources/Replay/ReplayEvent.swift"
    - "packages/Replay/Sources/Replay/ReplayLog.swift"
    - "packages/Replay/Sources/Replay/OrphanDetector.swift"
    - "packages/Replay/Sources/Replay/TokenDeltaDropOldestChannel.swift"
    - "packages/Replay/Tests/ReplayTests/SchemaTests.swift"
    - "packages/Replay/Tests/ReplayTests/ReplayLogTests.swift"
    - "packages/Replay/Tests/ReplayTests/OrphanDetectorTests.swift"
    - "packages/Replay/Tests/ReplayTests/TokenDeltaDropOldestChannelTests.swift"
    - "packages/Logging/Tests/JarvisLoggingTests/ChannelTests.swift"
  modified:
    - "packages/Logging/Sources/JarvisLogging/JarvisLogChannel.swift"
    - "packages/Logging/Tests/JarvisLoggingTests/LoggingTests.swift"
decisions:
  - "Hand-rolled libsqlite3 — no SQLite.swift dependency (Phase 7 sqlite-vec needs load_extension which the mainline package statically blocks)."
  - "Pragmas: WAL + synchronous=NORMAL + busy_timeout=3000 + foreign_keys=ON + temp_store=MEMORY."
  - "Batch policy: 50ms window OR 64-event chunks, whichever fires first. fsync via PRAGMA wal_checkpoint(TRUNCATE) only on turn_end."
  - "Per-element drop policy in TokenDeltaDropOldestChannel: drop oldest dropTag elements on overflow; non-dropTag elements SUSPEND. Saturated-with-non-dropTag fallback also suspends rather than dropping a protected event."
  - "crash_count: incremented in OrphanDetector.recoverOrphans on launch; decremented in ReplayLog.close on clean shutdown."
  - "OrphanDetector heuristic: ended_at IS NULL AND turn_id NOT IN (SELECT turn_id FROM events WHERE kind='turn_end'). The NOT IN clause covers the race where turn_end was recorded but the UPDATE on turns.ended_at hadn't run."
  - "Replay log is best-effort observability: write failures log via JarvisLogChannel.replay but never propagate into orchestrator turn semantics."
  - "ReplayEvent.encoded() emits raw bytes for textual/binary cases; tool_call_requested + tool_result_full use a JSON envelope with base64-encoded inner bytes so binary tool results round-trip."
metrics:
  duration: "approx 30min"
  tasks: 3
  files-created: 14
  files-modified: 2
  source-loc: 936
  test-loc: 789
  tests-added: 25
---

# Phase 4 Plan 04-03: Replay Log Summary

On-disk turn-level audit log (OBS-02), launch-time orphan recovery (OBS-07), and the per-element drop policy primitive that enforces the AGENT-10 critical invariant (`tool_calls` are never dropped under token firehose load). Hand-rolled libsqlite3 wrapper — no SQLite.swift dependency, because Phase 7 needs `load_extension` for sqlite-vec.

## What ships

- **`packages/Replay`** — new SPM library, three deps (AgentCore, JarvisLogging, Config), Swift 6 language mode.
- **`SQLiteConnection`** — thin sqlite3 wrapper with parameterised bindings (`SQLiteValue` enum), prepared statements, FULLMUTEX. Single chokepoint for all SQL writes.
- **`Schema`** — DDL verbatim from research §8: meta + sessions + turns + events tables, `events_by_turn` + `turns_by_session` indices, pragmas, INSERT OR IGNORE seed of `schema_version=1` + `crash_count=0`.
- **`ReplayLog`** — actor with `beginSession` / `startTurn` / `record` / `endTurn` / `close`. Writes batched in 50ms window OR 64-event chunks. `endTurn` appends a `turn_end` event, flushes, UPDATEs the row, then `PRAGMA wal_checkpoint(TRUNCATE)` for the per-turn fsync moment.
- **`OrphanDetector`** — actor that opens its own connection (so it can run before `ReplayLog.init`), bumps crash_count, runs the OBS-07 query, stamps each orphan with `stop_reason='orphan_recovered'` + `recovery_marker='detected_at_launch:crash_count=N'`.
- **`TokenDeltaDropOldestChannel<Tag>`** — actor-backed AsyncSequence. Overflow drops oldest `dropTag` elements only; any other tag SUSPENDS the producer.
- **`JarvisLogChannel`** — additive `.replay` + `.devoverlay` cases (5 -> 7 total; existing routes through MultiplexLogHandler unchanged).

## Verification

| Suite | Tests | Result |
|-------|-------|--------|
| `packages/Replay` (full) | 25 | pass (Schema 7, ReplayLog 8, OrphanDetector 4, TokenDeltaDropOldestChannel 6) |
| `packages/Logging` | 17 | pass (Plan 01-02 regression intact + 3 new ChannelTests + updated `test_sevenChannelsAreDefined`) |
| `packages/Bus` | 47 | pass (no regression) |
| `packages/Replay` release build | — | exit 0 |

**AGENT-10 load test (T4):** 10,000 tokenDelta + 1,000 toolCall events interleaved into a `capacity=2048` channel. Result: **exactly 1000 toolCalls delivered (zero drops on the protected tag)**; tokenDeltas bounded by drop policy. Test passes — the channel does what the invariant says it must.

**Crash-injection test (O4):** Open ReplayLog, beginSession, startTurn, record events, then drop the actor without calling `endTurn` or `close` (SIGKILL parity). Re-open via OrphanDetector — the in-flight turn is correctly identified and stamped.

**SQL injection guard:** `grep -E 'execute\(.*\\\(|exec\(.*\\\('` against `ReplayLog.swift` returns 0 (no string-interpolated SQL). All writes use the `SQLiteValue` parameterised binding path.

**SQLite.swift:** zero entries in `Replay/Package.swift`. Only mention in source is a doc comment in `SQLiteConnection.swift` explaining why we don't use it.

## Deviations from Plan

**[Rule 3 — Blocking issue] Logging test updated to assert 7 channels.**
- Found during: Task 2 build (compile error: `JarvisLogChannel.replay` missing).
- Issue: The plan distributes channel-enum extension into Task 3, but `ReplayLog` and `OrphanDetector` reference `JarvisLogChannel.replay` in their loggers and won't compile without it.
- Fix: Added `case replay` + `case devoverlay` to `JarvisLogChannel.swift` during Task 2 (one commit earlier than the plan suggested). Also updated `LoggingTests.test_fiveChannelsAreDefined` -> `test_sevenChannelsAreDefined` in the same commit so the existing assertion stays green. Task 3 still owns the dedicated `ChannelTests.swift` file, the `TokenDeltaDropOldestChannel` implementation, and its 6 tests.
- Files: `packages/Logging/Sources/JarvisLogging/JarvisLogChannel.swift`, `packages/Logging/Tests/JarvisLoggingTests/LoggingTests.swift`.
- Commit: `2614639`.

**[Plan note — schema test S1 query refinement.]**
- The plan's S1 test asserts "exactly four tables" via `SELECT name FROM sqlite_schema WHERE type='table'`. SQLite autocreates `sqlite_sequence` whenever AUTOINCREMENT is used (which `events.row_id` does), so the raw query returns five rows. The S1 test as committed filters with `AND name NOT LIKE 'sqlite_%'` — semantically the same assertion (our four tables are present, no other user tables exist), just SQLite-aware.

## Threat model status

All STRIDE table mitigations from `<threat_model>` are in place:
- T-04-03-04 (repudiation): OrphanDetector tested via O1, O2, O4 — orphan turns get a recovery_marker; turn_end-event race honored.
- T-04-03-05 (SQL injection): every DB write goes through `SQLiteValue` parameterised bindings; the verification grep confirms zero string-interpolated SQL.
- T-04-03-06 (tool_call drop via timing): TokenDeltaDropOldestChannel T3 + T4 tests prove tool_calls survive the firehose.

The accepted threats (T-04-03-01, T-04-03-02) remain accepted — single-user local-only machine, the file is per-user.

## Known Stubs

None at the storage layer.

The replay **viewer** UI is Phase 8 (per OBS-02 the synthetic ID normalisation lives there, not here). The orchestrator side that *consumes* this storage is Plan 04-04 (Wave 3) — `ReplayLog.beginSession` / `record` / `endTurn` are wired in there.

## Phase 4 Wave 3 readiness

Plan 04-04 (orchestrator) can now consume:
- `ReplayLog` for per-turn write paths.
- `OrphanDetector` for the launch boot sequence.
- `TokenDeltaDropOldestChannel` for the AGENT-10 fan-out into the replay log.
- `JarvisLogChannel.replay` for best-effort write logging.
- `JarvisLogChannel.devoverlay` for Plan 04-05 (DevOverlay) traces.

## Self-Check: PASSED

- All 14 created files exist on disk.
- All 3 task commits present in `git log`: `f1f1640` (Task 1), `2614639` (Task 2), `30b6ebd` (Task 3).
- Replay swift test: 25/25 pass.
- Logging swift test: 17/17 pass.
- Bus swift test: 47/47 pass (no regression).
- Replay release build: exit 0.
- SQLite.swift dependency: 0 entries in `Package.swift`.
- AGENT-10 invariant load test (T4): toolCall count = 1000 (exactly), zero drops.
