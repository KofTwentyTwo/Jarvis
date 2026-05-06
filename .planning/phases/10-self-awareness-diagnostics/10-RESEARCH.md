# Phase 10: Self-Awareness & Live Diagnostics — Research

**Researched:** 2026-05-06
**Domain:** macOS native introspection (CoreAudio + AVFoundation + Bundle/ProcessInfo) + AppKit diagnostic surfaces + MCP in-process tool wiring
**Confidence:** HIGH (all 12 research areas grounded in source-verified citations from this codebase or Apple framework headers)

## Summary

Phase 10 is a low-novelty, high-discipline phase. Every required surface has a near-identical analog already shipping in the repo: the four MCP tools mirror `SearchMemoryTool` / `ForgetFactTool` and register via `InProcessToolRegistry`; the system-prompt preamble lands at the single `systemPrompt:` argument site in `App/AppDelegate.swift:1242`; the DevOverlay subscriber fix is purely a wiring repair (the emitter exists in `packages/AgentCore/Sources/AgentOrchestrator/DevSnapshotEmitter.swift` but is never instantiated and the broadcaster's `.devOverlay` subscription is currently a no-op drain at `App/AppDelegate.swift:1325-1330`); the Voice Log window mirrors `DevOverlayWindow` (NSWindow + NSHostingView + frameAutosaveName); the diagnostic menu items extend `MenuBarContextMenu.build(...)` with two new closure-action items; the audio loopback uses the existing `AudioGraphOwner.subscribe()` fan-out; and the TTS playback diagnostic invokes `TTSEngineActor.synthesize(_, tier: .tier1, voice:)` directly.

The dominant risks are not technical — they are procedural. The phase exists because tests-green does not equal production-works, parallel agents on shared files produce partial work, and explicit `requestAccess` is required for TCC. Every plan must end with relaunch evidence in `SUMMARY.md` (D-26..D-28). Plan 10-01 specifically must include a real "Hey Jarvis" utterance in its verification (per `.continue-here.md` blockers).

**Primary recommendation:** Execute the five plans serially in the locked D-02 order. Each plan adds 30–250 LOC + tests + a Live Verification section in its SUMMARY. The single biggest implementation hazard is the `installAgent` ordering for plan 10-03 (the `DevSnapshotEmitter` must be constructed before the broadcaster's `.devOverlay` subscriber Task replaces its current no-op drain, and the `DevOverlayBridge.attach(channel:)` call must run when the window is constructed, not at install time).

## User Constraints (from CONTEXT.md)

### Locked Decisions

**Plan structure & sequence**

- **D-01:** Phase 10 plans run **serially**, single-threaded. No parallel-agent fan-out anywhere inside Phase 10.
- **D-02:** **5 plans expected**, foundation → UI: `10-01` MCP self-knowledge tools (SELF-01..04) → `10-02` system prompt preamble (SELF-05/06) → `10-03` DevOverlay subscriber fix (DIAG-02) → `10-04` audio loopback + TTS playback diagnostics (DIAG-03/04) → `10-05` Voice Log window (DIAG-01).
- **D-03:** **5 plans, not 4 or 6** — keeps foundation/UI split clean, isolates DIAG-01 (largest scope) to its own plan.
- **D-04:** Each plan ends with a **Live Verification section in its SUMMARY.md** with relaunch command + observed log lines (timestamped) + acceptance match.

**`stash@{0}` salvage policy**

- **D-05:** Salvage **selectively per plan**, not wholesale. Stash entry never `git stash apply`'d as a unit.
- **D-06:** Drop the stash only after Plan 10-05 SUMMARY.md is committed.

**Self-knowledge tool implementation (Plan 10-01)**

- **D-07:** All four tools follow the **`InProcessMemoryAdapters.swift` pattern** from Track D-2 (`commit 707c45b`).
- **D-08:** **CoreAudio queries are synchronous.** No actor needed for the device list itself. `get_active_audio_route` reads through the live `AudioGraphOwner` actor.
- **D-09:** **No caching of device lists.** Hardware can be unplugged between calls; freshness > performance.
- **D-10:** **`requiresConfirmation: false`** for all four tools — explicitly set, don't rely on default. Add coverage to `MCPRuntimeWiringTests` so a regression that drops one shows up immediately.
- **D-11:** **`get_self_state` snapshots are point-in-time.** No history, no streaming.

**System prompt preamble (Plan 10-02)**

- **D-12:** Emit the preamble from `App/MCP/AppDelegateContextBuilderAdapter.swift` (or `ContextBuilder` host). Compose **before** presence enrichment.
- **D-13:** Preamble is a **single locked string constant** in code (no JSON, no localization).
- **D-14:** **No tool-list duplication in the preamble.** The Anthropic API tools array provides the catalog; the preamble nudges.

**DevOverlay fix (Plan 10-03)**

- **D-15:** **Read-only investigation comes first.** First commit is the investigation note; fix commit comes second.
- **D-16:** **Minimum surgical change.** Touch the smallest set of lines that makes AC-08 pass.

**Diagnostic menu items (Plan 10-04)**

- **D-17:** Both menu items live in `App/MenuBar/MenuBarContextMenu.swift` under a "Diagnostics" submenu.
- **D-18:** **Audio loopback uses `AudioGraphOwner.subscribe()`** — same path Track B-7 introduced.
- **D-19:** **TTS playback uses `TTSEngineActor` tier-1 (`AVSpeechSynthesizer`)** with the fixed phrase "Jarvis is online".

**Voice Log window (Plan 10-05)**

- **D-20:** `VoiceLogPublisher` is an **actor** (Swift 6 strict concurrency).
- **D-21:** **In-memory only**, capped at **2000 events** with FIFO eviction.
- **D-22:** Event taxonomy locked, not extensible inside this phase: `wakeWordFired`, `wakeWordPaused`, `wakeWordResumed`, `vadSpeechStart`, `vadSpeechEnd`, `sttPartial`, `sttFinal`, `ttsSynthesizeStart`, `ttsSynthesizeComplete`, `ttsCancelled`, `voiceStateTransition(from:to:)`, `audioLevelRMS(value:)` (rate-limited ≤1 Hz at the publish site), `voiceError`.
- **D-23:** **AppKit window**, NOT WKWebView. Mirrors `DevOverlayWindow.swift`. Frame autosave via `NSWindow.frameAutosaveName`.
- **D-24:** RMS rate-limiting is **at the publisher side** (drop intermediate samples).
- **D-25:** Subscriber adapters live in `App/Voice/VoiceLogAdapters.swift`. Each existing voice surface (WakeWordDAG, VADGatedSession, LiveSpeechAnalyzerBridge, TTSEngineActor, VoiceController) gets a small additive `publisher.publish(.event(...))` callsite.

**Live-launch verification gate (cross-cutting)**

- **D-26:** Each plan's `SUMMARY.md` has a `## Live Verification` section (relaunch + observed + acceptance match).
- **D-27:** Tests-green is necessary but not sufficient.
- **D-28:** **TCC re-prompt protocol** when verifying any plan that touches mic/camera/audio: run `tccutil reset Microphone com.koftwentytwo.jarvis` (and/or `Camera`) once before the relaunch.

**Boundary-gate discipline**

- **D-29:** All **18 existing boundary gates** stay green at every plan boundary.
- **D-30:** No new boundary gate is required for Phase 10.

**Naming conventions**

- **D-31:** Test doubles for new code follow CLAUDE.md §"Test naming conventions" (Mock = records-and-scripts; Stub = canned-data; Fake = realistic-stateful).

### Claude's Discretion

- Specific event payload fields on `voiceStateTransition` and `voiceError` (struct shapes are Claude's choice as long as `Sendable`/`Equatable` and easy to render).
- Whether `get_self_state` includes a `git_commit` short-sha string (nice-to-have; include if cheap).
- Whether the audio loopback diagnostic shows a small "Recording…" / "Playing back…" status overlay or stays headless.
- Filter UI specifics in the Voice Log window (checkbox group vs segmented control).

### Deferred Ideas (OUT OF SCOPE)

- Tier-2 Orpheus TTS bring-up (~6 GB weight download, separate phase).
- `vec0.dylib` bundling + Ollama model pulls (Track D-5/6/7).
- `AppDelegate.swift` split refactor (P3, separate phase).
- Bus schema widening (`BusOutbound`/`BusInbound`).
- Voice Log persistence across launches.
- HUD-surfaced diagnostics (chosen as menu items).
- Memory Log companion to Voice Log.
- Self-state historical timeline.
- Camera Log window.

## Phase Requirements

| ID | Description | Research Support |
|----|-------------|------------------|
| SELF-01 | `list_audio_devices` MCP tool | Section 1 — CoreAudio device introspection; D-2 adapter pattern |
| SELF-02 | `get_active_audio_route` MCP tool | Section 1 + Section 8 — `AudioGraphOwner.subscribe()` and current-variant probe; D-08 reads through the actor |
| SELF-03 | `get_self_state` MCP tool | Section 3 — Bundle/ProcessInfo/runtime introspection; main-actor hop policy |
| SELF-04 | `list_camera_devices` MCP tool | Section 2 — `AVCaptureDevice.DiscoverySession` on macOS 26 Tahoe |
| SELF-05 | Self-aware system prompt | Section 4 — preamble emit point + cache eligibility threshold |
| SELF-06 | Tool catalog visibility (preamble nudge) | Section 4 — single-string discipline; no tool list duplication |
| DIAG-01 | Voice Log window | Section 6 + Section 7 + Section 10 — DevOverlay-mirror window; subscriber attach points; stash salvage triage |
| DIAG-02 | DevOverlay populates during turns | Section 5 — read-only investigation: emitter exists, never instantiated, broadcaster subscription is no-op drain |
| DIAG-03 | Audio loopback diagnostic | Section 8 — `AudioGraphOwner.subscribe()` + AVAudioEngine playback |
| DIAG-04 | TTS playback diagnostic | Section 9 — `TTSEngineActor.synthesize(_, tier: .tier1, voice:)` |

## Project Constraints (from CLAUDE.md)

| Constraint | Source | Phase 10 Implication |
|-----------|--------|---------------------|
| Swift 6 strict concurrency | CLAUDE.md §Constraints | Use actors / `OSAllocatedUnfairLock`; `NSLock` from async forbidden. `VoiceLogPublisher` is an actor (D-20). |
| T-06-05-03 — no transcripts to OSLog | CLAUDE.md + SPEC | Voice Log window may DISPLAY transcripts in-process; MUST NOT route through `Logger` / `os.log`. The stashed `VoiceLogEvent.swift` already documents this contract. |
| VOICE-14 — single `cancelAndSubmit` call site | CLAUDE.md / `VoiceController.swift:344` | No new `cancelAndSubmit` call sites. Audio loopback and TTS playback diagnostics MUST NOT touch the orchestrator's submit path. |
| `requiresConfirmation: true` reserved for `run_applescript` | `MCPRuntimeWiring.swift:113` + `scripts/check-applescript-confirmation.sh` | All four new tools register with `requiresConfirmation: false` explicitly (D-10). |
| 18 boundary gates green at every plan boundary | CLAUDE.md §Build / test | Every plan ends with `bash scripts/check-app-builds.sh` + the relevant grep gates listed in `SUMMARY.md`. |
| MCP via official `modelcontextprotocol/swift-sdk v0.12.0` | RESEARCH-DELTAS | New tools register via `InProcessToolRegistry` (in-process path, not stdio). No SDK API changes needed. |
| Opus 4.7 cache TTL — `extended-cache-ttl-2025-04-11` beta header + 1024-token threshold | CLAUDE.md + `CacheHints.swift:32-46` | `eligibleForSystemPrompt` already returns `nil` below 4096 chars (~1024 tokens); preamble must not push the system block over the boundary unintentionally. See Section 4. |
| Test naming taxonomy (Mock = records, Stub = canned, Fake = realistic) | CLAUDE.md | Phase 10 ships with right names from day one (D-31). |

## Architectural Responsibility Map

| Capability | Primary Tier | Secondary Tier | Rationale |
|------------|-------------|----------------|-----------|
| Audio device introspection (SELF-01) | Native (CoreAudio in-process) | — | `kAudioHardwarePropertyDevices` is a synchronous host-OS query. No network, no actor needed for the call itself. |
| Active audio route (SELF-02) | Native (AudioGraphOwner actor) | — | Reads the live owner's `currentVariant` + the AudioGraph's probed format; must hop into the actor. |
| Self-state (SELF-03) | Native (Bundle + ProcessInfo + actor probes) | — | Static metadata + a few main-actor / actor reads. No I/O. |
| Camera device introspection (SELF-04) | Native (AVCaptureDevice.DiscoverySession) | — | Synchronous discovery API; does NOT trigger TCC prompt (read-only enumeration). |
| System prompt preamble (SELF-05/06) | Native (Swift app — `ContextBuilder`) | LLM (Anthropic / Ollama) | Built in Swift before each turn; consumed by the model. NOT in webview. |
| Voice Log window (DIAG-01) | Native (AppKit + SwiftUI body via NSHostingView) | — | Diagnostic UI; not in HUD webview (D-23). Subscribers are voice subsystems already in Swift. |
| DevOverlay populate (DIAG-02) | Native (existing emitter + bridge + AppKit panel) | — | Wiring repair only; emitter, bridge, and view-model already exist. |
| Audio loopback (DIAG-03) | Native (AVAudioEngine + AudioGraphOwner subscription) | — | Pure I/O — mic frames → speaker. No inference, no webview. |
| TTS playback (DIAG-04) | Native (`AVSpeechSynthesizer` via `TTSEngineActor.tier1`) | — | Existing actor; new caller from menu item. |

## Standard Stack

### Core (already shipping in repo — DO NOT add new packages)

| Library | Version / Source | Purpose | Why Standard |
|---------|------------------|---------|--------------|
| Foundation | macOS 14+ system | Bundle, ProcessInfo, Date, JSONEncoder | Native introspection lives here |
| CoreAudio (`AudioToolbox`) | macOS 14+ system | `AudioObjectGetPropertyData`, `kAudioHardwarePropertyDevices`, `kAudioDevicePropertyStreams`, `kAudioDevicePropertyDeviceUID` | Standard low-level audio device enumeration; precedent inside repo at `build-devoverlay/SourcePackages/checkouts/argmax-oss-swift/Sources/WhisperKit/Core/Audio/AudioProcessor.swift:818-879` |
| AVFoundation (`AVCaptureDevice`, `AVAudioEngine`, `AVSpeechSynthesizer`) | macOS 14+ system | Camera discovery; mic stream; tier-1 TTS | Already used in `installVoice` and `installVision`; explicit `requestAccess` calls landed in `b92d062` |
| AppKit (`NSWindow`, `NSPanel`, `NSHostingView`, `NSMenuItem`) | macOS 14+ system | Diagnostic windows + menu items | Mirrors existing `DevOverlayWindow.swift:32-48` pattern |
| SwiftUI + Observation (`@Observable`) | macOS 14+ system | View-model surface inside the AppKit shell | Same pattern as `DevOverlayViewModel.swift:17-42` |
| `JarvisMCP` (in-tree) | this repo, `packages/MCP/Sources/MCP/` | `InProcessTool` protocol + `InProcessToolRegistry` actor | Phase 7 Track D-2 in-process tool path; no helper-spawn for read-only introspection |
| `AgentCore` / `AgentOrchestrator` (in-tree) | this repo | `OrchestratorEvent` stream, `DevSnapshotEmitter`, `DevSnapshot`, `BoundedAsyncChannel` | Plumbing already present for DevOverlay; only wiring is missing |
| `Voice` (in-tree) | this repo, `packages/Voice/Sources/Voice/` | `AudioGraphOwner.subscribe()`, `TTSEngineActor`, `VoiceController.state`, `WakeWordDAG.wakeWordStream` | All publish/subscribe surfaces for Voice Log already exist |

### Alternatives Considered

| Instead of | Could Use | Tradeoff (rejected) |
|------------|-----------|---------------------|
| `InProcessTool` for the four self-knowledge tools | Stdio-framed helper apps (mcp-self-state etc.) | Each helper would need its own codesigned nested bundle + entitlements + spawn; introspection tools have zero security boundary value (read-only, no IPC) and the overhead is wrong for a debug-class capability. **Locked by D-07.** |
| `WKWebView`-hosted Voice Log | Native AppKit window | Webview would widen `WKContentWorld` discipline + introduce a second bus surface. **Locked by D-23.** |
| Tier-2 Orpheus for the playback diagnostic | Tier-1 `AVSpeechSynthesizer` | Tier-2 depends on ~6 GB weight download (deferred). The diagnostic exists to verify the speaker route, not voice character. **Locked by D-19.** |
| Persistent Voice Log (SQLite) | In-memory ring | Persisted transcripts conflict with T-06-05-03. **Locked by D-21.** |
| New tap thread for audio loopback | Reuse `AudioGraphOwner.subscribe()` | New tap thread would race the wake-word DAG and require a second teardown path through VOICE-10. **Locked by D-18.** |

### Installation

No new packages. Phase 10 only adds source files inside existing targets.

**Version verification:** N/A — no third-party packages introduced.

## Architecture Patterns

### System Architecture Diagram

```
                    ┌────────────────────────────────────────────────────────────┐
                    │                     AgentOrchestrator                        │
User text  ─────▶   │   submit(text) ──▶ provider.stream ──▶ events ──▶           │
                    │                                          │                   │
                    └──────────────────────────────────────────┼───────────────────┘
                                                                │
                                              OrchestratorEventBroadcaster
                                                  ├── .memory ──▶ MemoryExtractionCoordinator
                                                  ├── .transcript ──▶ TurnTranscriptStore
                                                  ├── .devOverlay ──▶ ⓧ no-op drain (DIAG-02 fixes)
                                                  ├── .frameAttach ──▶ FrameAttachController
                                                  ├── .voice ──▶ VoiceOrchestratorAdapter
                                                  └── .bus ──▶ OutboundBatcher ──▶ webview HUD
                                                          ▲
                                                          │
                  Phase 10 Plan 10-03 inserts here:
                  let emitter = DevSnapshotEmitter(provider:..., modelId:...)
                  Replace devOverlay drain with: for await ev in devSub.stream { await emitter.apply(ev) }
                  At toggleDevOverlay(): bridge.attach(channel: emitter.output)


                    ┌────────────────────────────────────────────────────────────┐
                    │                       MCPRuntime                             │
LLM tool call ─▶   │  dispatcher → ConfirmingToolDispatcher → MCPToolDispatcher   │
                    │                                              │                │
                    └──────────────────────────────────────────────┼────────────────┘
                                                                    │
                                                                    ▼
                                            spawned helpers + InProcessToolRegistry
                                                                    │
                                       Phase 10 Plan 10-01 adds 4 InProcessTool registrants:
                                            list_audio_devices       (CoreAudio enum)
                                            get_active_audio_route   (AudioGraphOwner read)
                                            get_self_state           (Bundle + ProcessInfo + state probes)
                                            list_camera_devices      (AVCaptureDevice.DiscoverySession)


                    ┌────────────────────────────────────────────────────────────┐
                    │                        Voice Loop                            │
                    │                                                              │
        Mic ─▶  AudioGraph ─▶ BufferBroadcaster ┬─▶ WakeWordDAG ─▶ VoiceController │
                                                ├─▶ ChunkPump (STT)                │
                                                └─▶ Phase 10 Plan 10-04: 2s probe  │
                    │                                                              │
                    │   VoiceController.state ──▶ TTSEngineActor.synthesize(...)   │
                    │                              tier1: AVSpeechSynth            │
                    │                              tier2: Orpheus (deferred)        │
                    └──────────────────────────────────────────────────────────────┘
                              │
                              │  Phase 10 Plan 10-05: VoiceLogPublisher (actor) gets a thin
                              │  publish() callsite at every italicised event below:
                              │
                              ├─ WakeWordDAG.start ring loop:        wakeWordFired
                              ├─ WakeWordDAG.pause()/resume():       wakeWordPaused/Resumed
                              ├─ VoiceController.runVADInterceptor: vadSpeechStart/End
                              ├─ SpeechAnalyzerSTT partials drain:  sttPartial
                              ├─ VoiceController.handleSTTFinalized: sttFinal
                              ├─ VoiceController.doTransition:      voiceStateTransition
                              ├─ TTSEngineActor.synthesize:         ttsSynthesizeStart/Complete/cancel
                              └─ AudioLevelEmitter:                 audioLevelRMS (≤1 Hz throttled)
```

### Recommended File Layout (additive only)

```
App/
├── MCP/
│   ├── InProcessSelfStateAdapters.swift          # NEW (10-01) — four adapter structs + tool wrappers
│   ├── MCPRuntimeWiring.swift                    # MODIFIED (10-01) — pass new tools into InProcessToolRegistry
│   └── AppDelegateContextBuilderAdapter.swift    # MODIFIED (10-02) — add `static let preamble: String` + emit point
├── MenuBar/
│   └── MenuBarContextMenu.swift                  # MODIFIED (10-04) — add Diagnostics submenu w/ two items
├── Voice/
│   └── VoiceLogAdapters.swift                    # NEW (10-05) — thin sinks adapting voice subsystems → publisher
├── AppDelegate.swift                             # MODIFIED (every plan) — install order, subscriber wiring, menu actions
└── ...
packages/
├── AgentCore/Sources/AgentCore/
│   └── ContextBuilder.swift                      # MODIFIED (10-02) — accept preamble, prepend before presence enrichment
├── AgentCore/Sources/AgentOrchestrator/
│   └── DevSnapshotEmitter.swift                  # UNCHANGED — already correct, just unwired
├── DevOverlay/Sources/DevOverlay/
│   └── (no change — bridge/view-model already correct)
└── VoiceLog/                                     # NEW package (10-05) — salvaged from stash@{0} per D-25
    ├── Package.swift
    ├── Sources/VoiceLog/
    │   ├── VoiceLogEvent.swift                   # SALVAGE candidate (verify against D-22 taxonomy)
    │   ├── VoiceLogPublisher.swift               # SALVAGE candidate (verify against D-20/D-24)
    │   ├── VoiceLogViewModel.swift               # SALVAGE candidate (verify cap @ 2000 per D-21)
    │   ├── VoiceLogView.swift                    # SALVAGE candidate (SwiftUI body)
    │   ├── VoiceLogWindow.swift                  # SALVAGE candidate (NSWindow + frameAutosaveName)
    │   └── VoiceLogBridge.swift                  # SALVAGE — verify NO webview content world
    └── Tests/VoiceLogTests/
        ├── VoiceLogPublisherTests.swift          # SALVAGE
        └── VoiceLogViewModelTests.swift          # SALVAGE
```

### Pattern 1: In-Process MCP Tool Adapter

**What:** Adapter struct conforms to a per-tool `*Dispatching` protocol; tool wrapper conforms to `InProcessTool`; both register via `InProcessToolRegistry`.
**When to use:** Read-only or in-process introspection where stdio framing adds no value.
**Source citation:** `packages/MCP/Sources/MCP/InProcess/SearchMemoryTool.swift:25-66`; `App/MCP/InProcessMemoryAdapters.swift:22-56`.

**Skeleton (use verbatim, swap names):**

```swift
// In packages/MCP/Sources/MCP/InProcess/ListAudioDevicesTool.swift  (NEW or existing pattern)
public protocol AudioDeviceListing: Sendable {
    func listAudioDevices() async throws -> [AudioDeviceEntry]
}

public struct AudioDeviceEntry: Sendable, Codable, Equatable {
    public let name: String
    public let uid: String
    public let isDefault: Bool
    public let isActive: Bool
    public let sampleRate: Double
    public let channels: Int
    public let direction: String   // "input" | "output"
}

public struct ListAudioDevicesTool: InProcessTool {
    public let name = "list_audio_devices"
    public let requiresConfirmation = false        // D-10 explicit
    public var schemaJSON: Data { /* trivial: object with no required props */ }
    private let dispatcher: any AudioDeviceListing
    public init(dispatcher: any AudioDeviceListing) { self.dispatcher = dispatcher }
    public func call(args: Data) async throws -> Data {
        let entries = try await dispatcher.listAudioDevices()
        return try JSONEncoder().encode(["devices": entries])
    }
}

// In App/MCP/InProcessSelfStateAdapters.swift  (NEW)
public struct CoreAudioDeviceListAdapter: AudioDeviceListing {
    public init() {}
    public func listAudioDevices() async throws -> [AudioDeviceEntry] {
        // Synchronous CoreAudio query (D-08); off-hop into a Task if you
        // want to avoid blocking the actor caller on a cold device list.
        try CoreAudioIntrospection.snapshotDevices()
    }
}
```

**Registration (in `installAgent` or a dedicated `installSelfKnowledge`):**

```swift
let inproc = InProcessToolRegistry()
await inproc.register(ListAudioDevicesTool(dispatcher: CoreAudioDeviceListAdapter()))
await inproc.register(GetActiveAudioRouteTool(dispatcher: AudioGraphRouteAdapter(owner: audioGraphOwner)))
await inproc.register(GetSelfStateTool(dispatcher: SelfStateAdapter(...)))
await inproc.register(ListCameraDevicesTool(dispatcher: AVCaptureDeviceListAdapter()))
```

Then thread `inproc` into `MCPToolDispatcher` (which is the existing aggregation point — verify the path used by `SearchMemoryTool` in plan 07-06's `installMemory`).

### Pattern 2: AppKit Diagnostic Window (mirror of DevOverlay)

**What:** `NSWindow` (not NSPanel for Voice Log per stashed precedent — long-lived; use `.utilityWindow` `NSPanel` for ephemeral overlays) hosting `NSHostingView<SwiftUIView>`, with `frameAutosaveName` for position persistence. Hidden by default; show/hide on menu toggle.
**When to use:** Any diagnostic surface that should not pollute the always-on HUD.
**Source citation:** `packages/DevOverlay/Sources/DevOverlay/DevOverlayWindow.swift:32-48`; salvaged Voice Log mirror at `stash@{0}:packages/VoiceLog/Sources/VoiceLog/VoiceLogWindow.swift` (lines 28-58 of the stashed file).

```swift
@available(macOS 14.0, *)
@MainActor
public final class VoiceLogWindow {
    private let window: NSWindow
    public let viewModel: VoiceLogViewModel
    public init(viewModel: VoiceLogViewModel = VoiceLogViewModel()) {
        self.viewModel = viewModel
        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 480),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: true
        )
        w.title = "Jarvis Voice Log"
        w.isReleasedWhenClosed = false
        w.contentView = NSHostingView(rootView: VoiceLogView(viewModel: viewModel))
        w.setFrameAutosaveName("jarvis-voice-log-window")  // D-23 via NSWindow defaults
        w.center(); w.orderOut(nil)
        self.window = w
    }
    public func show() { window.makeKeyAndOrderFront(nil) }
    public func hide() { window.orderOut(nil) }
    public func toggle() { window.isVisible ? hide() : show() }
}
```

### Pattern 3: Closure-Action Menu Item (existing — extend, don't refactor)

**Source:** `App/MenuBar/MenuBarContextMenu.swift:48-60` (use `makeItem(title:action:)` — handles the `objc_setAssociatedObject` retain trick for the `ClosureTarget` trampoline; don't reinvent).

**Plan 10-04 diff shape:**

```swift
// Add to MenuBarContextMenu.build(...)'s parameter list:
//   audioLoopbackAction: @escaping () -> Void,
//   ttsPlaybackAction: @escaping () -> Void
// And add a Diagnostics submenu before the "Quit Jarvis" separator:

let diagnostics = NSMenuItem(title: "Diagnostics", action: nil, keyEquivalent: "")
let diagSub = NSMenu(title: "Diagnostics")
diagSub.addItem(makeItem(title: "Audio Loopback Test (2s)", action: audioLoopbackAction))
diagSub.addItem(makeItem(title: "Speak Test Phrase",         action: ttsPlaybackAction))
diagnostics.submenu = diagSub
menu.addItem(NSMenuItem.separator())
menu.addItem(diagnostics)
```

The `MenuBarIconControllerTests.swift` parameter list at lines 14, 35, 50 needs the two new closures threaded through (search by `devOverlayToggleAction:`).

### Pattern 4: Actor-Based Publisher with AsyncStream Fan-Out

**What:** A `Sendable` actor with a `nonisolated let stream: AsyncStream<Entry>` and an internal continuation; producers call `await publisher.post(event)`; the AppKit window's bridge consumes the stream on `@MainActor`.
**When to use:** Multi-producer, single-consumer event log where ordering matters and producers come from heterogeneous isolations.
**Source citation:** Stashed `VoiceLogPublisher` actor at `stash@{0}:packages/VoiceLog/Sources/VoiceLog/VoiceLogPublisher.swift:21-87` (review per D-25). Compare against the `BoundedAsyncChannel` pattern used by `DevSnapshotEmitter.output` (`packages/AgentCore/Sources/AgentOrchestrator/DevSnapshotEmitter.swift:24`) — the stashed version uses raw `AsyncStream` with `bufferingPolicy: .bufferingNewest(capacity)`, which matches D-21 (in-memory, FIFO eviction at 2000) but the cap differs (stash uses 1000). Update during salvage.

### Anti-Patterns to Avoid

- **Reaching into `DevOverlayWindow.viewModel` to set fields directly.** The view-model has `private(set)` precisely to enforce single-write-path through `apply(_:)` (`DevOverlayViewModel.swift:23`). Wire the bridge to the emitter's channel; don't shortcut.
- **Adding a second `cancelAndSubmit` call site.** VOICE-14 grep gate fails the build. Audio loopback and TTS playback diagnostics MUST NOT call into orchestrator's submit path.
- **Routing transcript text through `Logger` / `os.log` even "for debug purposes."** T-06-05-03; the Voice Log window may DISPLAY but never LOG. The stashed `VoiceLogEvent.swift` documents this contract at lines 4-9.
- **Spawning a new audio tap for the loopback diagnostic.** Use `AudioGraphOwner.subscribe()` (D-18) — a new tap races the wake-word DAG and corrupts VOICE-10's six-step teardown.
- **Caching the device list in `list_audio_devices` / `list_camera_devices`.** D-09 — staleness > performance for a debug introspection tool.
- **Allowing `requiresConfirmation` to default.** Set `false` explicitly on each new tool (D-10).
- **Refactoring `DevOverlayBridge` or `DevOverlayViewModel` in plan 10-03.** D-16 — minimum surgical change. Bridge and view-model are correct; the bug is upstream wiring.

## Don't Hand-Roll

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| MCP tool registration | A new `*Tool` parallel registry | `InProcessToolRegistry.register(_:)` | Existing path; one `MCPToolDispatcher` aggregation point |
| Multi-consumer audio fan-out | A new `AVAudioEngine` tap | `AudioGraphOwner.subscribe()` (Track B-7) | Existing actor-safe fan-out; collision-free with wake-word DAG |
| TTS invocation | New `AVSpeechSynthesizer` instance | `TTSEngineActor.synthesize(_, tier: .tier1, voice:)` | Existing actor with serial executor + cancellation contract |
| Window position persistence | Custom `UserDefaults` key + frame restore | `NSWindow.setFrameAutosaveName(_:)` | Built into AppKit; round-trips frame + size |
| Menu item closure binding | Inline `NSMenuItem` w/ `target = ClosureTarget()` | `MenuBarContextMenu.makeItem(title:action:)` | Handles the `objc_setAssociatedObject` retain dance correctly (`MenuBarContextMenu.swift:48-60`) |
| Bounded event log | Arrays + manual eviction in `DispatchQueue` | Actor with `AsyncStream` + ring buffer | Swift 6 strict concurrency safe out of the box |
| DevSnapshot accumulation | Hand-rolled tracker per field | `DevSnapshotEmitter.apply(_:)` | Already implements TTFB, total latency, last-5 ring with toolUseId dedup |
| Camera enumeration | `IOKit` calls | `AVCaptureDevice.DiscoverySession(deviceTypes:mediaType:position:)` | Apple-recommended; honors USB cameras, Continuity, etc. |
| Audio device enumeration on macOS | `system_profiler` shell-out | `AudioObjectGetPropertyData(kAudioHardwarePropertyDevices)` | Synchronous, fast, no subprocess |
| System uptime | Manual launch time tracking | `ProcessInfo.processInfo.systemUptime` (host uptime since boot) OR captured `Date()` at launch + delta | The latter is what `get_self_state` should use; system uptime is host, not app |

**Key insight:** Phase 10 is wiring, not architecture. Every "build a thing" instinct should bounce off an existing primitive. The single piece of meaningful new code is `CoreAudioIntrospection.snapshotDevices()` (Section 1 below) — and even that is ~80 LOC of boilerplate around a stable `AudioObjectGetPropertyData` pattern that already lives at `build-devoverlay/SourcePackages/checkouts/argmax-oss-swift/Sources/WhisperKit/Core/Audio/AudioProcessor.swift:818-879` for cross-reference.

## Runtime State Inventory

> Phase 10 is additive — it adds tools/UI surfaces but does not rename, refactor, or migrate existing surfaces. There is no stored data, live service config, OS-registered state, or build artifact that the new code invalidates.

| Category | Items Found | Action Required |
|----------|-------------|------------------|
| Stored data | None — all introspection is ephemeral, all diagnostics are in-memory. Voice Log is explicitly in-memory only (D-21). | none |
| Live service config | None — no external service config touched. The four new MCP tool names register in-process via `InProcessToolRegistry`; LLM tool catalog regenerates per turn. | none |
| OS-registered state | None — no Launch Services, no Task Scheduler, no daemon registration. Menu items are AppKit runtime-only; window frame autosave key (`jarvis-voice-log-window`) is new but in-process `NSWindow` user defaults, not OS-registered. | none |
| Secrets / env vars | None — no new secrets. Existing Anthropic key path (Keychain) is unchanged. | none |
| Build artifacts | `Jarvis.xcodeproj/project.pbxproj` and `project.yml` will gain entries for the new `VoiceLog` package and new source files; this is normal additive change, not a stale artifact. | regenerate via `xcodegen` after editing `project.yml` |

**The canonical question** (after every file in the repo is updated, what runtime systems still have the old string cached, stored, or registered?): nothing. Phase 10 is purely additive.

## Common Pitfalls

### Pitfall 1: DevOverlay subscriber appears "wired" but is a no-op drain
**What goes wrong:** Reading `installAgent` you'd think the broadcaster's `.devOverlay` priority subscription is delivering events to the overlay; in fact the subscriber Task at `App/AppDelegate.swift:1325-1330` just iterates the stream and does nothing.
**Why it happens:** Plan 04-05 wired the broadcaster + emitter type, but the App-side instantiation was deferred to "a follow-on plan" that never landed.
**How to avoid (this plan):** Plan 10-03 starts with the read-only investigation note (D-15) that says exactly this; the surgical fix is to (a) instantiate `DevSnapshotEmitter`, (b) replace the no-op drain with `await emitter.apply(event)`, (c) call `bridge.attach(channel: emitter.output)` when `DevOverlayWindow` is constructed.
**Warning signs:** DevOverlay opens but every field shows zero; `cache_creation_input_tokens` etc. never populate even though the tactical `streamTruncatedFinal` fix in `d8983af` is now landed.

### Pitfall 2: Tests-green ≠ production-works
**What goes wrong:** Unit tests pass, integration tests pass, but the user launches the app and the surface is dead.
**Why it happens:** Test fixtures stub the production wire, so the wire is never exercised; or production wire short-circuits on a missing dependency without surfacing it (Phase 9 fix `b92d062` is exactly this — `installVoice` short-circuited on missing models in Debug, leaving `outboundBatcher` nil).
**How to avoid:** D-26..D-28 — every plan's `SUMMARY.md` ends with a `## Live Verification` section containing relaunch command, observed log lines (timestamped), and explicit human-observed-audibly/visibly evidence per AC.
**Warning signs:** Plan SUMMARY.md is missing the Live Verification section. `/gsd-verify-phase 10` MUST reject these per D-27.

### Pitfall 3: TCC silent fail when verification follows a prior `tccutil reset`
**What goes wrong:** The `tccutil reset Microphone com.koftwentytwo.jarvis` step in D-28 is supposed to force a fresh OS prompt; if the explicit `requestAccess` call isn't reached on the production path, the user clicks "Allow" on no prompt and the test "passes" with stale-but-allowed status.
**Why it happens:** macOS TCC is OS-driven; prompts only fire on the OS's terms. Without `AVCaptureDevice.requestAccess(for:)` the prompt is silent.
**How to avoid:** Verify the explicit `requestAccess` is reached. `b92d062` added these in `installVoice`/`installVision`; Phase 10 plans that touch mic/camera reuse them — don't add new gate-skipping paths.
**Warning signs:** No `tccd` log line during the relaunch window after `tccutil reset`.

### Pitfall 4: Cache-eligibility breakage when preamble grows the system prompt
**What goes wrong:** Anthropic's `extended-cache-ttl-2025-04-11` requires ≥1024 tokens in the cached block (~4096 chars per `CacheHints.swift:50`). The current literal `"You are Jarvis, a personal macOS assistant."` (`AppDelegate.swift:1242`, ~50 chars) is BELOW the threshold so `eligibleForSystemPrompt` returns nil and no cache marker is sent — which is correct.
**Why it happens:** Adding a preamble could accidentally push the prompt JUST past 4096 chars, suddenly enabling cache marker emission. If the marker is emitted but the prompt content varies per-turn (e.g., presence enrichment text), the cache invalidates every turn and we PAY the cache-creation cost without a cache-read benefit.
**How to avoid:** D-12 + D-13 — preamble is a SINGLE LOCKED CONSTANT, composed BEFORE presence enrichment. Either (a) keep total preamble + base under 4096 chars (no cache marker, no cost), or (b) make sure ONLY the preamble portion is the cache-eligible block and presence enrichment lives in a separate, non-cached block. Verify behavior via `CacheHintsEligibilityTests`. The simplest path is (a): keep the preamble small (<2 KB).
**Warning signs:** DevOverlay shows `cache_creation_input_tokens` consistently > 0 with `cache_read_input_tokens == 0` across same-session turns.

### Pitfall 5: Voice Log audioLevelRMS flooding actor hops
**What goes wrong:** Producer-side throttling skipped → publisher actor receives 16 kHz / 30 Hz sample updates, each requiring an actor hop. Actor mailbox bloats, subscriber stream lags transcripts.
**Why it happens:** Easy to throttle at the subscriber side ("UI doesn't need to render that fast"), but the actor hop happens on every PRODUCE call regardless of whether the subscriber renders.
**How to avoid:** D-24 — rate-limit at the publish site. Producer holds a `lastEmittedAt: Date` and skips if `Date().timeIntervalSince(lastEmittedAt) < 1.0`. The publisher never sees the dropped samples.
**Warning signs:** Voice Log entries appear delayed under speech load; `vm.entries.count` grows fastest on `audioLevelRMS` rather than transcript events.

### Pitfall 6: Salvaging stash@{0} files wholesale without verification
**What goes wrong:** `git stash apply` would re-introduce 1500 lines of partial work, including the `AppDelegate.swift` edits that were partial pieces of three different parallel agents' attempts.
**Why it happens:** Speed temptation; the stash has correct-shaped scaffolding for `VoiceLog/`.
**How to avoid:** D-05 — review file-by-file via `git show 101a2aa1:<path>` (the third parent of `stash@{0}` holds untracked files). Salvage source code where it aligns with D-20..D-25; discard `AppDelegate.swift` / `MenuBar/MenuBarContextMenu.swift` / `project.pbxproj` / `project.yml` edits and re-author them in fresh commits per the locked decisions. Drop the stash only AFTER plan 10-05 is committed (D-06).
**Warning signs:** Stashed `VoiceLogPublisher.swift` capacity defaults to 1000, not the D-21 value of 2000 — direct evidence of why wholesale apply is wrong.

## Code Examples

> All examples cite files already in this repo. Plans should adapt these patterns rather than search ecosystem docs.

### Example 1: CoreAudio device enumeration (SELF-01 reference)

```swift
// Source pattern: argmax-oss-swift WhisperKit AudioProcessor.swift:818-879
// (in-tree at build-devoverlay/SourcePackages/checkouts/...)
import CoreAudio
import AudioToolbox

enum CoreAudioIntrospection {
    static func snapshotDevices() throws -> [AudioDeviceEntry] {
        // 1. Get list of all device IDs
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size
        )
        guard status == noErr else { throw CoreAudioError.size(status) }
        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        var deviceIDs = [AudioDeviceID](repeating: 0, count: count)
        status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceIDs
        )
        guard status == noErr else { throw CoreAudioError.fetch(status) }

        // 2. For each device, query name (kAudioObjectPropertyName), UID
        //    (kAudioDevicePropertyDeviceUID), input vs output streams
        //    (kAudioDevicePropertyStreams in kAudioObjectPropertyScopeInput vs Output),
        //    nominal sample rate, channel count.
        // 3. Resolve the default input/output via kAudioHardwarePropertyDefaultInputDevice
        //    / DefaultOutputDevice and flag isDefault accordingly.
        // 4. isActive = sampleRate > 0 && channelCount > 0 (heuristic; aligns
        //    with what AudioGraph's probed format reports)

        // (Full impl ~80 LOC; pattern verbatim from the WhisperKit source
        //  cited above. Plan 10-01 ships the full version.)
        return /* assembled entries */ []
    }
}

enum CoreAudioError: Error {
    case size(OSStatus)
    case fetch(OSStatus)
}
```

### Example 2: AVCaptureDevice enumeration (SELF-04 reference)

```swift
// macOS 26 Tahoe — AVCaptureDevice.DiscoverySession is the standard.
// .external covers USB cams; .builtInWideAngleCamera covers FaceTime; .continuityCamera covers iPhone-as-webcam.
import AVFoundation

enum CameraIntrospection {
    static func snapshotDevices() -> [CameraDeviceEntry] {
        let session = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera],
            mediaType: .video,
            position: .unspecified
        )
        return session.devices.map { dev in
            CameraDeviceEntry(
                localizedName: dev.localizedName,
                uniqueID: dev.uniqueID,
                isConnected: dev.isConnected,
                position: positionString(dev.position)
            )
        }
    }
    private static func positionString(_ p: AVCaptureDevice.Position) -> String {
        switch p {
        case .front: return "front"
        case .back:  return "back"
        case .unspecified: return "external"
        @unknown default: return "unknown"
        }
    }
}
```

**TCC note:** `AVCaptureDevice.DiscoverySession.devices` enumeration does NOT trigger the camera TCC prompt — it's read-only. The prompt only fires on `AVCaptureDevice.requestAccess(for: .video)` (already wired in `installVision` per `b92d062`). Calling `list_camera_devices` before TCC grant returns the device list with `isConnected: true` but the actual capture would fail. This is the right shape — the model gets to know the camera exists even before TCC is granted.

### Example 3: get_active_audio_route via AudioGraphOwner

```swift
// Source: packages/Voice/Sources/Voice/AudioGraph/AudioGraphOwner.swift:36-57
public actor AudioGraphRouteAdapter: ActiveAudioRouteDispatching {
    private let owner: AudioGraphOwner
    public init(owner: AudioGraphOwner) { self.owner = owner }

    public func getActiveAudioRoute() async throws -> ActiveAudioRoute? {
        guard let variant = await owner.currentVariant else { return nil }
        // The probed format lives on AudioGraph behind the owner — Plan 10-01
        // adds a small `await owner.activeRouteSnapshot()` accessor that
        // returns (inputUID, outputUID, sampleRate, channels). Use existing
        // probe log line at AudioGraph.swift (search for "probed format").
        let snap = await owner.activeRouteSnapshot()
        return ActiveAudioRoute(
            inputDeviceUID: snap.inputUID,
            inputDeviceName: snap.inputName,
            outputDeviceUID: snap.outputUID,
            outputDeviceName: snap.outputName,
            sampleRate: snap.sampleRate,
            channels: snap.channels,
            variant: String(describing: variant)   // "aecOn" | "aecOff"
        )
    }
}
```

(Plan 10-01 adds `activeRouteSnapshot()` to `AudioGraphOwner` if it doesn't exist — small actor method, returns a `Sendable` struct. Audit the existing logging line for the exact field names it reports.)

### Example 4: get_self_state composition

```swift
public struct SelfStateAdapter: SelfStateDispatching {
    private let bundle: Bundle
    private let launchInstant: Date
    private let providerIdentity: @Sendable () async -> (name: String, model: String)
    private let voiceState: @Sendable () async -> String?
    private let ttsT ier: @Sendable () async -> String
    private let sttBackend: @Sendable () async -> String
    private let wakeWordMuted: @Sendable () async -> Bool

    public func getSelfState() async -> SelfState {
        let info = bundle.infoDictionary ?? [:]
        let appName    = (info["CFBundleName"] as? String) ?? "Jarvis"
        let appVersion = (info["CFBundleShortVersionString"] as? String) ?? "0.0.0"
        let buildMode: String = {
            #if DEBUG
            return "debug"
            #else
            return "release"
            #endif
        }()
        let pid = ProcessInfo.processInfo.processIdentifier
        let uptime = Int(Date().timeIntervalSince(launchInstant))   // app uptime, not host
        let provider = await providerIdentity()
        return SelfState(
            appName: appName,
            appVersion: appVersion,
            buildMode: buildMode,
            pid: Int(pid),
            uptimeSeconds: uptime,
            llmProvider: provider.name,
            llmModel: provider.model,
            ttsTier: await ttsTier(),
            sttBackend: await sttBackend(),
            wakeWordMuted: await wakeWordMuted(),
            voiceLoopState: await voiceState() ?? "idle"
        )
    }
}
```

**Main-actor hop note:** `VoiceController.state` is `public private(set) var state: VoiceState` on a `public actor` (lines 44-45). Reading from a non-isolated context requires `await voiceController.state`. The `SelfStateAdapter` accepts a `@Sendable () async -> String?` closure to keep the adapter free of `Voice` import; AppDelegate constructs the closure with the actor reference at install time. This avoids a deadlock if the adapter is invoked from the agent loop while VoiceController is mid-transition (the hop awaits naturally).

### Example 5: System prompt preamble emit point

```swift
// In packages/AgentCore/Sources/AgentCore/ContextBuilder.swift  (MODIFIED)

public struct ContextBuilder { /* existing */ }

extension ContextBuilder {
    /// Locked self-aware preamble — D-13 single string constant.
    /// Total length: keep < 2 KB to stay well below the 4096-char cache
    /// boundary (Pitfall #4). Do NOT enumerate the tool list (D-14) — the
    /// Anthropic API tools array already provides it.
    public static let selfAwarePreamble: String = """
    You are Jarvis, an always-on macOS assistant running as a Swift app on \
    the user's Mac. You have voice input via the user's microphone, voice \
    output via the user's speakers, and a camera you can use to see when \
    asked. You expose a set of MCP tools for introspection — always prefer \
    calling those tools (list_audio_devices, get_active_audio_route, \
    get_self_state, list_camera_devices, get_time, get_clipboard, \
    run_applescript) over giving the user generic instructions like \
    "open System Settings" or "I don't have access to your hardware." \
    You are not a text-only assistant.
    """

    /// Compose the full system prompt for one turn.
    /// Order matters: preamble (cache-eligible identity) FIRST, then
    /// per-turn enrichments (presence, memory hydration). Plan 10-02 calls
    /// this from AppDelegate's orchestrator constructor instead of the
    /// hardcoded literal at AppDelegate.swift:1242.
    public static func systemPrompt(for turn: TurnContext) -> String {
        var s = selfAwarePreamble
        if let presence = turn.presenceText { s += "\n\n" + presence }
        if let memory = turn.memoryHydration { s += "\n\n" + memory }
        return s
    }
}
```

(`AppDelegate.swift:1242` becomes `systemPrompt: ContextBuilder.systemPrompt(for: ...)` — but check the actual `AgentOrchestrator.init` shape; the orchestrator currently takes `systemPrompt: String` directly. Plan 10-02 may need to thread per-turn context through differently; verify against `packages/AgentCore/Sources/AgentOrchestrator/AgentOrchestrator.swift:38-108`.)

### Example 6: DevSnapshotEmitter wiring (DIAG-02 fix)

```swift
// In App/AppDelegate.swift, inside installAgent(), AFTER orchestrator + broadcaster:
// REPLACING the current no-op drain at lines 1325-1330.

let devSnapshotEmitter = DevSnapshotEmitter(
    provider: "anthropic",          // TODO: plumb from providerFactory
    modelId: "claude-opus-4-7",
    capacity: 32                    // AGENT-10 four-seam compliance
)
self.devSnapshotEmitter = devSnapshotEmitter

let devSub = await broadcaster.subscribe(priority: .devOverlay, capacity: 32)
devOverlaySubscriberTask = Task {
    for await event in devSub.stream {
        if Task.isCancelled { break }
        await devSnapshotEmitter.apply(event)        // <— THE FIX
    }
}

// Then, in toggleDevOverlay() at AppDelegate.swift:2022-2027:
private func toggleDevOverlay() {
    if devOverlayWindow == nil {
        let window = DevOverlayWindow()
        let bridge = DevOverlayBridge(viewModel: window.viewModel)
        if let emitter = devSnapshotEmitter {
            Task { @MainActor in
                bridge.attach(channel: await emitter.output)   // emitter.output is `let`
            }
        }
        self.devOverlayWindow = window
        self.devOverlayBridge = bridge                          // hold strongly
    }
    devOverlayWindow?.toggle()
}
```

**Bridge lifecycle:** the bridge MUST be retained on `self.devOverlayBridge` (new ivar) so its subscriber task isn't deallocated immediately. `DevOverlayBridge` already holds `viewModel` weakly (line 19) — that's correct; the holding direction is bridge→AppDelegate→bridge.

### Example 7: Audio loopback diagnostic

```swift
// Plan 10-04 — in AppDelegate, audioLoopbackAction closure:

private func audioLoopbackAction() {
    Task.detached { [weak self] in
        guard let self else { return }
        guard let owner = await self.audioGraphOwner else { return }
        guard let sub = await owner.subscribe(capacityFrames: 16_000 * 3) else {
            // Owner not open — TCC denied or graph not built
            return
        }
        // Capture 2 seconds (16 kHz mono = 32 000 samples)
        let target = 16_000 * 2
        var collected = [Float]()
        collected.reserveCapacity(target)
        let deadline = ContinuousClock.now + .seconds(2)
        var scratch = [Float](repeating: 0, count: 1280)
        while ContinuousClock.now < deadline && collected.count < target {
            let n = scratch.withUnsafeMutableBufferPointer { sub.ringBuffer.readMono16k(into: $0) }
            if n > 0 {
                collected.append(contentsOf: scratch.prefix(n))
            } else {
                try? await Task.sleep(for: .milliseconds(10))
            }
        }
        // Play back through AVAudioEngine output route. AVAudioPlayerNode +
        // a single AVAudioPCMBuffer of the collected samples is enough; do NOT
        // touch AudioGraphOwner's engine — use a separate AVAudioEngine for
        // playback only (no input mixer, no VPIO).
        await Self.playMono16k(collected)
    }
}

private static func playMono16k(_ samples: [Float]) async {
    let engine = AVAudioEngine()
    let player = AVAudioPlayerNode()
    let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
    engine.attach(player)
    engine.connect(player, to: engine.mainMixerNode, format: format)
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))!
    buffer.frameLength = AVAudioFrameCount(samples.count)
    samples.withUnsafeBufferPointer { src in
        buffer.floatChannelData!.pointee.update(from: src.baseAddress!, count: samples.count)
    }
    do { try engine.start() } catch { return }
    await withCheckedContinuation { cont in
        player.scheduleBuffer(buffer, completionHandler: { cont.resume() })
        player.play()
    }
    engine.stop()
}
```

### Example 8: TTS playback diagnostic

```swift
// Plan 10-04 — in AppDelegate, ttsPlaybackAction closure:

private func ttsPlaybackAction() {
    Task.detached { [weak self] in
        guard let self else { return }
        guard let engine = await self.ttsEngine else { return }
        do {
            try await engine.synthesize(
                "Jarvis is online",
                tier: .tier1,                               // D-19
                voice: AVSpeechSynthesisVoice.currentLanguageCode()
            )
        } catch {
            // Cancellation is expected if the user clicks again mid-speech
            // (TTSEngineActor cancels in-flight; that's fine for a diagnostic).
        }
    }
}
```

`TTSEngineActor.synthesize` already yields `.started` / `.firstAudio(at:)` / `.finished` on its event stream (lines 109-119) and self-cancels on subsequent calls (lines 92-97). The diagnostic does not need to await events; awaiting the throwing call is enough.

### Example 9: Voice Log subscriber attach point — wakeWordFired

```swift
// Plan 10-05 — App/Voice/VoiceLogAdapters.swift (NEW file).
// The adapter spawns a small Task that drains WakeWordDAG.wakeWordStream
// AND publishes to VoiceLogPublisher. Crucially: this is ADDITIVE — the
// existing VoiceController.spawnWakeWordConsumer at VoiceController.swift:274
// remains; the adapter is a parallel reader on the same AsyncStream.
//
// EXCEPT: AsyncStream is a SINGLE-CONSUMER protocol — multiple `for await`
// loops on the same stream produce undefined ordering. The correct fix is
// either (a) wrap the original stream in an AsyncStream broadcaster (more
// code), OR (b) emit to the publisher from INSIDE the existing consumer
// at VoiceController.handleWakeWord (one-line addition). Pick (b).
//
// Plan 10-05 task: thread an `Optional<VoiceLogSink>` through VoiceController.init
// and call `await voiceLog?.post(.wakeWordFired(at: Date()))` inside
// handleWakeWord BEFORE the state switch.

extension VoiceController {
    // Production path: VoiceController gains a `voiceLog: VoiceLogSink?` ivar.
    // installVoice constructs the publisher, builds VoiceController with the
    // sink, and AppDelegate retains the publisher.
}
```

**Important:** every voice subsystem has the same single-consumer constraint. The publish callsite must be inside the existing consumer, not a parallel reader. Map of attach points (Plan 10-05 ships one diff per row):

| Event | File | Existing line / function | Phase 10 add |
|-------|------|--------------------------|--------------|
| `wakeWordFired` | `packages/Voice/Sources/Voice/VoiceController.swift:283` (`handleWakeWord`) | switch-state on event | First line of function: `await voiceLog?.post(.wakeWordFired(at: Date()))` |
| `wakeWordPaused` / `wakeWordResumed` | `packages/Voice/Sources/Voice/WakeWord/WakeWordDAG.swift:119, 126` | `pause()` / `resume()` log lines | One line under each `logger.debug` |
| `vadSpeechStart` / `vadSpeechEnd` | `packages/Voice/Sources/Voice/VoiceController.swift:521-528` (`runVADInterceptor`) | switch on `decision` cases | One line per case |
| `sttPartial` | `packages/Voice/Sources/Voice/VoiceController.swift:448` (the partials drain Task) | `for await _ in partials` (currently discards per T-06-05-03) | Replace with: `for await p in partials { await voiceLog?.post(.sttPartial(text: p.text, at: Date())) }` |
| `sttFinal` | `packages/Voice/Sources/Voice/VoiceController.swift:458` (`handleSTTFinalized`) | called at end of finalize Task | One line at top: `await voiceLog?.post(.sttFinal(text: text, at: Date()))` |
| `voiceStateTransition` | `packages/Voice/Sources/Voice/VoiceController.swift` (search for `doTransition` — actor private method) | every state change | Inside `doTransition`: `await voiceLog?.post(.voiceStateTransition(from: old, to: new))` |
| `ttsSynthesizeStart` / `Complete` / `Cancel` | `packages/Voice/Sources/Voice/TTS/TTSEngineActor.swift:91, 119` | `synthesize` enters / completes; `cancel` at line 192 | Before `eventContinuation.yield(.started)`, after `.finished`, in `cancel()` body |
| `audioLevelRMS` | `packages/Voice/Sources/Voice/Control/AudioLevelEmitter.swift:80` (32 ms windows) | RMS computed per window | Throttled (D-24): `if Date().timeIntervalSince(lastEmittedAt) >= 1.0 { post; lastEmittedAt = now }` |
| `voiceError` | `packages/Voice/Sources/Voice/VoiceController.swift:454-455` (logger.warning on STT finalize error) + WakeWord errors | logger calls today | Add `await voiceLog?.post(.voiceError(message: ..., at: Date()))` next to each logger.warning/error in the voice surface |

**T-06-05-03 reminder:** the existing `VoiceController.swift:448` line currently DISCARDS `partials` precisely because the comment says "T-06-05-03: transcript text is NEVER passed to logger or os.log." Plan 10-05 changes this to PUBLISH partials to the in-memory Voice Log — which is allowed (the rule is "no OSLog," not "no in-memory display"). The publish call must NOT log; verify the publisher implementation does not call any logging APIs on the event payload.

## State of the Art

| Old Approach | Current Approach | When Changed | Impact |
|--------------|------------------|--------------|--------|
| Stdio-framed MCP helpers for every tool | In-process tools via `InProcessToolRegistry` for read-only state queries | Track D-2 (Phase 7), commit `707c45b` | Self-knowledge tools register without per-helper bundle/codesign overhead |
| WhisperKit standalone package | `argmaxinc/argmax-oss-swift v0.18.0` monorepo (WhisperKit + TTSKit + SpeakerKit) | RESEARCH-DELTAS | Out of scope for Phase 10; relevant only for STT fallback feature flag |
| `SFSpeechRecognizer` for STT | Apple `SpeechAnalyzer` / `SpeechTranscriber` (macOS 26 Tahoe) | macOS 26 release, ~April 2026 | Out of scope for Phase 10; STT primary already chosen |
| Hand-rolled MCP JSON-RPC framing | `modelcontextprotocol/swift-sdk v0.12.0` | RESEARCH-DELTAS | Phase 5 wiring; Phase 10 inherits |
| BRIEF.md "Sonnet only" framing | Multi-provider (`AnthropicProvider` + `OllamaProvider`) | Phase 4 | Self-state tool reports active provider per-turn |
| `streamTruncatedFinal` due to missing `stream: true` | Explicit `"stream": true` in body + correct beta header | commit `d8983af` (2026-05-06) | Without this, DIAG-02 has no events to populate — verify `d8983af` is in HEAD before Plan 10-03 |
| Implicit `Info.plist`-only TCC | Explicit `AVCaptureDevice.requestAccess` calls in `installVoice` / `installVision` | commit `b92d062` (2026-05-06) | D-28 reset/relaunch protocol depends on this |

**Deprecated/outdated (do NOT pull from older docs):**
- ROADMAP wording about Voice Log persisting across launches (superseded by SPEC.md D-21).
- `BRIEF.md` "Sonnet only" framing (superseded by multi-provider).
- Old DevOverlay docstrings calling the subscriber wiring "deferred" — that deferral is what Plan 10-03 closes.

## Assumptions Log

| # | Claim | Section | Risk if Wrong |
|---|-------|---------|---------------|
| A1 | `AudioGraphOwner` exposes a synchronous-readable view of the active route's input/output device UID + probed sample rate. | Section 1 (SELF-02) | If only the `currentVariant` (.aecOn/.aecOff) is exposed and the route fields live deeper in `AudioGraph`, Plan 10-01 must add an `activeRouteSnapshot()` actor method (small additive change). Verified-true: `currentVariant` is exposed at line 37; the probed format log line referenced in SPEC AC-02 lives in `AudioGraph.swift` (search for "probed format") — Plan 10-01 can choose to expose it via a new accessor. **[ASSUMED]** |
| A2 | `AVCaptureDevice.DiscoverySession` enumeration does NOT trigger TCC prompt on macOS 26 Tahoe (only `requestAccess` does). | Section 2 (SELF-04) | If discovery DOES prompt, `list_camera_devices` would force TCC dialog on every introspection — wrong UX. **Apple docs state discovery is metadata-only**; verify by running the tool before granting camera TCC during plan 10-01 verification. [CITED: developer.apple.com/documentation/avfoundation/avcapturedevice/discoverysession] |
| A3 | `Bundle.main.infoDictionary["CFBundleShortVersionString"]` and `["CFBundleName"]` are populated in BOTH Debug and Release on this project's `project.yml` config. | Section 3 (SELF-03) | If Debug builds skip these keys, `get_self_state` returns "0.0.0" / "Jarvis" defaults — visible degradation but not blocking. Verify by `defaults read` of the built `Info.plist` during plan 10-01 verification. **[ASSUMED]** |
| A4 | Total preamble (D-13) + base prompt + presence enrichment stays <4096 chars under typical conditions, OR the cache marker placement is structurally correct (preamble cached, presence not). | Section 4 (SELF-05/06) | Cache marker on a varying prompt invalidates the cache every turn — pays cost without benefit. Mitigation: keep the preamble itself under 2 KB (reachable per Example 5) and verify via `CacheHintsEligibilityTests`. **[CITED: CacheHints.swift:32-46 in this repo]** |
| A5 | The DevOverlay subscriber bug is purely "emitter never instantiated + drain is no-op" and not also a problem in `OrchestratorEventBroadcaster.start()` or `subscribe(priority:capacity:)`. | Section 5 (DIAG-02) | If broadcaster itself doesn't deliver `.devOverlay` priority events, the surgical fix won't close AC-08. Mitigation: D-15 read-only investigation step explicitly enumerates broadcaster, subscription, drain, emitter, bridge, view-model — investigation MUST verify each link before coding. **[VERIFIED via source read: broadcaster.subscribe + .devOverlay priority both present in OrchestratorEventBroadcaster; the gap is in the App-side wiring at AppDelegate.swift:1325-1330 and toggleDevOverlay at 2020-2027]** |
| A6 | `AsyncStream` from `AVSpeechSynthesizer` (via `TTSEngineActor.tier1`) reliably yields `.finished` even when `voice` lookup falls back from identifier to language code. | Section 9 (DIAG-04) | If lookup fails entirely, the synthesize call may throw; for a diagnostic that's acceptable (caller swallows the error). Verify by running with both a known-good identifier ("com.apple.voice.compact.en-US.Samantha") and a bad one. **[ASSUMED]** |
| A7 | `tccutil reset Microphone com.koftwentytwo.jarvis` actually clears the mic TCC entry (vs. requiring just bundle ID variants like `com.koftwentytwo.Jarvis`). | Section 11 (D-28) | Bundle ID case sensitivity differs by macOS version. If reset doesn't fire, the relaunch verification doesn't prove `requestAccess` is reached. Mitigation: each plan's verification step records the EXACT command used; if the prompt didn't appear, fall back to `tccutil reset Microphone` (no bundle filter) which resets all apps. **[VERIFIED via b92d062 commit message — same command used during the live launch debug session that produced the phase]** |
| A8 | The stashed `VoiceLogPublisher.swift` actor implementation matches D-20/D-24 enough to be salvageable (capacity arg differs but shape is correct). | Section 10 + Pitfall #6 | If the salvaged file uses `NSLock` or non-actor concurrency, it's a Swift 6 strict concurrency violation. **[VERIFIED via stash inspection above: it IS an actor, uses `nonisolated let stream: AsyncStream<VoiceLogEntry>` + internal continuation. Capacity default is 1000; bump to 2000 per D-21.]** |
| A9 | Replacing the no-op `for await _ in partials { /* discarded */ }` at `VoiceController.swift:448` with a publishing loop does NOT change observable VoiceController behavior. | Section 7 (DIAG-01 sttPartial attach) | If the discard is load-bearing for some race condition, replacing it could regress. **[VERIFIED via source read: the discard is purely a no-op iteration kept to satisfy AsyncSequence contract; the comment at line 446 confirms transcripts MUST NOT log but does not say MUST discard]**. Plan 10-05 should still verify regression behavior via `VoiceControllerTests`. |

**Net assessment:** A4, A7, A9 are highest-impact assumptions. A4 and A9 are mitigated by existing tests (`CacheHintsEligibilityTests`, `VoiceControllerTests`); A7 is mitigated by the phase's own live-verification step. None block planning.

## Open Questions

1. **Should `get_self_state` include presence enrichment summary fields?**
   - What we know: SPEC says "model, voice config, feature flags, build version" — no presence.
   - What's unclear: the model might benefit from knowing what the user is doing (idle/typing) to answer "what am I doing?" — but presence is already in the system prompt via 07-06.
   - Recommendation: NO. Keep `get_self_state` to runtime self-state. Presence is a separate axis and adding it would duplicate prompt content into a tool-call result.

2. **Should the audio loopback diagnostic visualize the captured RMS in the menu item title?**
   - What we know: D-claude-discretion allows headless or status overlay.
   - What's unclear: a "Recording 2.0/2.0s" countdown in the menu title is cheap.
   - Recommendation: include a transient title update on the menu item ("Audio Loopback Test (recording…)" → "Audio Loopback Test (playing back…)") since `NSMenuItem.title` is mutable on `@MainActor`. Skip if it requires new HUD surface.

3. **What's the TCC-reset bundle ID exactly?**
   - What we know: `b92d062` commit message presumably references the exact ID.
   - What's unclear: `com.koftwentytwo.jarvis` vs `com.koftwentytwo.Jarvis` (case).
   - Recommendation: each plan's verification reads the actual bundle ID from `Info.plist` of the built app and uses that string verbatim in the `tccutil` command.

4. **Does `AudioGraphOwner` already expose the active input/output device UIDs, or does Plan 10-01 add a new accessor?**
   - What we know: `currentVariant` is exposed; the probed format is logged but not exposed.
   - What's unclear: Plan 10-01 may need to add `activeRouteSnapshot() -> ActiveRouteSnapshot` (small actor method).
   - Recommendation: Plan 10-01 adds the accessor as a small additive change; it's a 5-line method that returns existing internal state.

## Environment Availability

> Phase 10 is purely a Swift app + macOS framework phase — no new external CLIs, runtimes, or services beyond what already powers the project.

| Dependency | Required By | Available | Version | Fallback |
|------------|------------|-----------|---------|----------|
| macOS 14+ (target floor) | All AppKit + Observation usage | ✓ | macOS 26 Tahoe (host) | — |
| CoreAudio | `list_audio_devices` | ✓ | system framework | — |
| AVFoundation | `list_camera_devices`, audio loopback, TTS playback | ✓ | system framework | — |
| Anthropic API key | System prompt cache verification | ✓ | Keychain (existing) | Skip cache test if absent |
| Built `Jarvis.app` artifact | Live-launch verification (D-26) | ✓ (built from `b92d062`) | Debug build | `bash scripts/check-app-builds.sh` rebuilds |
| `tccutil` | TCC reset (D-28) | ✓ | macOS system | Manual System Settings reset |
| `system_profiler` | SPEC AC-01 + AC-04 cross-validation | ✓ | macOS system | — |
| `xcodegen` | Regenerating `project.pbxproj` after `project.yml` edits | ✓ (assumed installed; check via `which xcodegen`) | — | Hand-edit `project.pbxproj` — discouraged |

**Missing dependencies with no fallback:** none.
**Missing dependencies with fallback:** none.

## Validation Architecture

> Required because `.planning/config.json` has `workflow.nyquist_validation: true`.

### Test Framework

| Property | Value |
|----------|-------|
| Framework | Swift Testing (`@Test` macros) for SPM packages; XCTest for App target |
| Config file | Per-package `Package.swift` declares `.testTarget`; App target uses Xcode test scheme via `scripts/check-app-builds.sh` |
| Quick run command | `swift test --package-path packages/<Pkg> --filter <Suite>/<test>` (sub-second) |
| Full suite command | All package tests: looped `swift test --package-path packages/{AgentCore,Voice,Vision,Memory,MCP,DevOverlay,Bus,Config,Logging,Replay,Harness,Keychain,Shell}`. App target: `bash scripts/check-app-builds.sh` |

### Phase Requirements → Test Map

| Req ID | Behavior | Test Type | Automated Command | File Exists? |
|--------|----------|-----------|-------------------|--------------|
| SELF-01 | `list_audio_devices` returns ≥1 input + ≥1 output, fields populated | unit | `swift test --package-path packages/MCP --filter ListAudioDevicesToolTests` | ❌ Wave 0 |
| SELF-01 | Tool registers in MCPRuntime; `requiresConfirmation: false` set | unit | `swift test --package-path packages/MCP --filter MCPRuntimeWiringTests/registersFourSelfKnowledgeTools` | ❌ Wave 0 (extend existing) |
| SELF-01 | Cross-validates with `system_profiler SPAudioDataType` on host | live-launch | manual: relaunch + invoke tool via DevOverlay tool-call inspector + diff vs `system_profiler` | ❌ Wave 0 (script optional) |
| SELF-02 | `get_active_audio_route` returns non-nil while voice loop active | integration | `swift test --package-path packages/Voice --filter ActiveAudioRouteAdapterTests` (uses test seam on AudioGraphOwner) | ❌ Wave 0 |
| SELF-02 | Result matches `AudioGraph: probed format sampleRate=X channels=Y` log | live-launch | manual relaunch — observe log line, call tool, diff | — |
| SELF-03 | `get_self_state` returns populated struct (app_version, pid, uptime, llm_model, voice_loop_state) | unit | `swift test --package-path packages/MCP --filter GetSelfStateToolTests` | ❌ Wave 0 |
| SELF-03 | Cross-checks against `Bundle.main.infoDictionary` + active `LaunchSnapshot` | unit | same suite, fixture-driven | ❌ Wave 0 |
| SELF-04 | `list_camera_devices` returns built-in FaceTime entry | unit + live-launch | unit: `swift test --filter ListCameraDevicesToolTests`; live: relaunch, invoke, diff `system_profiler SPCameraDataType` | ❌ Wave 0 |
| SELF-05 | After preamble change, "what mic are you using?" produces `get_active_audio_route` tool call | live-launch | manual: relaunch app, ask via voice/text, observe DevOverlay last-5 tool-calls list shows `get_active_audio_route` (depends on Plan 10-03) | — |
| SELF-05 | Asking "are you a text-only assistant?" produces denial | live-launch | manual relaunch + log capture | — |
| SELF-06 | Preamble doesn't push system prompt over cache boundary | unit | `swift test --package-path packages/AgentCore --filter CacheHintsEligibilityTests/preambleDoesNotEnableCacheUnintentionally` | ❌ Wave 0 (extend existing `CacheHintsEligibilityTests`) |
| DIAG-01 | Voice Log opens via menu item; first entry appears within 1s of "Hey Jarvis" | live-launch | relaunch + utterance + screenshot of log entries with timestamps | — |
| DIAG-01 | Publisher caps at 2000; FIFO eviction on overflow | unit | `swift test --package-path packages/VoiceLog --filter VoiceLogPublisherTests/capsAt2000WithFIFO` | ❌ Wave 0 (salvage from stash + extend) |
| DIAG-01 | RMS rate-limited ≤1 Hz at publisher side | unit | `VoiceLogPublisherTests/audioLevelRMSRateLimited` | ❌ Wave 0 |
| DIAG-01 | No transcript text passes through `Logger` / `os.log` | grep gate | `bash scripts/check-no-transcript-oslog.sh` (existing T-06-05-03 gate) | ✓ existing |
| DIAG-02 | DevOverlay populates Provider/Model/tokens within 100ms of `.turnEnded` | integration + live-launch | unit: `DevSnapshotEmitterTests/applyTurnEndedFlushesAccumulator` (existing); live: relaunch + send turn calling `get_time` + observe DevOverlay populated | ✓ unit existing; ❌ integration end-to-end test (salvage from stash `DevOverlayBroadcasterIntegrationTests.swift`) |
| DIAG-03 | Audio loopback records 2s + plays back audibly | live-launch | manual: tccutil reset Microphone com.koftwentytwo.jarvis; relaunch; click menu item; speak; observe playback | — |
| DIAG-04 | TTS Playback diagnostic speaks "Jarvis is online" within 2s | live-launch | manual: click menu item; observe audible phrase + log line | — |

### Sampling Rate

- **Per task commit:** `swift test --package-path packages/<TouchedPkg>` (≤30 s typical)
- **Per wave merge / per plan boundary:** `bash scripts/check-app-builds.sh` + all 18 boundary gates green + Live Verification section in `SUMMARY.md` (D-26 mandatory)
- **Phase gate (`/gsd-verify-phase 10`):** All five plan SUMMARY.md files contain Live Verification with PASS evidence for their respective ACs (D-27); all 14 SPEC ACs explicitly checked; no boundary gate red

### Wave 0 Gaps

- [ ] `packages/MCP/Tests/MCPTests/ListAudioDevicesToolTests.swift` — covers SELF-01
- [ ] `packages/MCP/Tests/MCPTests/GetActiveAudioRouteToolTests.swift` — covers SELF-02
- [ ] `packages/MCP/Tests/MCPTests/GetSelfStateToolTests.swift` — covers SELF-03
- [ ] `packages/MCP/Tests/MCPTests/ListCameraDevicesToolTests.swift` — covers SELF-04
- [ ] Extend `packages/MCP/Tests/MCPTests/MCPRuntimeWiringTests.swift` to assert four new tools registered with `requiresConfirmation: false`
- [ ] Extend `packages/AgentCore/Tests/AgentCoreTests/CacheHintsEligibilityTests.swift` with `preambleDoesNotEnableCacheUnintentionally` case
- [ ] `packages/VoiceLog/Package.swift` + sources (salvage from `stash@{0}` per D-25)
- [ ] `packages/VoiceLog/Tests/VoiceLogTests/VoiceLogPublisherTests.swift` — capsAt2000WithFIFO + audioLevelRMSRateLimited (extend stashed file)
- [ ] `packages/VoiceLog/Tests/VoiceLogTests/VoiceLogViewModelTests.swift` — salvage
- [ ] Salvage `packages/DevOverlay/Tests/DevOverlayTests/DevOverlayBroadcasterIntegrationTests.swift` from stash (Plan 10-03)
- [ ] Live-launch evidence template (Section 11 below) baked into each plan's SUMMARY.md

## Live-Launch Verification Format (D-26 template)

This block is the canonical format every plan's `SUMMARY.md` must include. Copy verbatim, fill the angle brackets:

```markdown
## Live Verification (D-26 / SPEC AC-13)

### Pre-checks
- [ ] `bash scripts/check-app-builds.sh` PASS
- [ ] All 18 boundary gates green (`bash scripts/check-*.sh`)
- [ ] Targeted unit / integration tests PASS

### Reset (D-28; only when touching mic / camera / audio)
- Command: `tccutil reset Microphone com.koftwentytwo.jarvis`
- Command: `tccutil reset Camera com.koftwentytwo.jarvis`     # if camera in scope
- Effect verified: <"Allow microphone…" OS prompt observed at relaunch> (or N/A)

### Relaunch
- Command: `bash scripts/check-app-builds.sh && open build/Build/Products/Debug/Jarvis.app`
- Build artifact: `build/Build/Products/Debug/Jarvis.app` from commit `<short-sha>`

### Observed (timestamped from `log stream --predicate 'subsystem == "com.koftwentytwo.jarvis"' --style compact`)
- `<HH:MM:SS.mmm>  <subsystem.category>  <log message>`
- `<HH:MM:SS.mmm>  <subsystem.category>  <log message>`
- Human observation: <"I heard the phrase audibly within 1.5s of clicking">

### Acceptance Match
- AC-XX: PASS — <evidence>
- AC-YY: PASS — <evidence>
```

## Stash Salvage Triage (D-05 — Plan 10-03 + 10-05 inputs)

Files in `stash@{0}` (commit `bfbd37c`, 2026-05-06 partial-work-from-failed-parallel-dispatch). The stash is a merge with three parents — index, untracked, working. Use `git show 101a2aa1:<path>` to inspect untracked files (the third parent).

| File | Plan | Salvage verdict | Notes |
|------|------|----------------|-------|
| `App/AppDelegate.swift` (190-line edit) | — | **DISCARD** | Partial pieces from parallel agents; re-author cleanly per locked decisions in 10-03 + 10-05. |
| `App/MenuBar/MenuBarContextMenu.swift` (6-line edit) | 10-04 | **DISCARD; re-author** | Pattern is correct (add Diagnostics submenu) but originator lacked the locked D-17 / D-19 specs. |
| `App/Voice/VoiceLogAdapters.swift` (185 LOC, untracked) | 10-05 | **REVIEW; partial salvage likely** | If shape matches D-25 (one publish callsite per voice surface), salvage. If it tries to spawn parallel readers on `AsyncStream`, discard the parallel-reader pattern. |
| `Jarvis.xcodeproj/project.pbxproj` + `project.yml` | 10-05 | **DISCARD; regen** | Re-author after `project.yml` edits via `xcodegen`. |
| `packages/DevOverlay/Tests/DevOverlayTests/DevOverlayBroadcasterIntegrationTests.swift` (162 LOC) | 10-03 | **SALVAGE** | Integration test fixture is exactly what AC-08 needs end-to-end. |
| `packages/Vision/Tests/VisionTests/CameraButtonTCCWiringTests.swift` (90 LOC) | — | **OUT OF SCOPE** | Camera button verification is post-`b92d062` retest, not a Phase 10 requirement. Defer. |
| `packages/VoiceLog/Package.swift` (33 LOC) | 10-05 | **SALVAGE** | Standard SPM Package.swift. |
| `packages/VoiceLog/Sources/VoiceLog/VoiceLogEvent.swift` (176 LOC) | 10-05 | **SALVAGE w/ TAXONOMY DIFF** | Stashed taxonomy includes `vadSilence`, `vadSpeech`, `orchestratorSubmit`, `orchestratorTurnEnd`, `orchestratorCancelled`, `orchestratorError` which are NOT in D-22's locked list. Trim to D-22 set OR widen D-22 (locked, requires phase amendment — don't widen). Strip the orchestrator events; keep VAD `silence`/`speech` only if useful for state visibility (D-22 is "voiceStateTransition" — VAD substates don't fit cleanly; recommend trimming). |
| `packages/VoiceLog/Sources/VoiceLog/VoiceLogPublisher.swift` (92 LOC) | 10-05 | **SALVAGE w/ CAPACITY BUMP** | Actor-shaped (matches D-20). Default capacity 1000 → bump to 2000 (D-21). RMS rate-limit at producer side (D-24) is NOT in stashed file — add. |
| `packages/VoiceLog/Sources/VoiceLog/VoiceLogView.swift` (185 LOC) | 10-05 | **SALVAGE** | SwiftUI body — review for Voice Log filter UI (D-claude-discretion). |
| `packages/VoiceLog/Sources/VoiceLog/VoiceLogViewModel.swift` (84 LOC) | 10-05 | **SALVAGE w/ EVICTION CHECK** | Verify FIFO at 2000 entries (D-21). |
| `packages/VoiceLog/Sources/VoiceLog/VoiceLogWindow.swift` (78 LOC) | 10-05 | **SALVAGE** | NSWindow + NSHostingView + frameAutosaveName — matches D-23 exactly (verified above). |
| `packages/VoiceLog/Sources/VoiceLog/VoiceLogBridge.swift` (46 LOC) | 10-05 | **REVIEW** | Verify it does NOT introduce a webview content world (D-23). If it's a thin AsyncStream→@MainActor pump (mirror of `DevOverlayBridge`), salvage. |
| `packages/VoiceLog/Tests/VoiceLogTests/VoiceLogPublisherTests.swift` (91 LOC) | 10-05 | **SALVAGE w/ EXTEND** | Add capsAt2000WithFIFO + audioLevelRMSRateLimited cases. |
| `packages/VoiceLog/Tests/VoiceLogTests/VoiceLogViewModelTests.swift` (96 LOC) | 10-05 | **SALVAGE** | — |

**Drop sequence (D-06):** `git stash drop stash@{0}` ONLY after Plan 10-05 SUMMARY.md is committed. Phase 10 verifier checks for stash absence as a tidiness signal.

## Sources

### Primary (HIGH confidence — source-verified in this repo)

- `App/AppDelegate.swift:1242` — Current `systemPrompt` literal injection point.
- `App/AppDelegate.swift:1325-1330` — DIAG-02 root cause: no-op drain on `.devOverlay` subscription.
- `App/AppDelegate.swift:2020-2027` — `toggleDevOverlay()` constructs window without bridging to the unbuilt emitter.
- `App/MCP/InProcessMemoryAdapters.swift:1-56` — Track D-2 reference adapter pattern.
- `App/MCP/MCPRuntimeWiring.swift:97-119` — Tool registration site; `requiresConfirmation: true` only for `mcp-applescript`.
- `App/MenuBar/MenuBarContextMenu.swift:48-60` — `makeItem(title:action:)` closure-trampoline pattern.
- `App/Voice/VoiceOutputWiring.swift:13-25` — `TTSEngineActor` tier-1-only constructor.
- `packages/AgentCore/Sources/AgentCore/CacheHints.swift:32-56` — 4096-char cache eligibility threshold.
- `packages/AgentCore/Sources/AgentOrchestrator/DevSnapshotEmitter.swift:22-92` — Existing emitter with `apply(_:)` and bounded output channel.
- `packages/AgentCore/Sources/AgentOrchestrator/DevSnapshot.swift:20-80` — `DevSnapshot` shape.
- `packages/DevOverlay/Sources/DevOverlay/DevOverlayBridge.swift:17-52` — Channel→view-model pump (correct as-is).
- `packages/DevOverlay/Sources/DevOverlay/DevOverlayViewModel.swift:17-42` — `private(set) var snapshot` single-writer enforcement.
- `packages/DevOverlay/Sources/DevOverlay/DevOverlayWindow.swift:32-48` — `NSPanel` + `NSHostingView` template.
- `packages/MCP/Sources/MCP/InProcess/InProcessTool.swift:10-31` — `InProcessTool` protocol.
- `packages/MCP/Sources/MCP/InProcess/InProcessToolRegistry.swift:6-30` — Registry actor.
- `packages/MCP/Sources/MCP/InProcess/SearchMemoryTool.swift:25-66` — Tool schema + dispatch boilerplate.
- `packages/Voice/Sources/Voice/AudioGraph/AudioGraphOwner.swift:32-58` — `subscribe()` and `currentVariant`.
- `packages/Voice/Sources/Voice/VoiceController.swift:283-305, 380-460, 521-528` — Wake-word handler, STT session lifecycle, VAD interceptor with the only legitimate publish-callsite locations.
- `packages/Voice/Sources/Voice/TTS/TTSEngineActor.swift:91-119, 192` — `synthesize` and `cancel` flow.
- `packages/Voice/Sources/Voice/WakeWord/WakeWordDAG.swift:48, 105-129` — Stream + pause/resume log lines.
- `packages/Voice/Sources/Voice/Control/AudioLevelEmitter.swift:6-80` — RMS computation site (D-24 throttle insertion point).
- `stash@{0}` (`bfbd37c`, parent `101a2aa1` for untracked) — Inspected in-band; salvage triage table above.
- Commits `d8983af`, `cb7ee6f`, `b92d062`, `c8e37ab` — The fix sequence that produced this phase.

### Secondary (MEDIUM confidence — referenced but not freshly verified)

- `build-devoverlay/SourcePackages/checkouts/argmax-oss-swift/Sources/WhisperKit/Core/Audio/AudioProcessor.swift:818-879` — CoreAudio enumeration template (in-tree, but third-party code).
- `packages/AgentCore/Sources/AgentOrchestrator/AgentOrchestrator.swift:38, 98-108, 254` — Orchestrator init and system-prompt usage (read summary, not full body).

### Tertiary (LOW confidence — Apple framework docs, training data)

- `AVCaptureDevice.DiscoverySession` enumeration is metadata-only and does not trigger TCC prompt — Apple docs (training).
- `tccutil reset Microphone <bundle-id>` semantics on macOS 26 — operational use during `b92d062` debug session, not docs.
- `NSWindow.frameAutosaveName` round-trips frame and size to `NSUserDefaults` — Apple docs (training).
- `ProcessInfo.processInfo.systemUptime` returns host uptime since boot — Apple docs (training); for `get_self_state` use captured `Date()` at launch instead.

## Metadata

**Confidence breakdown:**
- Standard stack: HIGH — every named library/type has a citation in this repo
- Architecture (subscriber attach points, install order, broadcaster topology): HIGH — read line-by-line from current source
- Pitfalls: HIGH — pitfalls #1, #2, #3 are documented in `.continue-here.md`; #4-#6 verified via source/spec
- DIAG-02 root cause analysis: HIGH — confirmed via source: emitter exists but unwired; broadcaster subscription is no-op drain
- Stash salvage triage: HIGH — files inspected via `git show`; recommendations align with D-22, D-21, D-23
- Validation Architecture (Nyquist): MEDIUM — gap list is right; Wave 0 work is straightforward; live-launch sample sizes are observation-based (1 utterance, 1 click), not statistically sampled

**Research date:** 2026-05-06
**Valid until:** 2026-05-13 (the dependent surfaces — AudioGraphOwner, TTSEngineActor, DevSnapshotEmitter, MCPRuntimeWiring — are stable and unlikely to change inside the phase window; Anthropic's `extended-cache-ttl-2025-04-11` beta header gating is fast-moving but irrelevant to Phase 10 since the preamble stays well under the threshold)
