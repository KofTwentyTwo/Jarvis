# Phase 10: Self-Awareness & Live Diagnostics — Pattern Map

**Mapped:** 2026-05-06
**Files analyzed:** 24 (4 new tools, 4 new tool adapters, 1 prompt adapter, 1 menu modification, 6 VoiceLog files (salvage), 1 voice-log adapter file, 5 Wave-0 test files, 2 modified-only files)
**Analogs found:** 24 / 24 (every new file has a near-identical analog already in repo)

**Plan order (locked, serial — D-01/D-02):**
1. `10-01` MCP self-knowledge tools (SELF-01..04)
2. `10-02` System prompt preamble (SELF-05/06)
3. `10-03` DevOverlay subscriber fix (DIAG-02)
4. `10-04` Audio loopback + TTS playback diagnostics (DIAG-03/04)
5. `10-05` Voice Log window (DIAG-01)

---

## File Classification

| Plan | File | Status | Role | Data Flow | Closest Analog | Match Quality |
|------|------|--------|------|-----------|----------------|---------------|
| 10-01 | `packages/MCP/Sources/MCP/InProcess/ListAudioDevicesTool.swift` | NEW | MCP in-process tool | request-response | `packages/MCP/Sources/MCP/InProcess/SearchMemoryTool.swift` | exact (role + flow) |
| 10-01 | `packages/MCP/Sources/MCP/InProcess/GetActiveAudioRouteTool.swift` | NEW | MCP in-process tool | request-response | `packages/MCP/Sources/MCP/InProcess/SearchMemoryTool.swift` | exact |
| 10-01 | `packages/MCP/Sources/MCP/InProcess/GetSelfStateTool.swift` | NEW | MCP in-process tool | request-response | `packages/MCP/Sources/MCP/InProcess/SearchMemoryTool.swift` | exact |
| 10-01 | `packages/MCP/Sources/MCP/InProcess/ListCameraDevicesTool.swift` | NEW | MCP in-process tool | request-response | `packages/MCP/Sources/MCP/InProcess/SearchMemoryTool.swift` | exact |
| 10-01 | `App/MCP/InProcessSelfStateAdapters.swift` | NEW | tool adapter (App→Module bridge) | request-response | `App/MCP/InProcessMemoryAdapters.swift` | exact |
| 10-01 | `App/MCP/MCPRuntimeWiring.swift` | MODIFIED | tool registry config | request-response | (self — extend `register()` block at lines 99-119) | exact (in-place additive) |
| 10-01 | `packages/Voice/Sources/Voice/AudioGraph/AudioGraphOwner.swift` | MODIFIED | actor accessor (additive) | request-response | (self — add `activeRouteSnapshot()` accessor) | role-match (additive 5-line method) |
| 10-02 | `packages/AgentCore/Sources/AgentCore/ContextBuilder.swift` | MODIFIED | system-prompt composer | transform | (self — add `selfAwarePreamble` constant + `systemPrompt(for:)`) | role-match (additive) |
| 10-02 | `App/AppDelegate.swift` (line 1242) | MODIFIED | system-prompt emit point | request-response | (self — replace literal with `ContextBuilder.systemPrompt(...)` call) | exact (single-line surgical) |
| 10-03 | `App/AppDelegate.swift` (lines 1325-1330) | MODIFIED | broadcaster subscriber wiring | event-driven | (self — replace no-op drain with `await emitter.apply(event)`) | exact (3-line surgical) |
| 10-03 | `App/AppDelegate.swift` (lines 2020-2027 `toggleDevOverlay()`) | MODIFIED | window construction + bridge attach | event-driven | (self — add `bridge.attach(channel:)` call) | exact (4-line surgical) |
| 10-04 | `App/MenuBar/MenuBarContextMenu.swift` | MODIFIED | AppKit menu builder | event-driven (closure trampoline) | (self — extend `build()` w/ Diagnostics submenu) | exact (additive in same file) |
| 10-04 | `App/AppDelegate.swift` (audioLoopbackAction + ttsPlaybackAction) | MODIFIED | menu-action closures | request-response | `App/Voice/VoiceOutputWiring.swift` (TTS construction) + `AudioGraphOwner.subscribe()` callsites | role-match |
| 10-05 | `packages/VoiceLog/Package.swift` | NEW (salvage) | SPM package descriptor | config | other in-repo `Package.swift` files | exact |
| 10-05 | `packages/VoiceLog/Sources/VoiceLog/VoiceLogEvent.swift` | NEW (salvage w/ taxonomy diff) | event taxonomy | data model | (stash@{0} file; trim to D-22) | role-match |
| 10-05 | `packages/VoiceLog/Sources/VoiceLog/VoiceLogPublisher.swift` | NEW (salvage w/ capacity bump) | actor publisher with AsyncStream fan-out | pub-sub | `packages/Voice/Sources/Voice/AudioGraph/BufferBroadcaster.swift` | exact (role + flow) |
| 10-05 | `packages/VoiceLog/Sources/VoiceLog/VoiceLogViewModel.swift` | NEW (salvage w/ FIFO check) | SwiftUI view-model | event-driven | `packages/DevOverlay/Sources/DevOverlay/DevOverlayViewModel.swift` | exact |
| 10-05 | `packages/VoiceLog/Sources/VoiceLog/VoiceLogView.swift` | NEW (salvage) | SwiftUI body | render | `packages/DevOverlay/Sources/DevOverlay/DevOverlayView.swift` | exact |
| 10-05 | `packages/VoiceLog/Sources/VoiceLog/VoiceLogWindow.swift` | NEW (salvage) | AppKit `NSWindow` + `NSHostingView` | UI shell | `packages/DevOverlay/Sources/DevOverlay/DevOverlayWindow.swift` | exact |
| 10-05 | `packages/VoiceLog/Sources/VoiceLog/VoiceLogBridge.swift` | NEW (review for webview leak) | AsyncStream→@MainActor pump | event-driven | `packages/DevOverlay/Sources/DevOverlay/DevOverlayBridge.swift` | exact |
| 10-05 | `App/Voice/VoiceLogAdapters.swift` | NEW (review-only salvage) | voice-subsystem subscriber adapter | event-driven | (no analog — closest is in-line publish callsites pattern; mirror `OutboundBatcher` sink usage) | role-match |
| 10-05 | `packages/Voice/Sources/Voice/VoiceController.swift` (multiple sites) | MODIFIED | event publisher callsites (additive) | event-driven | (self — additive `await voiceLog?.post(...)` at existing event boundaries) | exact (in-place additive) |
| 10-05 | `packages/Voice/Sources/Voice/WakeWord/WakeWordDAG.swift` (lines 119, 126) | MODIFIED | event publisher callsite | event-driven | (self — additive 1-line under existing logger.debug) | exact |
| 10-05 | `packages/Voice/Sources/Voice/TTS/TTSEngineActor.swift` (lines 91, 119, 192) | MODIFIED | event publisher callsite | event-driven | (self — additive at start/finish/cancel) | exact |
| 10-05 | `packages/Voice/Sources/Voice/Control/AudioLevelEmitter.swift` (line 80) | MODIFIED | event publisher with rate-limit | streaming | (self — add `lastEmittedAt: Date` throttle gate) | exact |
| 10-03 | `packages/DevOverlay/Tests/DevOverlayTests/DevOverlayBroadcasterIntegrationTests.swift` | NEW (salvage from stash) | integration test | request-response | (stash@{0} file; salvage as-is) | exact |
| W0 | `packages/MCP/Tests/MCPTests/ListAudioDevicesToolTests.swift` | NEW (Wave-0 stub) | unit test | request-response | `packages/MCP/Tests/MCPTests/SearchMemoryToolTests.swift` (sibling) | exact |
| W0 | `packages/MCP/Tests/MCPTests/GetActiveAudioRouteToolTests.swift` | NEW (Wave-0 stub) | unit test | request-response | `packages/MCP/Tests/MCPTests/SearchMemoryToolTests.swift` | exact |
| W0 | `packages/MCP/Tests/MCPTests/GetSelfStateToolTests.swift` | NEW (Wave-0 stub) | unit test | request-response | `packages/MCP/Tests/MCPTests/SearchMemoryToolTests.swift` | exact |
| W0 | `packages/MCP/Tests/MCPTests/ListCameraDevicesToolTests.swift` | NEW (Wave-0 stub) | unit test | request-response | `packages/MCP/Tests/MCPTests/SearchMemoryToolTests.swift` | exact |
| W0 | `packages/MCP/Tests/MCPTests/MCPRuntimeWiringTests.swift` | EXTENDED | unit test | request-response | (self — add `registersFourSelfKnowledgeTools` case) | exact |
| W0 | `packages/AgentCore/Tests/AgentCoreTests/CacheHintsEligibilityTests.swift` | EXTENDED | unit test | transform | (self — add `preambleDoesNotEnableCacheUnintentionally`) | exact |
| W0 | `packages/VoiceLog/Tests/VoiceLogTests/VoiceLogPublisherTests.swift` | NEW (salvage + extend) | unit test | pub-sub | (stash@{0} file; extend with cap + RMS rate-limit cases) | exact |
| W0 | `packages/VoiceLog/Tests/VoiceLogTests/VoiceLogViewModelTests.swift` | NEW (salvage) | unit test | event-driven | (stash@{0} file) | exact |

---

## Pattern Assignments

### Plan 10-01: MCP Self-Knowledge Tools

#### `packages/MCP/Sources/MCP/InProcess/{ListAudioDevices,GetActiveAudioRoute,GetSelfState,ListCameraDevices}Tool.swift` (MCP in-process tool, request-response)

**Analog:** `packages/MCP/Sources/MCP/InProcess/SearchMemoryTool.swift` (lines 25-66 cited by RESEARCH §Pattern 1).

**Protocol** (from `packages/MCP/Sources/MCP/InProcess/InProcessTool.swift:10-31`):
```swift
public protocol InProcessTool: Sendable {
    var name: String { get }
    var schemaJSON: Data { get }
    var requiresConfirmation: Bool { get }    // D-10: explicit `false` for all four
    func call(args: Data) async throws -> Data
}
```

**Skeleton (use verbatim, swap names):**
```swift
public protocol AudioDeviceListing: Sendable {
    func listAudioDevices() async throws -> [AudioDeviceEntry]
}

public struct ListAudioDevicesTool: InProcessTool {
    public let name = "list_audio_devices"
    public let requiresConfirmation = false        // D-10 — explicit, not defaulted
    public var schemaJSON: Data { /* trivial: object with no required props */ }
    private let dispatcher: any AudioDeviceListing
    public init(dispatcher: any AudioDeviceListing) { self.dispatcher = dispatcher }
    public func call(args: Data) async throws -> Data {
        let entries = try await dispatcher.listAudioDevices()
        return try JSONEncoder().encode(["devices": entries])
    }
}
```

**Acceptance:** RESEARCH §Pattern 1 + Section 1; SPEC AC-01..04.

---

#### `App/MCP/InProcessSelfStateAdapters.swift` (App-side adapter, request-response)

**Analog:** `App/MCP/InProcessMemoryAdapters.swift` (lines 22-56 — Track D-2 commit `707c45b`).

**Imports + module-boundary pattern (verbatim from analog):**
```swift
import Foundation
import JarvisMCP    // for the tool's protocol
import Memory       // analog imports Memory; new file imports Voice for AudioGraphOwner
```
Comment header explains the boundary discipline:
> "These adapters live in `App/` rather than `packages/MCP/` because they cross the module boundary — JarvisMCP intentionally does NOT import Memory (Plan 07-03 design: protocol seam keeps MCP unaware of SQLite/HybridSearch internals)."

Phase 10 mirrors this: JarvisMCP does NOT import `Voice`, `AVFoundation`, or `CoreAudio`. The four adapters in `App/MCP/InProcessSelfStateAdapters.swift` provide the bridge.

**Adapter pattern (verbatim shape):**
```swift
public struct CoreAudioDeviceListAdapter: AudioDeviceListing {
    public init() {}
    public func listAudioDevices() async throws -> [AudioDeviceEntry] {
        try CoreAudioIntrospection.snapshotDevices()
    }
}

public actor AudioGraphRouteAdapter: ActiveAudioRouteDispatching {
    private let owner: AudioGraphOwner
    public init(owner: AudioGraphOwner) { self.owner = owner }
    public func getActiveAudioRoute() async throws -> ActiveAudioRoute? {
        guard let variant = await owner.currentVariant else { return nil }
        let snap = await owner.activeRouteSnapshot()
        return ActiveAudioRoute(/* fields */)
    }
}
```

**CoreAudio enumeration body** — see RESEARCH §Example 1 (lines 477-524), template from `build-devoverlay/SourcePackages/checkouts/argmax-oss-swift/Sources/WhisperKit/Core/Audio/AudioProcessor.swift:818-879`. ~80 LOC of `AudioObjectGetPropertyData` boilerplate.

**Camera enumeration body** — see RESEARCH §Example 2 (lines 528-558). `AVCaptureDevice.DiscoverySession(deviceTypes:[.builtInWideAngleCamera, .external, .continuityCamera], mediaType:.video, position:.unspecified)`. Read-only; does NOT trigger TCC prompt (verified A2).

**Self-state composition** — see RESEARCH §Example 4 (lines 594-635). Bundle + ProcessInfo + closure-injected actor probes for VoiceController.state / TTSEngine tier / etc. Uses captured `Date()` at launch (NOT `ProcessInfo.systemUptime` — that's host uptime).

---

#### `App/MCP/MCPRuntimeWiring.swift` (MODIFIED — tool registration site)

**Analog:** Self. Lines 99-119 are the existing helper-spawn registration block; Phase 10 adds `InProcessToolRegistry.register(_:)` calls in the same builder.

**Existing pattern (lines 99-113):**
```swift
try await client.register(
    name: "mcp-time",
    binaryURL: helperBinary(in: helpersDir, name: "mcp-time"),
    requiresConfirmation: false
)
// ...
try await client.register(
    name: "mcp-applescript",
    binaryURL: helperBinary(in: helpersDir, name: "mcp-applescript"),
    requiresConfirmation: true     // <-- only this one is `true` per check-applescript-confirmation.sh
)
```

**Add (after stdio helpers, in `installAgent` not `MCPRuntimeWiring.build` — needs runtime refs):**
```swift
let inproc = InProcessToolRegistry()
await inproc.register(ListAudioDevicesTool(dispatcher: CoreAudioDeviceListAdapter()))
await inproc.register(GetActiveAudioRouteTool(dispatcher: AudioGraphRouteAdapter(owner: audioGraphOwner)))
await inproc.register(GetSelfStateTool(dispatcher: SelfStateAdapter(/* closures */)))
await inproc.register(ListCameraDevicesTool(dispatcher: AVCaptureDeviceListAdapter()))
```

Then thread `inproc` into the existing `MCPToolDispatcher` aggregation point — verify the path used by `SearchMemoryTool` in `installMemory` (Plan 07-06).

**Boundary-gate constraint (D-10/D-29):** All four tools register with `requiresConfirmation: false` explicitly so `scripts/check-applescript-confirmation.sh` semantics stay readable. Wave-0 test `MCPRuntimeWiringTests/registersFourSelfKnowledgeTools` asserts each one.

---

#### `packages/Voice/Sources/Voice/AudioGraph/AudioGraphOwner.swift` (MODIFIED — additive accessor)

**Analog:** Self. RESEARCH §Example 3 + Assumption A1: add `activeRouteSnapshot() -> ActiveRouteSnapshot` actor method (~5 LOC) returning `(inputUID, inputName, outputUID, outputName, sampleRate, channels)`. Read existing internal state populated by the format probe (search for `"probed format"` log line).

---

### Plan 10-02: System Prompt Preamble

#### `packages/AgentCore/Sources/AgentCore/ContextBuilder.swift` (MODIFIED)

**Analog:** Self. Add `static let selfAwarePreamble: String` constant + `static func systemPrompt(for: TurnContext) -> String`.

**Skeleton (verbatim from RESEARCH §Example 5, lines 640-672):**
```swift
extension ContextBuilder {
    /// Locked self-aware preamble — D-13 single string constant.
    /// Total length: keep < 2 KB to stay well below the 4096-char cache
    /// boundary (Pitfall #4). Do NOT enumerate the tool list (D-14).
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

    public static func systemPrompt(for turn: TurnContext) -> String {
        var s = selfAwarePreamble
        if let presence = turn.presenceText { s += "\n\n" + presence }
        if let memory = turn.memoryHydration { s += "\n\n" + memory }
        return s
    }
}
```

**Cache-eligibility constraint (Pitfall #4 + Assumption A4):** Total system prompt must stay <4096 chars to keep `eligibleForSystemPrompt` returning `nil` (no cache marker, no cache-creation cost on per-turn-varying content). Wave-0 test `CacheHintsEligibilityTests/preambleDoesNotEnableCacheUnintentionally` enforces.

#### `App/AppDelegate.swift:1242` (single-line surgical change — system prompt emit point)

**Current literal (verified-read):**
```swift
let orchestrator = AgentOrchestrator(
    configStore: configStore,
    providerFactory: providerFactory,
    toolDispatcher: mcpRuntime.dispatcher,
    replayLog: replayLog,
    sessionId: sessionId,
    systemPrompt: "You are Jarvis, a personal macOS assistant.",     // <-- LINE 1242
    availableTools: [],
    visionRouter: self.visionRouter,
    presenceSnapshot: PresenceStateSnapshot.shared
)
```

**Replace with:**
```swift
systemPrompt: ContextBuilder.systemPrompt(for: turnContext),
```

Verify against `packages/AgentCore/Sources/AgentOrchestrator/AgentOrchestrator.swift:38, 98-108, 254` — orchestrator currently takes `systemPrompt: String` directly; if per-turn enrichment is needed, plan 10-02 must thread `TurnContext` through (out of scope for surgical change — keep preamble static if shape mismatches).

---

### Plan 10-03: DevOverlay Subscriber Fix (DIAG-02)

> **Two-step pattern (D-15/D-16, mandatory order):**
> 1. **First commit:** read-only investigation note (in plan working dir or code comment block) explaining what's actually broken — broadcaster not subscribed, subscription torn down too early, `@Published` not driving the view, etc. NO source changes.
> 2. **Second commit:** the surgical fix (3-line `installAgent` change + 4-line `toggleDevOverlay()` change identified in RESEARCH §Example 6). NO refactor of `DevOverlayBridge` or `DevOverlayViewModel` — they're correct.

#### `App/AppDelegate.swift` lines 1325-1330 (DIAG-02 surgical fix #1)

**Current code (verified-read):**
```swift
// 5c. DevOverlay subscriber (lossy — observational; reserved for the
//     DevOverlay emitter wiring in a follow-on plan). Subscribed here
//     so the broadcaster's three-subscriber pattern is established;
//     the drain task simply consumes events to keep the actor's
//     internal mirror flushing.
let devSub = await broadcaster.subscribe(priority: .devOverlay, capacity: 32)
devOverlaySubscriberTask = Task {
    for await _ in devSub.stream {
        if Task.isCancelled { break }
    }
}
```

**Replace with (RESEARCH §Example 6, lines 680-696):**
```swift
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
        await devSnapshotEmitter.apply(event)        // <— THE FIX (was no-op)
    }
}
```

Add `var devSnapshotEmitter: DevSnapshotEmitter?` ivar to AppDelegate.

#### `App/AppDelegate.swift:2020-2027` `toggleDevOverlay()` (DIAG-02 surgical fix #2)

**Replace with:**
```swift
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

**Bridge lifecycle:** the bridge MUST be retained on `self.devOverlayBridge` (new ivar) so its subscriber Task isn't deallocated immediately. `DevOverlayBridge` already holds `viewModel` weakly — that's correct; the holding direction is bridge→AppDelegate→bridge. Add `var devOverlayBridge: DevOverlayBridge?` ivar.

#### `packages/DevOverlay/Tests/DevOverlayTests/DevOverlayBroadcasterIntegrationTests.swift` (SALVAGE from stash)

**Verdict from RESEARCH §Stash Salvage Triage (line 1009):** SALVAGE as-is. Integration test fixture is exactly what AC-08 needs end-to-end.

---

### Plan 10-04: Audio Loopback + TTS Playback Diagnostics

#### `App/MenuBar/MenuBarContextMenu.swift` (MODIFIED — extend `build()`)

**Analog:** Self — `MenuBarContextMenu.build()` lines 7-39 + `makeItem(title:action:)` closure-trampoline pattern at lines 48-60 (verified-read).

**Existing closure-trampoline pattern (verbatim from `MenuBarContextMenu.swift:48-60`):**
```swift
private static func makeItem(title: String, action: @escaping () -> Void) -> NSMenuItem {
    let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
    let target = ClosureTarget(action: action)
    item.target = target
    item.action = #selector(ClosureTarget.run)
    objc_setAssociatedObject(
        item,
        &MenuBarContextMenu.trampolineKey,
        target,
        .OBJC_ASSOCIATION_RETAIN_NONATOMIC
    )
    return item
}
```
**Critical:** the `objc_setAssociatedObject` retain dance is load-bearing (`NSMenuItem.target` is `weak`). Reuse `makeItem(title:action:)` — do NOT inline new menu items.

**Diff shape (RESEARCH §Pattern 3, lines 376-384):**
```swift
// Add to build()'s parameter list:
//   audioLoopbackAction: @escaping () -> Void,
//   ttsPlaybackAction: @escaping () -> Void
// Add Diagnostics submenu before the "Quit Jarvis" separator:

let diagnostics = NSMenuItem(title: "Diagnostics", action: nil, keyEquivalent: "")
let diagSub = NSMenu(title: "Diagnostics")
diagSub.addItem(makeItem(title: "Audio Loopback Test (2s)", action: audioLoopbackAction))
diagSub.addItem(makeItem(title: "Speak Test Phrase",         action: ttsPlaybackAction))
diagnostics.submenu = diagSub
menu.addItem(NSMenuItem.separator())
menu.addItem(diagnostics)
```

`MenuBarIconControllerTests.swift` parameter list (lines 14, 35, 50) needs the two new closures threaded through (search by `devOverlayToggleAction:`).

#### `App/AppDelegate.swift` `audioLoopbackAction()` (NEW closure)

**Analog:** Existing `AudioGraphOwner.subscribe(capacityFrames:)` callsites in `installVoice` (Track B-7).

**Skeleton (verbatim from RESEARCH §Example 7, lines 720-769):**
```swift
private func audioLoopbackAction() {
    Task.detached { [weak self] in
        guard let self else { return }
        guard let owner = await self.audioGraphOwner else { return }
        guard let sub = await owner.subscribe(capacityFrames: 16_000 * 3) else { return }
        let target = 16_000 * 2
        var collected = [Float]()
        collected.reserveCapacity(target)
        let deadline = ContinuousClock.now + .seconds(2)
        var scratch = [Float](repeating: 0, count: 1280)
        while ContinuousClock.now < deadline && collected.count < target {
            let n = scratch.withUnsafeMutableBufferPointer { sub.ringBuffer.readMono16k(into: $0) }
            if n > 0 { collected.append(contentsOf: scratch.prefix(n)) }
            else { try? await Task.sleep(for: .milliseconds(10)) }
        }
        await Self.playMono16k(collected)
    }
}
```
Playback uses a separate `AVAudioEngine` instance (NOT `AudioGraphOwner`'s engine) — see RESEARCH lines 752-769. **D-18:** reuses existing tap; no new ring buffer; doesn't disturb wake-word DAG.

#### `App/AppDelegate.swift` `ttsPlaybackAction()` (NEW closure)

**Analog:** `App/Voice/VoiceOutputWiring.swift:13-25` — `TTSEngineActor` tier-1 constructor.

**Skeleton (verbatim from RESEARCH §Example 8, lines 776-792):**
```swift
private func ttsPlaybackAction() {
    Task.detached { [weak self] in
        guard let self else { return }
        guard let engine = await self.ttsEngine else { return }
        do {
            try await engine.synthesize(
                "Jarvis is online",
                tier: .tier1,                               // D-19 — no tier-2
                voice: AVSpeechSynthesisVoice.currentLanguageCode()
            )
        } catch {
            // Cancellation expected if user clicks again mid-speech (TTSEngineActor cancels in-flight)
        }
    }
}
```

**TTSEngineActor contract (verified):** `synthesize` already yields `.started` / `.firstAudio(at:)` / `.finished` on its event stream (lines 109-119) and self-cancels on subsequent calls (lines 92-97). Diagnostic does not need to await events.

---

### Plan 10-05: Voice Log Window (DIAG-01) — Largest Plan

#### `packages/VoiceLog/Sources/VoiceLog/VoiceLogPublisher.swift` (NEW — salvage w/ capacity bump)

**Analog:** `packages/Voice/Sources/Voice/AudioGraph/BufferBroadcaster.swift` (lines 38-74 verified-read). Same actor-with-fan-out shape; AsyncStream replaces RingBuffer for events.

**Pattern (RESEARCH §Pattern 4, lines 388-392):**
> Stashed `VoiceLogPublisher` actor at `stash@{0}:packages/VoiceLog/Sources/VoiceLog/VoiceLogPublisher.swift:21-87` (review per D-25). Compare against the `BoundedAsyncChannel` pattern used by `DevSnapshotEmitter.output`. Stashed version uses raw `AsyncStream` with `bufferingPolicy: .bufferingNewest(capacity)`, which matches D-21 (in-memory, FIFO eviction at 2000) but the cap differs (stash uses 1000).

**Constraints:**
- **Actor** (D-20). Swift 6 strict concurrency safe; `nonisolated let stream: AsyncStream<VoiceLogEntry>` + internal continuation.
- **Cap = 2000** (D-21; stash default is 1000 — bump on salvage).
- **RMS rate-limit at PUBLISHER side** (D-24, Pitfall #5): producer holds `lastEmittedAt: Date`, drops samples if `Date().timeIntervalSince(lastEmittedAt) < 1.0`. NOT subscriber-side throttling.
- **In-memory only** (D-21, T-06-05-03): never call `Logger`/`os.log`/`OSLog` on event payloads even for "debug." Existing grep gate `scripts/check-no-transcript-oslog.sh` enforces.

#### `packages/VoiceLog/Sources/VoiceLog/VoiceLogEvent.swift` (NEW — salvage w/ taxonomy diff)

**Analog:** stash@{0} file (176 LOC). **Taxonomy differs from D-22.** Triage:
- **KEEP (D-22 set):** `wakeWordFired`, `wakeWordPaused`, `wakeWordResumed`, `vadSpeechStart`, `vadSpeechEnd`, `sttPartial`, `sttFinal`, `ttsSynthesizeStart`, `ttsSynthesizeComplete`, `ttsCancelled`, `voiceStateTransition(from:to:)`, `audioLevelRMS(value:)`, `voiceError`.
- **STRIP (NOT in D-22):** `vadSilence`, `vadSpeech` (substates of voiceStateTransition), `orchestratorSubmit`, `orchestratorTurnEnd`, `orchestratorCancelled`, `orchestratorError` (out of scope — voice surface only).

**Constraint:** Phase 10 cannot widen D-22 (locked, would require phase amendment). Trim to D-22; defer orchestrator events to a future Memory Log / orchestrator log phase.

#### `packages/VoiceLog/Sources/VoiceLog/VoiceLogWindow.swift` (NEW — salvage)

**Analog:** `packages/DevOverlay/Sources/DevOverlay/DevOverlayWindow.swift` (verified-read lines 1-64).

**Imports + class shape (verbatim from analog, swap NSPanel→NSWindow per RESEARCH §Pattern 2 line 335):**
```swift
#if canImport(AppKit) && canImport(SwiftUI)
import AppKit
import SwiftUI

@available(macOS 14.0, *)
@MainActor
public final class VoiceLogWindow {
    private let window: NSWindow                        // long-lived; not NSPanel
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
        w.setFrameAutosaveName("jarvis-voice-log-window")  // D-23
        w.center(); w.orderOut(nil)
        self.window = w
    }
    public func show() { window.makeKeyAndOrderFront(nil) }
    public func hide() { window.orderOut(nil) }
    public func toggle() { window.isVisible ? hide() : show() }
}
#endif
```

**T-09 INVARIANT (CRITICAL):** Voice Log MUST be AppKit (`NSWindow` + `NSHostingView`), NOT WKWebView (D-23). Adding a second `WKContentWorld` widens the webview surface area and violates `check-no-evaluate-javascript.sh`. The salvaged `VoiceLogBridge.swift` MUST be reviewed for accidental webview imports — discard if it imports `WebKit`.

#### `packages/VoiceLog/Sources/VoiceLog/VoiceLogBridge.swift` (NEW — review for webview leak)

**Analog:** `packages/DevOverlay/Sources/DevOverlay/DevOverlayBridge.swift:17-52` (channel→view-model pump).

**Shape:** AsyncStream→`@MainActor` pump. Subscriber Task drains the publisher's stream, marshals entries to `VoiceLogViewModel.append(_:)` on `@MainActor`. **NO WebKit imports.** **NO `WKScriptMessageHandler`.** **NO `evaluateJavaScript`.** Verify via grep before commit.

#### `packages/VoiceLog/Sources/VoiceLog/VoiceLogViewModel.swift` (NEW — salvage w/ FIFO check)

**Analog:** `packages/DevOverlay/Sources/DevOverlay/DevOverlayViewModel.swift:17-42` — `private(set) var snapshot` single-writer enforcement. Phase 10 mirrors: `private(set) var entries: [VoiceLogEntry]` with single `apply(_:)` writer. **Verify cap=2000 FIFO eviction** (D-21).

#### `App/Voice/VoiceLogAdapters.swift` (NEW — review-only salvage)

**Analog:** No direct analog. Closest pattern: existing in-process `OutboundBatcher` (sink injection) + the `voiceLog: VoiceLogSink?` closure-injection pattern from RESEARCH §Example 9 (lines 800-820).

**KEY INSIGHT (RESEARCH §Pattern 4 + Example 9):** AsyncStream is a SINGLE-CONSUMER protocol — multiple `for await` loops on the same stream produce undefined ordering. **The publish callsite must be inside the existing consumer, not a parallel reader.** The stash version may try parallel readers — discard that pattern; thread an `Optional<VoiceLogSink>` through `VoiceController.init` (and equivalent install paths) and call `await voiceLog?.post(.event(...))` inline at the existing event boundaries.

#### Voice Subsystem Attach Points (9-row table from RESEARCH §Example 9)

Plan 10-05 ships one tiny additive diff per row. **EVERY publish callsite is inside the existing single consumer**, never a parallel reader.

| # | Event | File | Line / Function | Phase 10 Add |
|---|-------|------|-----------------|--------------|
| 1 | `wakeWordFired` | `packages/Voice/Sources/Voice/VoiceController.swift:283` (`handleWakeWord`) | switch-state on event | First line of function: `await voiceLog?.post(.wakeWordFired(at: Date()))` |
| 2 | `wakeWordPaused` / `wakeWordResumed` | `packages/Voice/Sources/Voice/WakeWord/WakeWordDAG.swift:119, 126` | `pause()` / `resume()` log lines | One line under each `logger.debug` |
| 3 | `vadSpeechStart` / `vadSpeechEnd` | `packages/Voice/Sources/Voice/VoiceController.swift:521-528` (`runVADInterceptor`) | switch on `decision` cases | One line per case |
| 4 | `sttPartial` | `packages/Voice/Sources/Voice/VoiceController.swift:448` (partials drain Task) | `for await _ in partials` (currently DISCARDS per T-06-05-03) | Replace with `for await p in partials { await voiceLog?.post(.sttPartial(text: p.text, at: Date())) }` |
| 5 | `sttFinal` | `packages/Voice/Sources/Voice/VoiceController.swift:458` (`handleSTTFinalized`) | called at end of finalize Task | One line at top: `await voiceLog?.post(.sttFinal(text: text, at: Date()))` |
| 6 | `voiceStateTransition` | `packages/Voice/Sources/Voice/VoiceController.swift` (search `doTransition`) | every state change | Inside `doTransition`: `await voiceLog?.post(.voiceStateTransition(from: old, to: new))` |
| 7 | `ttsSynthesizeStart` / `Complete` / `Cancel` | `packages/Voice/Sources/Voice/TTS/TTSEngineActor.swift:91, 119, 192` | `synthesize` enters / completes; `cancel` body | Before `eventContinuation.yield(.started)`, after `.finished`, in `cancel()` body |
| 8 | `audioLevelRMS` | `packages/Voice/Sources/Voice/Control/AudioLevelEmitter.swift:80` (32 ms windows) | RMS computed per window | **Throttled (D-24):** `if Date().timeIntervalSince(lastEmittedAt) >= 1.0 { post; lastEmittedAt = now }` |
| 9 | `voiceError` | `packages/Voice/Sources/Voice/VoiceController.swift:454-455` + WakeWord errors | logger.warning calls today | `await voiceLog?.post(.voiceError(message: ..., at: Date()))` next to each logger.warning/error |

**T-06-05-03 reminder (Pitfall A9):** the existing `VoiceController.swift:448` line currently DISCARDS partials precisely because the comment says "transcript text is NEVER passed to logger or os.log." Plan 10-05 changes this to PUBLISH partials to the in-memory Voice Log — which IS allowed (the rule is "no OSLog," not "no in-memory display"). **Verify the publisher implementation does not call any logging APIs on the event payload.**

---

## Shared Patterns (Cross-Cutting)

### Authentication / Authorization
**Source:** N/A — no new auth surfaces in Phase 10. All MCP tools register `requiresConfirmation: false` (D-10); `scripts/check-applescript-confirmation.sh` semantics unchanged.

### Error Handling
**Source:** Existing `try?` patterns + `do/catch` swallowing in diagnostic closures (RESEARCH §Examples 7, 8 lines 754, 786-790). Diagnostics are best-effort; failures are non-fatal.

### Concurrency Discipline (CLAUDE.md §Constraints + D-20)
**Source:** Swift 6 strict concurrency:
- All new actors use `nonisolated let` for AsyncStream + serial executor for cancellation contracts.
- `OSAllocatedUnfairLock` allowed (existing `BufferBroadcaster.swift:38` precedent); `NSLock` from async forbidden.
- `@MainActor` for AppKit window classes (verified-read pattern in `DevOverlayWindow.swift:18`).

### Test Naming (D-31, CLAUDE.md §Test naming conventions)
**Source:** CLAUDE.md. Phase 10 ships with right names from day 1:
- **`Mock*`** — records calls AND returns scripted responses.
- **`Stub*`** — returns canned data without recording.
- **`Fake*`** — alternative implementation behaviorally close to production.

Do NOT import the older naming-mismatch corpus. New test files added in Phase 10 follow the convention.

### Module Boundary Discipline
**Source:** `App/MCP/InProcessMemoryAdapters.swift` header comment (lines 4-12). JarvisMCP intentionally does NOT import Memory; adapters in `App/` cross the boundary. Phase 10 mirrors: JarvisMCP does NOT import Voice/AVFoundation/CoreAudio — adapters in `App/MCP/InProcessSelfStateAdapters.swift` provide the bridge.

### Boundary Gate Discipline (D-29)
**Source:** CLAUDE.md §"Boundary gates". All 18 existing gates stay green at every plan boundary:
- `check-app-builds.sh` (App target compiles)
- `check-applescript-confirmation.sh` (`requiresConfirmation: true` reserved for `mcp-applescript`)
- `check-no-leftover-stubs.sh` (no stub-marker rot)
- `check-install-order.sh` (install cascade order preserved)
- `check-no-null-voice-adapters.sh` (no `Null*Adapter` resurrection)
- `check-no-evaluate-javascript.sh` (T-09 — webview surface area; CRITICAL for Voice Log being AppKit not WKWebView per D-23)
- `check-no-transcript-oslog.sh` (T-06-05-03 — Voice Log payloads must not pass through `Logger`/`os.log`)
- 11 other gates listed in CLAUDE.md.

---

## Anti-Patterns to Avoid

| # | Anti-Pattern | Source / Why | Phase 10 Manifestation |
|---|-------------|--------------|------------------------|
| AP-01 | **Tests-green ≠ production-works** | CONTEXT D-26..D-28; RESEARCH Pitfall #2; `.continue-here.md` blocker | Every plan must include `## Live Verification` section in SUMMARY.md per D-26 template (relaunch + observed log lines + AC match). `/gsd-verify-phase 10` rejects plans without this section. |
| AP-02 | **Parallel agents on overlapping files** | CONTEXT D-01; RESEARCH Pitfall #6; the stash exists because of this exact failure | Phase 10 plans run **serially**, single-threaded. No parallel-agent fan-out anywhere in Phase 10. |
| AP-03 | **Silent TCC fail** (explicit `requestAccess` not reached) | RESEARCH Pitfall #3; `b92d062` commit body | When verifying any plan that touches mic/camera/audio: `tccutil reset Microphone com.koftwentytwo.jarvis` (and/or Camera) before relaunch. Verify `tccd` log line during relaunch window proves `AVCaptureDevice.requestAccess(for:)` was reached. |
| AP-04 | **Cache-eligibility breakage** when preamble grows system prompt past 4096 chars | RESEARCH Pitfall #4 + Assumption A4; `CacheHints.swift:32-46` | Preamble is a single locked string composed BEFORE presence enrichment. Either keep total under 4096 chars (no cache marker) OR ensure ONLY preamble is the cache-eligible block. Wave-0 test `CacheHintsEligibilityTests/preambleDoesNotEnableCacheUnintentionally` enforces. |
| AP-05 | **Voice Log audioLevelRMS flooding actor hops** | RESEARCH Pitfall #5; CONTEXT D-24 | Rate-limit at the **publish site** (producer holds `lastEmittedAt: Date`, drops if <1s). NOT subscriber-side throttling — actor hops happen on every PRODUCE call regardless of whether subscriber renders. |
| AP-06 | **Stash@{0} wholesale apply** without per-file verification | RESEARCH Pitfall #6; CONTEXT D-05/D-06 | NEVER `git stash apply stash@{0}` as a unit. Salvage file-by-file via `git show 101a2aa1:<path>`. See Stash Salvage Triage table below. Drop stash ONLY after Plan 10-05 SUMMARY.md is committed (D-06). |
| AP-07 | **WKContentWorld widening** for Voice Log | T-09 invariant; CONTEXT D-23; SPEC line 150 | Voice Log MUST be AppKit (`NSWindow` + `NSHostingView`), NOT WKWebView. `check-no-evaluate-javascript.sh` enforces. Salvaged `VoiceLogBridge.swift` MUST be reviewed for `WebKit` imports — discard if present. |
| AP-08 | **Adding a second `cancelAndSubmit` call site** | VOICE-14; `VoiceController.swift:344` | Audio loopback (Plan 10-04) and TTS playback (Plan 10-04) MUST NOT touch the orchestrator's submit path. Diagnostics are pure I/O. |
| AP-09 | **Routing transcript text through `Logger` / `os.log`** even for debug | T-06-05-03; SPEC line 60 | Voice Log holds transcript content in-process only. Publisher implementation must NOT call any logging APIs on event payloads. Existing grep gate enforces. |
| AP-10 | **Spawning a new audio tap** for the loopback diagnostic | CONTEXT D-18; RESEARCH lines 397-399 | Use `AudioGraphOwner.subscribe()` (Track B-7 fan-out). New tap races wake-word DAG and corrupts VOICE-10 six-step teardown. |
| AP-11 | **Caching the device list** in `list_audio_devices` / `list_camera_devices` | CONTEXT D-09 | Hardware can be unplugged between calls — freshness > performance for a debug introspection tool. |
| AP-12 | **Allowing `requiresConfirmation` to default** | CONTEXT D-10; RESEARCH lines 401-402 | Set `false` explicitly on each new tool so `check-applescript-confirmation.sh` semantics stay readable. |
| AP-13 | **Refactoring `DevOverlayBridge` or `DevOverlayViewModel`** in Plan 10-03 | CONTEXT D-16; RESEARCH Pitfall #1 | Bridge and view-model are correct; the bug is upstream wiring. Minimum surgical change only. |
| AP-14 | **Reaching into `DevOverlayWindow.viewModel` to set fields directly** | RESEARCH lines 396-397; `DevOverlayViewModel.swift:23` `private(set)` enforcement | Wire the bridge to the emitter's channel; don't shortcut around `apply(_:)`. |
| AP-15 | **Parallel readers on the same `AsyncStream`** for Voice Log | RESEARCH §Example 9 lines 806-810 | AsyncStream is single-consumer. Publish callsites are INSIDE existing consumers (e.g., inside `VoiceController.handleWakeWord`), not parallel readers spawned in `VoiceLogAdapters.swift`. |
| AP-16 | **Two-step pattern violation** in Plan 10-03 (fix-before-investigation) | CONTEXT D-15/D-16 | Plan 10-03 commits in ORDER: (a) read-only investigation note FIRST, (b) surgical fix SECOND. Skipping (a) means risking premature broadcaster refactor. |

---

## Stash Salvage Triage (D-05 — verbatim from RESEARCH §Stash Salvage Triage)

> Files in `stash@{0}` (commit `bfbd37c`, 2026-05-06 partial-work-from-failed-parallel-dispatch). Three-parent merge — use `git show 101a2aa1:<path>` to inspect untracked files (third parent).

| File | Plan | Salvage Verdict | Notes |
|------|------|-----------------|-------|
| `App/AppDelegate.swift` (190-line edit) | — | **DISCARD** | Partial pieces from parallel agents; re-author cleanly per locked decisions in 10-03 + 10-05. |
| `App/MenuBar/MenuBarContextMenu.swift` (6-line edit) | 10-04 | **DISCARD; re-author** | Pattern is correct (add Diagnostics submenu) but originator lacked locked D-17 / D-19 specs. |
| `App/Voice/VoiceLogAdapters.swift` (185 LOC, untracked) | 10-05 | **REVIEW; partial salvage likely** | If shape matches D-25 (one publish callsite per voice surface), salvage. If it tries to spawn parallel readers on `AsyncStream`, discard the parallel-reader pattern. |
| `Jarvis.xcodeproj/project.pbxproj` + `project.yml` | 10-05 | **DISCARD; regen** | Re-author after `project.yml` edits via `xcodegen`. |
| `packages/DevOverlay/Tests/DevOverlayTests/DevOverlayBroadcasterIntegrationTests.swift` (162 LOC) | 10-03 | **SALVAGE** | Integration test fixture is exactly what AC-08 needs end-to-end. |
| `packages/Vision/Tests/VisionTests/CameraButtonTCCWiringTests.swift` (90 LOC) | — | **OUT OF SCOPE** | Camera button verification is post-`b92d062` retest, not a Phase 10 requirement. Defer. |
| `packages/VoiceLog/Package.swift` (33 LOC) | 10-05 | **SALVAGE** | Standard SPM Package.swift. |
| `packages/VoiceLog/Sources/VoiceLog/VoiceLogEvent.swift` (176 LOC) | 10-05 | **SALVAGE w/ TAXONOMY DIFF** | Stashed taxonomy includes `vadSilence`, `vadSpeech`, `orchestratorSubmit`, `orchestratorTurnEnd`, `orchestratorCancelled`, `orchestratorError` which are NOT in D-22's locked list. Trim to D-22 set. (D-22 is locked — don't widen.) |
| `packages/VoiceLog/Sources/VoiceLog/VoiceLogPublisher.swift` (92 LOC) | 10-05 | **SALVAGE w/ CAPACITY BUMP** | Actor-shaped (matches D-20). Default capacity 1000 → bump to 2000 (D-21). RMS rate-limit at producer side (D-24) is NOT in stashed file — add. |
| `packages/VoiceLog/Sources/VoiceLog/VoiceLogView.swift` (185 LOC) | 10-05 | **SALVAGE** | SwiftUI body — review for Voice Log filter UI (D-claude-discretion). |
| `packages/VoiceLog/Sources/VoiceLog/VoiceLogViewModel.swift` (84 LOC) | 10-05 | **SALVAGE w/ EVICTION CHECK** | Verify FIFO at 2000 entries (D-21). |
| `packages/VoiceLog/Sources/VoiceLog/VoiceLogWindow.swift` (78 LOC) | 10-05 | **SALVAGE** | NSWindow + NSHostingView + frameAutosaveName — matches D-23 exactly. |
| `packages/VoiceLog/Sources/VoiceLog/VoiceLogBridge.swift` (46 LOC) | 10-05 | **REVIEW** | Verify it does NOT introduce a webview content world (D-23). If it's a thin AsyncStream→@MainActor pump (mirror of `DevOverlayBridge`), salvage. |
| `packages/VoiceLog/Tests/VoiceLogTests/VoiceLogPublisherTests.swift` (91 LOC) | 10-05 | **SALVAGE w/ EXTEND** | Add `capsAt2000WithFIFO` + `audioLevelRMSRateLimited` cases. |
| `packages/VoiceLog/Tests/VoiceLogTests/VoiceLogViewModelTests.swift` (96 LOC) | 10-05 | **SALVAGE** | — |

**Drop sequence (D-06):** `git stash drop stash@{0}` ONLY after Plan 10-05 SUMMARY.md is committed. Phase 10 verifier checks for stash absence as a tidiness signal.

---

## No Analog Found

None. Every new Phase 10 file has a near-identical analog already shipping in the repo. The single piece of meaningfully novel code is `CoreAudioIntrospection.snapshotDevices()` (~80 LOC of `AudioObjectGetPropertyData` boilerplate) — and even that has a cross-reference template at `build-devoverlay/SourcePackages/checkouts/argmax-oss-swift/Sources/WhisperKit/Core/Audio/AudioProcessor.swift:818-879`.

> **Key insight from RESEARCH:** Phase 10 is wiring, not architecture. Every "build a thing" instinct should bounce off an existing primitive.

---

## Metadata

**Analog search scope:**
- `App/MCP/`, `App/MenuBar/`, `App/Voice/`, `App/AppDelegate.swift`
- `packages/MCP/Sources/MCP/InProcess/`, `packages/MCP/Tests/`
- `packages/AgentCore/Sources/AgentCore/`, `packages/AgentCore/Sources/AgentOrchestrator/`
- `packages/DevOverlay/Sources/DevOverlay/`, `packages/DevOverlay/Tests/`
- `packages/Voice/Sources/Voice/AudioGraph/`, `packages/Voice/Sources/Voice/WakeWord/`, `packages/Voice/Sources/Voice/TTS/`, `packages/Voice/Sources/Voice/Control/`
- `stash@{0}` (`bfbd37c`, untracked parent `101a2aa1`) for VoiceLog scaffolding triage

**Files verified by direct read during pattern mapping:**
- `App/MCP/InProcessMemoryAdapters.swift:1-56`
- `App/MCP/MCPRuntimeWiring.swift:1-130`
- `App/MenuBar/MenuBarContextMenu.swift:1-80`
- `packages/DevOverlay/Sources/DevOverlay/DevOverlayWindow.swift:1-64`
- `packages/AgentCore/Sources/AgentOrchestrator/DevSnapshotEmitter.swift:1-60`
- `packages/MCP/Sources/MCP/InProcess/InProcessTool.swift:1-31`
- `packages/Voice/Sources/Voice/AudioGraph/BufferBroadcaster.swift:1-80`
- `App/AppDelegate.swift:1235-1344` (system prompt emit point + DevOverlay no-op drain — both line numbers in RESEARCH confirmed correct)

**Pattern extraction date:** 2026-05-06

---

*Phase: 10-self-awareness-diagnostics*
*Patterns mapped: 2026-05-06*
*Next step: gsd-planner consumes this PATTERNS.md to assign analog patterns to plan actions in 10-01-PLAN.md..10-05-PLAN.md*
