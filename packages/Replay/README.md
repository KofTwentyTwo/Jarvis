# Replay

Per-turn NDJSON log under `~/Library/Application Support/Jarvis/replay/`. Every turn writes a full transcript of LLM events, tool calls (pre- and post-sanitize bytes both, per SEC-07), memory mutations, and stop reason. The replayer is a developer tool, not user-facing.

## Key public types

| Type | Purpose |
|------|---------|
| `ReplayLog` (actor) | The single writer; rotated per session |
| `ReplayEvent` | NDJSON event union — `turnStart`, `userInput`, `tokenDelta`, `toolCallRequested`, `toolResult`, `memoryRetrieval`, `memoryFactAdded`, `memoryFactUpdated`, `memoryFactForgotten`, `turnEnd` |
| `ReplaySession` | Session-level rollup (multiple turns) |
| `ReplayPaths` | Path resolver |

## Depends on

`AgentCore`, `Config`, `Logging`. External: `swift-log`.

## Used by

`App/AppDelegate`, `packages/AgentCore` (`AgentOrchestrator` is the primary writer), `packages/Memory` (writes mutation + retrieval events), `App/MCP/ReplayingToolResultObserver.swift` (writes pre/post sanitize bytes).

## Key invariants / contracts

- **`ReplayLog` is the single writer per session file.** Multi-writer is undefined.
- **`turnNonce` is persisted in replay rows but never on the bus** (SEC-06).
- **Pre- and post-sanitize bytes both go to replay** (SEC-07). The model only sees post-sanitize.
- **`replayLog.beginSession` is called before any turn.** Pre-audit BLOCKER fixed (audit-2026-05-04).
- **NDJSON format.** Each line is one event, JSON-encoded. Newline-delimited; no leading/trailing whitespace within events.

## Tests

XCTest. Round-trip serialization tests, session rollover, file-handle leak detection (`packages/Harness/FDLeakDetector` SEC-08).

## Notable files

- `Sources/Replay/ReplayLog.swift` — the writer actor
- `Sources/Replay/ReplayEvent.swift` — event union
- `Sources/Replay/ReplaySession.swift` — session rollup
