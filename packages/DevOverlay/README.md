# DevOverlay

Cmd+Option+D toggleable debug panel. Shows current agent state, last 5 tool calls (inputs + outputs), context token count, and per-turn latency breakdown. Not user-facing — a developer tool.

## Key public types

| Type | Purpose |
|------|---------|
| `DevOverlayWindow` | The borderless `NSWindow` that hosts the SwiftUI view |
| `DevOverlayView` | SwiftUI panel — state, tool calls, tokens, latencies |
| `DevOverlayViewModel` | Subscribes to `OrchestratorEvent` + `MemoryEvent` streams |
| `DevOverlayBridge` | Wiring from AppDelegate (event-stream subscriber + window controller) |

## Depends on

`AgentCore`, `AgentOrchestrator`, `Logging`. External: `swift-log`.

## Used by

`App/AppDelegate`. Not consumed by other packages.

## Key invariants / contracts

- **Read-only consumer.** DevOverlay never mutates orchestrator/memory state — it only watches.
- **Latency tracking is wall-clock, not LLM-billed.** Per-turn breakdown shows network + decode + tool dispatch separately.
- **Token count is provider-reported usage.** Not a local re-tokenization.

## Tests

XCTest. Snapshot tests on view-model state transitions, integration with mock orchestrator events.

## Notable files

- `Sources/DevOverlay/DevOverlayView.swift` — SwiftUI panel
- `Sources/DevOverlay/DevOverlayViewModel.swift` — event-stream subscriber
- `Sources/DevOverlay/DevOverlayBridge.swift` — AppDelegate wiring
