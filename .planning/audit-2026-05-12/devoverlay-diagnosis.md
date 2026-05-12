# Dev Overlay Diagnosis — 2026-05-12

**Status:** wired-but-dead. The window opens. It renders `DevSnapshot.initial`. It never updates.

## What the menu item does today

`MenuBarContextMenu.swift:29` adds the "Show Dev Overlay" item, calling
`devOverlayToggleAction` → `AppDelegate.toggleDevOverlay()`
(`App/AppDelegate.swift:2654-2659`). That method **lazily constructs**
`DevOverlayWindow()` on first call and toggles its `NSPanel`. So the panel
does appear — and it shows the initial empty `DevSnapshot` forever.

## Why it shows nothing — three independent breaks

**[CRITICAL] Break 1 — `DevSnapshotEmitter` is never instantiated in the app.**
`packages/AgentCore/Sources/AgentOrchestrator/DevSnapshotEmitter.swift` exists
and is fully implemented (subscribes to `OrchestratorEvent`, maintains the
last-5 tool-call ring, emits to a `BoundedAsyncChannel<DevSnapshot>`). But
`grep -rn DevSnapshotEmitter App/` returns zero hits except a stale comment at
`AppDelegate.swift:381`. The emitter has tests
(`packages/AgentCore/Tests/AgentOrchestratorTests/DevSnapshotEmitterTests.swift`)
but no production consumer. No instance is built, no orchestrator events flow
through it, no snapshots are produced.

**[CRITICAL] Break 2 — the `.devOverlay` broadcaster subscriber drains to `/dev/null`.**
`AppDelegate.swift:1808-1813` subscribes a `.devOverlay`-priority subscriber
on the `OrchestratorEventBroadcaster` and immediately throws every event away:

```swift
for await _ in devSub.stream {        // events arrive…
    if Task.isCancelled { break }     // …and are dropped on the floor.
}
```

The comment at line 1803 admits this: *"reserved for the DevOverlay emitter
wiring in a follow-on plan"*. The follow-on plan never landed.

**[CRITICAL] Break 3 — `DevOverlayWindow` is constructed standalone, with no `DevOverlayBridge`.**
`AppDelegate.swift:2654`: `devOverlayWindow = DevOverlayWindow()`. That calls
`DevOverlayWindow.init()` which creates a fresh `DevOverlayViewModel(snapshot: .initial)`
and a fresh `DevOverlayView`. Nothing ever calls `viewModel.apply(_:)`. The
`DevOverlayBridge.attach(channel:)` API (`DevOverlayBridge.swift:30`) is the
intended writer — it's never instantiated either.

## The flow as-designed vs. as-built

Designed (per `04-RESEARCH.md §9` referenced in `DevOverlayView.swift:8`):
```
OrchestratorEvent stream → DevSnapshotEmitter (apply + ring) →
    BoundedAsyncChannel<DevSnapshot> → DevOverlayBridge →
        viewModel.apply(snap) → SwiftUI re-render
```

Built:
```
OrchestratorEvent stream → broadcaster.subscribe(.devOverlay) → /dev/null
                                                                ^
DevOverlayWindow → DevOverlayViewModel(.initial) → SwiftUI render (initial only)
```

The two halves never meet. Phase 4 shipped the components; Phase 9
("wired but dead" audit) flagged this — `.planning/source-material/` audit
rounds R3/R4 are exactly this class of gap.

## Git history of the feature

- `1aeec87` (P4): DevOverlay package + `DevSnapshot` + `ToolCallRow` types
- `5e50f40` (P4): `DevSnapshotEmitter` aggregates events → snapshot
- `b389455` (P4): tests
- `877f42b`, `467a9bb`, `d23ee60`: review fixes (ME-01/02 — single-write-path)
- `c7242ed`: menu-bar item wired to `toggleDevOverlay` — but **the wiring stopped at constructing the window**. No emitter, no bridge.

## Scope deltas vs. user intent

User wants: "current agent state, last 5 tool calls (inputs + outputs),
context token count, per-turn latency breakdown" + **live log stream from
every part of the system**.

Built but not connected: state / last-5 tools / token counters / latency
(all in `DevSnapshot`). Slice 2 = wire the existing pieces together.

Not built at all: live log stream. swift-log handlers only multiplex to
file + os.Logger (`LoggingBootstrap.swift:16`). No broadcast handler exists.
Slice 3 = build it.

Also missing from current design: subsystem health (BootHealth) and
HUD/voice/presence state fields. Slice 2 adds these to the snapshot or to
sibling panes.
