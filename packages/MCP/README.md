# MCP

Tool dispatch + child-process spawning. Two library products: `JarvisMCP` (the dispatcher chain) and `JarvisChildSpawn` (the FD/env-hardened spawn primitive).

## Key public types

### `JarvisMCP`

| Type | Purpose |
|------|---------|
| `MCPClient` (actor) | Registry of `MCPServerHandle` actors; per-server restart mutex; tool→server lookup |
| `MCPServerHandle` (actor) | One running helper process; restart task slot; tools/list cache |
| `ToolRegistry` | Plain-data registry of `ToolMetadata` (name, server, schema, requiresConfirmation) |
| `MCPToolDispatcher` | Inner dispatcher (Plan 05-04) — direct call routing |
| `ConfirmingToolDispatcher` | Outer dispatcher (Plan 05-05) — gates `requiresConfirmation: true` through broker |
| `ConfirmationBroker` / `ConfirmationPresenter` | Awaitable confirmation channel + UI presenter |
| `ConfirmationOutcome` | `.approved` / `.denied` / `.timeout` |
| `SanitizeForModel` | Wraps tool results in `UntrustedWrapper` + applies 8 KB cap |
| `InProcessTool` (protocol) | Contract for in-process tools (no helper spawn) |
| `InProcessToolRegistry` | Separate registry for in-process tools |
| `SearchMemoryTool` / `ForgetFactTool` | Memory in-process tools (Track D-2). Gated on store + search availability in `AppDelegate` |
| `SearchConversationTool` | In-process scaffold (code-present; not yet registered in `App/`) |
| `ListAudioDevicesTool` / `GetActiveAudioRouteTool` / `GetSelfStateTool` / `ListCameraDevicesTool` | Phase 10 / Wave-1 self-knowledge tools (`74b9ac2`). All read-only, no confirmation. App-side dispatcher adapters live in `App/MCP/InProcessSelfStateAdapters.swift` |

### `JarvisChildSpawn`

| Type | Purpose |
|------|---------|
| `ChildSpawnGate` | Spawn primitive — `FD_CLOEXEC` on every long-lived parent FD; minimal `PATH=/usr/bin:/bin` env |

## Depends on

`AgentCore`, `Logging`. External: `modelcontextprotocol/swift-sdk v0.12.0`, `swift-log`.

## Used by

`App/MCP/MCPRuntimeWiring.swift`, `App/AppDelegate`, `packages/Vision` (uses `JarvisChildSpawn`), `packages/Memory` (in-process tool adapters wired via `App/MCP/InProcessMemoryAdapters.swift`), `App/MCP/InProcessSelfStateAdapters.swift` (Phase 10 self-knowledge dispatchers), `packages/Harness`.

## Key invariants / contracts

- **`requiresConfirmation: true` for `run_applescript` at TWO sites** (`MCPRuntimeWiring.swift` + the harness adapter). `scripts/check-applescript-confirmation.sh` grep-gates.
- **Per-server restart mutex.** Concurrent callers awaiting a crashed helper share one in-flight restart, never stampede.
- **`ChildSpawnGate` enforces `FD_CLOEXEC`** on every long-lived parent FD (replay log, SQLite WAL).
- **Minimal child env.** `PATH=/usr/bin:/bin` only. No parent env inheritance.
- **`SanitizeForModel` runs `UntrustedWrapper` on every tool result** before the bytes reach the model. Pre-sanitize bytes still go to replay (SEC-07).
- **Tool result content capped at 8 KB.** `ToolResultPacker` (in `AgentCore`) is invoked before model emit.

## Tests

85 XCTest. Crash/restart fixtures via `MockHelper` (a real fixture binary that responds to start/list/call/crash signals), confirmation broker tests, sanitize round-trips, tool-cap-recovery scenarios.

## Notable files

- `Sources/MCP/MCPClient.swift` — top-level facade
- `Sources/MCP/ConfirmingToolDispatcher.swift` — confirmation-gating outer
- `Sources/MCP/SanitizeForModel.swift` — UntrustedWrapper + cap
- `Sources/JarvisChildSpawn/ChildSpawnGate.swift` — FD_CLOEXEC gate
- `Sources/MCP/InProcess/SearchMemoryTool.swift` — in-process memory tool
- `Sources/MCP/InProcess/{ListAudioDevicesTool,GetActiveAudioRouteTool,GetSelfStateTool,ListCameraDevicesTool}.swift` — Phase 10 / Wave-1 self-knowledge tools
