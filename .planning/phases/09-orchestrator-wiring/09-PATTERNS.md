# Phase 9: Orchestrator Wiring - Pattern Map

**Mapped:** 2026-05-01
**Files analyzed:** 11 (3 new adapters + 2 new actors + 1 deleted + 5 modified)
**Analogs found:** 11 / 11 (100% — Phase 9 is pure dispatch glue; every type already exists)

---

## File Classification

| New / Modified File | Role | Data Flow | Closest Analog | Match Quality |
|---------------------|------|-----------|----------------|---------------|
| `App/Voice/VoiceOrchestratorAdapter.swift` (NEW) | adapter (App-target bridge) | request-response | `App/AppDelegate.swift:1097` `AppDelegateBannerAdapter` | exact |
| `App/Voice/VoiceTTSAdapter.swift` (NEW) | adapter (App-target bridge) | request-response | `App/AppDelegate.swift:1097` `AppDelegateBannerAdapter` | exact |
| `App/Voice/VoiceBusEmitterAdapter.swift` (NEW) | adapter (App-target bridge) | streaming (~30 Hz) | `App/AppDelegate.swift:1128` `NullBusEmitterAdapter` (current placeholder) | exact-replacement |
| `App/Voice/NullVoiceAdapters.swift` (DELETED) | placeholder | n/a | n/a | n/a |
| `<package>/OrchestratorEventBroadcaster.swift` (NEW actor, ~80 LOC) | fan-out service | pub-sub (1→N) | `packages/AgentCore/Sources/AgentOrchestrator/DevSnapshotEmitter.swift` (subscribe-to-channel pattern) + `packages/Replay/Sources/Replay/TokenDeltaDropOldestChannel.swift` (drop-oldest policy) | role+flow match |
| `<package>/PresenceStateSnapshot.swift` (NEW actor, ~30 LOC) | snapshot service | event-driven (write) + request-response (read) | `packages/Vision/Sources/Vision/PresenceMonitor.swift` (actor consuming PresenceEvent stream) | role match |
| `App/MCP/PresenceSnapshotAdapter.swift` or fold into existing `App/MCP/AppDelegateContextBuilderAdapter.swift` (MODIFIED) | adapter (App-target bridge) | event-driven | `App/MCP/AppDelegateContextBuilderAdapter.swift` (current — has `attachPresence`) | exact |
| `App/AppDelegate.swift` (MODIFIED — adds `installAgent()`) | bootstrap | sequential | `App/AppDelegate.swift:462` `installVoice()` / `:562` `installMemory()` / `:667` `installVision()` | exact |
| `App/AppDelegate.swift` (MODIFIED — Bus inbound handler for `chatSubmit` / `chatCancelAndSubmit` / `frameAttachRequested`) | bus handler | request-response | `packages/Bus/Sources/Bus/WebviewBridge.swift:68` `onInbound` closure pattern | role match (no current chat handler exists) |
| `packages/AgentCore/Sources/AgentOrchestrator/AgentOrchestrator.swift` (MODIFIED — adds `visionRouter:` ctor dep + `runTurn` images branch + `presenceSnapshot:` ctor dep) | orchestrator | streaming + branching dispatch | itself (lines 59-77 ctor; lines 115-190 `runTurn`) | self-pattern |
| `packages/Vision/Sources/Vision/ContextBuilder.swift` (MODIFIED — `installPresence` becomes real) | utility | event-driven | itself (lines 47-56 current no-op drain) | self-pattern (replace body) |

**Match-quality legend:**
- *exact* — same role + same data flow, same package conventions
- *exact-replacement* — replacing a current placeholder with the real thing; same protocol conformance
- *role match* — same role, different data flow detail
- *self-pattern* — modification of an existing file; the file is its own analog
- *role+flow match* — combines two analogs (subscribe pattern + drop-oldest policy)

---

## Pattern Assignments

### `App/Voice/VoiceOrchestratorAdapter.swift` (NEW — adapter, request-response)

**Role:** Bridge `Voice.VoiceOrchestratorInterface` (text-only, voice-actor side) → `AgentOrchestrator.submit(.voice(text))` / `.cancelAndSubmit(.voice(text))` and emit `VoiceOrchestratorEvent` on the voice events stream when the orchestrator turn completes / cancels / errors. Surface `SubmitOutcome.rejected` reasons to HUD banner via `HUDBannerCoordinator.enqueue(...)` (D-10).

**Closest analog:** `App/AppDelegate.swift:1097-1120` — `AppDelegateBannerAdapter` (the current `final class … : VoiceBannerInterface, @unchecked Sendable` pattern, with `weak var coordinator: HUDBannerCoordinator?` + `Task { @MainActor in coordinator?.enqueue(...) }`).

**Imports pattern** (mirror Voice/Bus boundary; copy from `App/Voice/NullVoiceAdapters.swift:1-3` + `App/AppDelegate.swift:10-11`):
```swift
import Foundation
import Voice
import AgentCore        // BoundedAsyncChannel (events channel type)
import AgentOrchestrator // AgentOrchestrator, SubmitOutcome, RejectReason, TurnInput
```

**Adapter shape** (mirror current `NullOrchestratorAdapter` actor + AsyncStream/Continuation pair from `App/Voice/NullVoiceAdapters.swift:20-38`):
```swift
actor VoiceOrchestratorAdapter: VoiceOrchestratorInterface {
    nonisolated let voiceEvents: AsyncStream<VoiceOrchestratorEvent>
    private nonisolated let eventsCont: AsyncStream<VoiceOrchestratorEvent>.Continuation

    private let orchestrator: AgentOrchestrator
    private let bannerCoordinator: HUDBannerCoordinator?  // weak via @MainActor hop

    init(orchestrator: AgentOrchestrator, bannerCoordinator: HUDBannerCoordinator?) {
        let (stream, cont) = AsyncStream<VoiceOrchestratorEvent>.makeStream()
        self.voiceEvents = stream
        self.eventsCont = cont
        self.orchestrator = orchestrator
        self.bannerCoordinator = bannerCoordinator
    }

    func submit(text: String) async {
        let outcome = await orchestrator.submit(.voice(text))
        await handleOutcome(outcome)
    }

    func cancelAndSubmit(text: String) async {
        eventsCont.yield(.cancelled)  // matches NullOrchestratorAdapter line 35
        let outcome = await orchestrator.cancelAndSubmit(.voice(text))
        await handleOutcome(outcome)
    }
}
```

**Banner-on-rejection pattern** (D-10) — copy from `AppDelegateBannerAdapter.showBanner` at `App/AppDelegate.swift:1101-1112`:
```swift
private func handleOutcome(_ outcome: SubmitOutcome) async {
    switch outcome {
    case .ran, .superseded:
        return  // success — voice events fire naturally from the orchestrator-events
                // broadcaster's voice subscriber (separate from this adapter)
    case .rejected(let reason):
        let coord = bannerCoordinator
        let (id, body) = bannerForReason(reason)
        Task { @MainActor in
            coord?.enqueue(BannerContent(
                id: id,
                priority: 5,                          // higher than voice-aec-banner (10)
                title: "Voice Submission Rejected",
                body: body,
                action: nil
            ))
        }
        eventsCont.yield(.error)  // VoiceController returns to .idle
    }
}

private func bannerForReason(_ reason: RejectReason) -> (id: String, body: String) {
    switch reason {
    case .turnInFlight:        return ("voice-rejected-turninflight",
                                       "Already thinking — wait or say cancel.")
    case .providerUnavailable: return ("voice-rejected-provider",
                                       "Provider unavailable — check Anthropic key or Ollama daemon.")
    case .configError:         return ("voice-rejected-config",
                                       "Config error — see ~/Library/Logs/Jarvis/system.log.")
    }
}
```

**Why the voice events stream stays adapter-owned vs broadcaster-owned (D-09 reading):** `VoiceOrchestratorInterface.voiceEvents` is a typed enum (`turnEnded(finalText:) / cancelled / error`) consumed inside `VoiceController`'s state machine. The `OrchestratorEventBroadcaster` (D-05) emits raw `OrchestratorEvent`s. The translation `OrchestratorEvent → VoiceOrchestratorEvent` lives either inside this adapter (with the adapter holding a child stream from the broadcaster) OR in a fourth broadcaster subscriber. Planner picks; the simpler shape is the latter — the adapter only handles its own submit/cancel calls; a separate `VoiceEventTranslator` task drains a broadcaster child-stream and yields onto `eventsCont`.

---

### `App/Voice/VoiceTTSAdapter.swift` (NEW — adapter, request-response)

**Role:** Bridge `Voice.VoiceTTSInterface` → the production `TTSEngineActor` (Phase 6 lands the type; Phase 9 wires it).

**Closest analog:** `App/Voice/NullVoiceAdapters.swift:41-51` (current placeholder shape) + `App/AppDelegate.swift:1097-1120` (App-target adapter pattern).

**Imports pattern:**
```swift
import Foundation
import Voice
// Phase 6's TTSEngineActor home — confirm package name during planning
// (likely `Voice` itself or a sub-package like `JarvisTTS`).
```

**Adapter shape:**
```swift
actor VoiceTTSAdapter: VoiceTTSInterface {
    private let engine: TTSEngineActor

    init(engine: TTSEngineActor) {
        self.engine = engine
    }

    var hasSynthInFlight: Bool {
        get async { await engine.isActivelySynthesizing }
    }

    func synthesize(_ text: String) async {
        // Tier resolution: tier-2 (Orpheus) when feature flag enabled, else tier-1
        // (AVSpeechSynthesizer). Phase 6's TTSEngineActor exposes a unified
        // synthesize(_:tier:voice:) entry; Phase 9 reads the flag from
        // PerTurnSnapshot before calling.
        await engine.synthesize(text, tier: resolvedTier(), voice: nil)
    }

    func cancelTTS() async {
        await engine.cancel()
    }

    private func resolvedTier() async -> TTSTier { /* read PerTurnSnapshot */ }
}
```

**Note for planner:** the comments at `App/Voice/NullVoiceAdapters.swift:44-50` document the exact target methods (`TTSEngineActor.synthesize(_:tier:voice:)` and `TTSEngineActor.cancel()`) — copy those signatures verbatim if Phase 6 surfaces them.

---

### `App/Voice/VoiceBusEmitterAdapter.swift` (NEW — adapter, streaming)

**Role:** Bridge `Voice.BusOutboundEmitter` → `Bus.OutboundBatcher.postAudio(_:)` so 30 Hz RMS values flow through the existing 02-03 batcher to the webview's `RingMesh.audioLevel` uniform.

**Closest analog:** `App/AppDelegate.swift:1128-1132` — current `NullBusEmitterAdapter` (struct, no-op).

**Imports pattern:**
```swift
import Foundation
import Voice
import Bus  // OutboundBatcher
```

**Adapter shape** (mirror the current placeholder; struct-with-strong-ref since `OutboundBatcher` is an actor):
```swift
struct VoiceBusEmitterAdapter: BusOutboundEmitter {
    let batcher: OutboundBatcher  // actor reference, Sendable

    func postAudio(_ rms: Float) async {
        await batcher.postAudio(rms)
    }
}
```

**Why a struct, not a class:** The current `NullBusEmitterAdapter` is a struct (line 1128). `OutboundBatcher` is an actor and Sendable; the adapter has no mutable state. Match the existing shape exactly — no `@MainActor`, no `@unchecked Sendable`.

---

### `OrchestratorEventBroadcaster.swift` (NEW — actor, fan-out, ~80 LOC)

**Role:** Single drainer of `AgentOrchestrator.events` (a `BoundedAsyncChannel<OrchestratorEvent>`). Re-emits each event onto N child streams (memory subscriber, dev-overlay subscriber, frame-attach release subscriber, voice-event translator). Per-consumer bounded queue with **drop-oldest** policy (D-06), with **priority filter** so `.turnEnd / .toolCardUpdate(running|completed|failed) / .error` are NEVER dropped on the memory subscriber regardless of buffer state (D-07). Lives for app lifetime, owned by `AppDelegate` (D-08).

**Package home** (planner confirms via VISION-03 / SPM-graph audit): likely a NEW lightweight package `packages/AgentEventBus/` with `import AgentCore + import AgentOrchestrator`. The App target imports this package and constructs the broadcaster in `installAgent()`. Co-locating in `AgentOrchestrator/` itself is also viable; the broadcaster only depends on `BoundedAsyncChannel<OrchestratorEvent>` and `AsyncStream<OrchestratorEvent>` — both already in scope there.

**Closest analog 1** (subscribe-to-channel pattern): `packages/AgentCore/Sources/AgentOrchestrator/DevSnapshotEmitter.swift:71-81` — `subscribe(to:)`:
```swift
public func subscribe(to events: BoundedAsyncChannel<OrchestratorEvent>) {
    subscriberTask?.cancel()
    let task = Task { [weak self] in
        for await event in events {
            if Task.isCancelled { break }
            guard let self = self else { break }
            await self.apply(event)
        }
    }
    subscriberTask = task
}
```
**Copy shape verbatim** for the broadcaster's drain Task. Key idioms: `subscriberTask?.cancel()` for idempotent re-subscription, `[weak self]` capture, `Task.isCancelled` early exit, `guard let self else break`.

**Closest analog 2** (drop-oldest with priority-filter exception): `packages/Replay/Sources/Replay/TokenDeltaDropOldestChannel.swift:58-92` — the `send(_:)` actor method with the per-element drop policy:
```swift
public func send(_ element: Element) async {
    while true {
        guard !finished else { return }
        if let waiter = pendingReceive { … }
        if buffer.count < capacity { buffer.append(element); return }

        // Overflow: drop oldest dropTag-eligible element.
        if element.tag == dropTag,
           let idx = buffer.firstIndex(where: { $0.tag == dropTag }) {
            buffer.remove(at: idx)
            buffer.append(element)
            return
        }
        // Saturated with protected elements — suspend.
        await withCheckedContinuation { (cont: …) in pendingSends.append(cont) }
    }
}
```
**Adapt for the broadcaster:** each child consumer holds a per-consumer `[OrchestratorEvent]` ring (default capacity 256, planner tunes per consumer per CONTEXT.md "Claude's Discretion"). On overflow, drop the oldest event whose `eventClass == .lossy` (where `.lossy` = `.tokenDelta` or `.thinkingDelta`). If buffer is saturated with non-lossy events, the broadcaster's per-consumer push **falls back** to one of two modes (planner picks):
- (a) drop the new event anyway (degrade non-memory consumers' invariant when memory is saturated with non-lossy);
- (b) suspend the broadcaster's drain (couples consumers — exactly what D-06 forbids); → **NOT allowed**.

The clean answer: per-consumer overflow always drops the oldest event of that consumer's class, even if that violates D-07 for non-memory consumers. D-07 only protects MEMORY's invariant. Other consumers (DevOverlay, frame-attach) tolerate loss.

**Recommended actor shape:**
```swift
public actor OrchestratorEventBroadcaster {
    public struct Subscription: Sendable {
        public let stream: AsyncStream<OrchestratorEvent>
        let id: UUID
    }

    public enum Priority: Sendable {
        case memory       // .turnEnd / .toolCardUpdate / .error never dropped
        case devOverlay   // all events lossy on overflow
        case frameAttach  // .turnEnd never dropped (needs to fire onAssistantTurnComplete)
        case voice        // .turnEnd / .error never dropped
    }

    private let upstream: BoundedAsyncChannel<OrchestratorEvent>
    private var subscribers: [Subscriber] = []
    private var drainTask: Task<Void, Never>?

    private struct Subscriber {
        let id: UUID
        let priority: Priority
        let capacity: Int
        let cont: AsyncStream<OrchestratorEvent>.Continuation
        var buffer: [OrchestratorEvent]
    }

    public init(upstream: BoundedAsyncChannel<OrchestratorEvent>) {
        self.upstream = upstream
    }

    public func start() {
        drainTask?.cancel()
        drainTask = Task { [weak self] in
            guard let self else { return }
            for await event in await self.upstream {
                if Task.isCancelled { break }
                await self.fanOut(event)
            }
        }
    }

    public func subscribe(priority: Priority, capacity: Int = 256) -> Subscription {
        let (stream, cont) = AsyncStream<OrchestratorEvent>.makeStream(
            bufferingPolicy: .unbounded   // we manage backpressure ourselves
        )
        let id = UUID()
        subscribers.append(Subscriber(
            id: id, priority: priority, capacity: capacity,
            cont: cont, buffer: []
        ))
        return Subscription(stream: stream, id: id)
    }

    private func fanOut(_ event: OrchestratorEvent) {
        for i in subscribers.indices {
            push(event, to: &subscribers[i])
        }
    }

    private func push(_ event: OrchestratorEvent, to sub: inout Subscriber) {
        if sub.buffer.count < sub.capacity {
            sub.buffer.append(event)
            sub.cont.yield(event)  // continuation buffer is unbounded; we cap our internal mirror
            return
        }
        // Overflow — drop-oldest of the lossy class for this priority.
        let isProtected = isProtectedForPriority(event, priority: sub.priority)
        if isProtected {
            // D-07: always emit, even on overflow. Tradeoff: this consumer's
            // ring will lag behind real time. Acceptable per D-06 ("isolates a
            // stuck consumer from blocking everyone else").
            sub.buffer.append(event)
            sub.cont.yield(event)
            return
        }
        // Non-protected: drop oldest non-protected.
        if let idx = sub.buffer.firstIndex(where: {
            !isProtectedForPriority($0, priority: sub.priority)
        }) {
            sub.buffer.remove(at: idx)
            sub.buffer.append(event)
            sub.cont.yield(event)
        }
        // else: buffer is fully protected; drop the new non-protected event silently.
    }

    private func isProtectedForPriority(_ event: OrchestratorEvent, priority: Priority) -> Bool {
        switch priority {
        case .memory:
            // D-07: only .tokenDelta and .thinkingDelta are eligible for drop.
            switch event {
            case .tokenDelta, .thinkingDelta: return false
            default: return true
            }
        case .devOverlay:
            return false  // all events lossy
        case .frameAttach:
            if case .turnEnd = event { return true }
            return false
        case .voice:
            switch event {
            case .turnEnd, .error: return true
            default: return false
            }
        }
    }
}
```

**Tests** (new target `OrchestratorEventBroadcasterTests`):
- Fan-out: 3 subscribers receive the same event in order.
- Drop-oldest: saturate one consumer's buffer with `.tokenDelta`s, push another `.tokenDelta` → oldest dropped, others advance.
- Priority filter (D-07): saturate memory subscriber's buffer with `.tokenDelta`s, then send `.turnEnd` → `.turnEnd` is enqueued (capacity exceeded for that consumer, but protected event always wins).
- Stuck consumer isolation (D-06): freeze one consumer's iterator, send 1000 events upstream; other consumers advance freely (the broadcaster's drain Task does NOT block).

---

### `PresenceStateSnapshot.swift` (NEW — actor, ~30 LOC)

**Role:** Stores the latest `PresenceEvent` + observation timestamp. `ContextBuilder.installPresence` becomes a real implementation that writes to this snapshot. `AgentOrchestrator.runTurn` reads `await presenceSnapshot?.currentEnrichment()` while building the system prompt.

**Closest analog:** `packages/Vision/Sources/Vision/PresenceMonitor.swift` (an actor that consumes a frame stream and produces `PresenceEvent`s). The new snapshot is the simpler dual: an actor that consumes `PresenceEvent`s and surfaces a string.

**Package home** (per CONTEXT.md): subject to the VISION-03 boundary script. Packages under consideration:
- `packages/Vision/` — natural home for presence-derived state. Already imports `PresenceEvent`. **Risk:** no current Vision code path references `AgentOrchestrator`; VISION-03 is preserved if `PresenceStateSnapshot` returns only a `String?` (never an event ID, never an orchestrator-side type).
- `packages/AgentCore/Sources/AgentOrchestrator/` — co-locates with the consumer. Requires Vision to be a dep of AgentOrchestrator OR the snapshot to consume an `AsyncSequence` generic (no `import Vision`).
- New `packages/PresenceContext/` — clean separation. Adds a package; planner weighs SPM-graph cost.

Recommended: **`packages/Vision/Sources/Vision/PresenceStateSnapshot.swift`**. Vision already exposes `ContextBuilder` (07-05); the snapshot is the missing piece of D-13's public surface. Returns `String?` only.

**Recommended actor shape:**
```swift
public actor PresenceStateSnapshot {
    public static let shared = PresenceStateSnapshot()  // process-wide, like PresenceMonitor.bus

    private var latest: PresenceEvent?
    private var observedAt: Date?

    public init() {}

    public func record(_ event: PresenceEvent) {
        latest = event
        observedAt = Date()
    }

    /// D-14: returns a literal sentence to append to the system prompt.
    /// Suppress when state is `.present` AND last-seen < 5 seconds (avoid
    /// noise on every turn). Returns nil → caller skips injection entirely.
    public func currentEnrichment(now: Date = Date()) -> String? {
        guard let observedAt, case let .transition(to: presence, _, _) = latest else {
            return nil
        }
        let age = now.timeIntervalSince(observedAt)
        switch presence {
        case .present where age < 5:                            return nil
        case .present:                                          return "User is at the desk."
        case .absent(let since):
            let mins = Int(now.timeIntervalSince(since) / 60)
            return mins >= 5 ? "User has been away from the desk for \(mins) minutes." : nil
        case .absentLongTerm(let since):
            let mins = Int(now.timeIntervalSince(since) / 60)
            return "User has been away from the desk for \(mins) minutes."
        case .unknown:                                           return nil
        }
    }
}
```

**`ContextBuilder.installPresence` body change** (replace lines 47-56 of `packages/Vision/Sources/Vision/ContextBuilder.swift`). Current:
```swift
public static func installPresence(_ stream: AsyncStream<PresenceEvent>) {
    Task.detached {
        for await _ in stream {
            // 07-06 deferred wiring: ...
        }
    }
}
```
**New:**
```swift
public static func installPresence(_ stream: AsyncStream<PresenceEvent>) {
    Task.detached {
        for await event in stream {
            await PresenceStateSnapshot.shared.record(event)
        }
    }
}
```

**`AgentOrchestrator.runTurn` consumption** (insert into line 162-167 area where the system prompt is composed):
```swift
let composedSystem = UntrustedWrapper.composeSystemPrompt(base: systemPrompt, nonce: nonce)
let presenceLine = await presenceSnapshot?.currentEnrichment()
let finalSystem = presenceLine.map { "\(composedSystem)\n\n\($0)" } ?? composedSystem
let initialMessages: [LLMMessage] = [
    LLMMessage(role: .system, content: [.text(finalSystem)]),
    LLMMessage(role: .user, content: [.text(input.userText)]),
]
```

**Constructor injection on `AgentOrchestrator`** — add an optional dep alongside `visionRouter`:
```swift
public init(
    configStore: ConfigStore,
    providerFactory: @escaping @Sendable (ProviderSelection) async throws -> any LLMProvider,
    toolDispatcher: any ToolDispatcher,
    replayLog: ReplayLog,
    sessionId: SessionID,
    systemPrompt: String,
    availableTools: [ToolSchema] = [],
    visionRouter: VisionRouter? = nil,           // D-01 (NEW)
    presenceSnapshot: PresenceStateSnapshot? = nil // D-13 (NEW)
) { … }
```

**Why optional, not required:** `AgentOrchestratorTests` and the harness must keep working without Vision. Defaulting to `nil` preserves Phase 4's test ergonomics (the orchestrator currently has 8 ctor args without these two; adding required args breaks ~30 test sites).

---

### `App/AppDelegate.swift` — `installAgent()` NEW METHOD

**Role:** Bootstrap the orchestrator + broadcaster + voice/memory/vision wiring closures. Mirrors the six-step pattern of `installVoice()` / `installMemory()` / `installVision()`.

**Closest analog:** `App/AppDelegate.swift:561-635` — `installMemory()`. Six numbered steps, graceful-degradation via `systemLogger?.warning(...) + early return`, strong properties retained on AppDelegate.

**`installMemory()` template excerpt** (the six-step pattern, copy to `installAgent()`):
```swift
@MainActor
private func installMemory() async {
    // 1. DB URL.
    let dbURL = configFileURL().deletingLastPathComponent()
        .appendingPathComponent("jarvis.db")

    // 2. MemoryStore.
    let store: MemoryStore
    do {
        store = try MemoryStore(databaseURL: dbURL)
    } catch {
        systemLogger?.warning("installMemory: store init failed (...)")
        return
    }
    memoryStore = store

    // 3. Wire the replay sink.
    if let log = replayLog {
        await store.setReplayLog(AppDelegateMemoryReplaySink(replayLog: log))
    } else { ... }

    // 4. MemoryExtractor on OllamaProvider.
    let extractorProvider = OllamaProvider(baseURL: ...)
    let extractor = MemoryExtractor(provider: extractorProvider)

    // 5. Background orchestrator. Held strongly; start() spawns drain.
    let memoryOrch = MemoryExtractionOrchestrator(extractor: extractor, applyOp: ...)
    await memoryOrch.start()
    memoryExtractionOrchestrator = memoryOrch

    // 6. Coordinator wiring — subscribe to AgentOrchestrator.events.
    let coord = MemoryExtractionCoordinator(memoryOrchestrator: memoryOrch)
    memoryExtractionCoordinator = coord
    if let events = self.agentOrchestratorEvents() {
        await coord.start(orchestratorEvents: events, turnContent: { _ in nil })
    }
}
```

**`installAgent()` recommended shape** (insert in `applicationWillFinishLaunching` between step 10 (MCP runtime build) and step 11 (memory install) — or fold step 10 into installAgent so the dispatcher is constructed adjacent to the orchestrator):

```swift
@MainActor
private func installAgent() async {
    // 1. Required deps from earlier installs. Bail early if any missing.
    guard let mcpRuntime = self.mcpRuntime,
          let replayLog = self.replayLog,
          let configStore = self.configStore else {
        systemLogger?.warning("installAgent: deps not ready (mcp/replay/config)")
        return
    }

    // 2. Provider factory closure — closes over Keychain + ConfigStore.
    let keychainStoreLocal = self.keychainStore
    let providerFactory: @Sendable (ProviderSelection) async throws -> any LLMProvider = {
        selection in
        switch selection {
        case .anthropic:
            return AnthropicProvider(apiKeyProvider: { [keychainStoreLocal] in
                (try? keychainStoreLocal.get(.anthropic)) ?? ""
            })
        case .ollama:
            return OllamaProvider(baseURL: URL(string: "http://127.0.0.1:11434")!)
        }
    }

    // 3. Construct the orchestrator with the new optional deps.
    //    visionRouter + presenceSnapshot may not be ready yet (visionInstallTask
    //    runs in parallel); pass nil now and inject later — OR sequence
    //    installAgent AFTER installVision. CONTEXT D-01 implies the latter.
    let orchestrator = AgentOrchestrator(
        configStore: configStore,
        providerFactory: providerFactory,
        toolDispatcher: mcpRuntime.dispatcher,
        replayLog: replayLog,
        sessionId: SessionID.fresh(),
        systemPrompt: defaultSystemPrompt,
        availableTools: await mcpRuntime.client.registeredToolSchemas(),
        visionRouter: self.visionRouter,
        presenceSnapshot: PresenceStateSnapshot.shared
    )
    self.agentOrchestrator = orchestrator

    // 4. Construct the broadcaster around the orchestrator's events channel.
    //    Held strongly — drain Task lives for app lifetime (D-08).
    let broadcaster = OrchestratorEventBroadcaster(upstream: orchestrator.events)
    await broadcaster.start()
    self.eventBroadcaster = broadcaster

    // 5. Wire each consumer to its child stream.
    //    5a. Memory subscriber (D-07: protected events).
    let memorySub = await broadcaster.subscribe(priority: .memory, capacity: 256)
    if let coord = self.memoryExtractionCoordinator {
        await coord.start(
            orchestratorEvents: memorySub.stream,  // see signature change below
            turnContent: { [weak self] turnId in
                await self?.lookupTurnContent(turnId)
            }
        )
    }

    //    5b. DevOverlay subscriber (all events lossy).
    let devSub = await broadcaster.subscribe(priority: .devOverlay, capacity: 32)
    await devSnapshotEmitter.subscribe(to: devSub.stream)

    //    5c. Frame-attach release subscriber.
    let frameSub = await broadcaster.subscribe(priority: .frameAttach, capacity: 64)
    self.frameAttachReleaseTask = Task {
        for await event in frameSub.stream {
            if case .turnEnd(let turnId, _) = event,
               await self.turnHadImage(turnId) {
                await self.frameAttachController?.onAssistantTurnComplete()
            }
        }
    }

    //    5d. Voice event translator subscriber (feeds VoiceOrchestratorAdapter).
    let voiceSub = await broadcaster.subscribe(priority: .voice, capacity: 64)
    // Wire to VoiceOrchestratorAdapter.eventsCont — see VoiceOrchestratorAdapter design.

    systemLogger?.info("installAgent: AgentOrchestrator + broadcaster wired")
}
```

**Signature change required on `MemoryExtractionCoordinator.start(...)`:**
Current (line 32-35 of `MemoryExtractionCoordinator.swift`):
```swift
public func start(
    orchestratorEvents: BoundedAsyncChannel<OrchestratorEvent>,
    turnContent: @escaping TurnContentLookup
)
```
The broadcaster emits `AsyncStream<OrchestratorEvent>`, not `BoundedAsyncChannel<OrchestratorEvent>`. **Two options:**
- (a) Change the `start(...)` parameter to a generic `AsyncSequence` — keeps the coordinator agnostic.
- (b) Have the broadcaster expose a `BoundedAsyncChannel`-typed subscription. Match the existing memory ctor.

Recommended: (a) — generic `AsyncSequence`. Matches `HudStateCoordinator.attachPresence<S: AsyncSequence>(_)` shape from `App/HUD/HudStateCoordinator.swift:135-138`:
```swift
public func attachPresence<S: AsyncSequence & Sendable>(_ stream: S)
    where S.Element: Sendable
```
Translates to:
```swift
public func start<S: AsyncSequence & Sendable>(
    orchestratorEvents: S,
    turnContent: @escaping TurnContentLookup
) where S.Element == OrchestratorEvent
```

**Replace placeholder `agentOrchestratorEvents()` at lines 641-646.** Body becomes:
```swift
private func agentOrchestratorEvents() -> AgentOrchestrator? {
    return self.agentOrchestrator
}
```
…and the call site in `installMemory()` (line 622) becomes a broadcaster-subscribe call rather than a direct reference. Per D-08, the broadcaster owns the events channel; memory should subscribe via `broadcaster.subscribe(priority: .memory)`.

---

### `App/AppDelegate.swift` — Bus inbound handler additions

**Role:** Handle `chatSubmit` / `chatCancelAndSubmit` / `frameAttachRequested` from the webview (D-12, D-15). Emit `submitRejected` outbound on rejection (D-10).

**Closest analog:** `packages/Bus/Sources/Bus/WebviewBridge.swift:68` — `public var onInbound: (@MainActor (BusInbound) async throws -> BusReply?)?`. Currently AppDelegate does NOT install an inbound handler (line 209 of WebviewBridge consumes `onInbound` — search shows it's nil-defaulted in `installBus()` at AppDelegate line 845-915). Phase 9 introduces the first non-handshake inbound handler.

**BusInbound enum extension required** (in `packages/Bus/Sources/Bus/BusInbound.swift`, current at lines 10-13):
```swift
public enum BusInbound: Equatable, Sendable {
    case helloAck(version: String)
    case uiReady
    // Phase 9 additions:
    case chatSubmit(text: String)                  // D-12
    case chatCancelAndSubmit(text: String)         // D-12
    case frameAttachRequested                      // D-15
}
```
Add Discriminator + decode/encode arms. Mirror the existing exhaustive-switch shape (lines 15-49) — NO default branch.

**BusOutbound enum extension** (for `submitRejected` toast — D-10):
```swift
case submitRejected(reason: String)  // text-path symmetric with voice-path banner
```

**`BUS_PROTOCOL_VERSION` bump** required (per CONTEXT.md "Integration Points"). The handshake check at `WebviewBridge` enforces strict equality; missing the bump → silent JS clients get refused.

**Handler installation in `installBus()`** (insert near line 892 where `onHandshakeArmed` is set):
```swift
bridge.onInbound = { [weak self] inbound async throws -> BusReply? in
    guard let self else { return nil }
    switch inbound {
    case .helloAck, .uiReady:
        return nil  // handshake handled inside WebviewBridge

    case .chatSubmit(let text):
        await self.handleChatSubmit(text)
        return .ok

    case .chatCancelAndSubmit(let text):
        await self.handleChatCancelAndSubmit(text)
        return .ok

    case .frameAttachRequested:
        await self.frameAttachController?.requestAttach(reason: .hudButton)
        return .ok
    }
}
```

**Handler bodies** — direct calls to orchestrator (D-12 cardinal):
```swift
private func handleChatSubmit(_ text: String) async {
    guard let orch = agentOrchestrator else { return }

    // D-15 phrase trigger before submit so frame can be attached.
    let cb = ContextBuilder()
    if cb.matchesFrameAttachPhrase(text), let fac = frameAttachController {
        await fac.requestAttach(reason: .phraseDetected(in: text))
        // The HUD confirmation flow is responsible for follow-up;
        // for the no-phrase path, fall through to direct submit.
        // Planner picks: gate the submit on user confirmation, OR
        // submit text-only and let the user re-issue with image.
    }

    let outcome = await orch.submit(.text(text))
    await handleTextOutcome(outcome)
}

private func handleChatCancelAndSubmit(_ text: String) async {
    guard let orch = agentOrchestrator else { return }
    let outcome = await orch.cancelAndSubmit(.text(text))
    await handleTextOutcome(outcome)
}

private func handleTextOutcome(_ outcome: SubmitOutcome) async {
    switch outcome {
    case .ran, .superseded:
        return
    case .rejected(let reason):
        // D-10 text path: Bus toast (chat-panel surface), NOT banner.
        let body = bodyForReason(reason)
        try? await webviewBridge?.send(.submitRejected(reason: body))
    }
}
```

---

### `AgentOrchestrator.runTurn` — vision branch (D-01, D-02, D-03)

**Role:** Pre-turn provider swap when `TurnInput.images.isEmpty == false`. After `messageStop`, post-response evaluation may escalate T1→T2 with same `turnId`.

**Modification site:** `packages/AgentCore/Sources/AgentOrchestrator/AgentOrchestrator.swift:115-190` — `runTurn(input:retryOf:supersededPrior:)`. Insert the vision branch between the existing `provider = try await providerFactory(...)` line (124-126) and the `replayLog.startTurn` call (137-150).

**Pattern to insert** (mirrors the existing `do { provider = try await providerFactory(...) } catch { return .rejected(reason: .providerUnavailable) }` shape at lines 124-133):

```swift
// D-01: image-bearing turn → swap provider via VisionRouter before runTurnLoop.
//       The existing providerFactory(...) result is shadowed when images are
//       present. T2 reached only via post-response escalation (see runTurnLoop).
var provider: any LLMProvider
do {
    provider = try await providerFactory(perTurn.resolvedProvider)
} catch {
    return .rejected(reason: .providerUnavailable)
}

if !input.images.isEmpty, let router = self.visionRouter {
    let firstImage = input.images[0]  // Phase 9 supports single-frame attach
    let cloudOptIn = ContextBuilder().matchesCloudOptIn(input.userText)
    let decision = await router.route(
        for: firstImage,
        prompt: input.userText,
        explicitCloudOptIn: cloudOptIn
    )
    provider = await router.providerForTier(decision.tier)
    // Stash decision on TurnExecution so runTurnLoop's post-response
    // hook can call evaluatePostResponse(...) for D-02 escalation.
}
```

**Post-response escalation** (D-02) — extend `runTurnLoop`'s `.endTurn` arm at line 338 to call `evaluatePostResponse`:
```swift
case .endTurn:
    if visionContext != nil {  // image-bearing turn
        let outcome = await visionRouter?.evaluatePostResponse(
            assistantTextSoFar,
            config: .default,
            t2Available: visionContext.t2Available
        )
        if outcome == .escalateToT2 {
            // Discard T1 response from model-facing history.
            // Swap to t2Provider. Re-stream. Same turnId.
            // Record `escalation_attempt` marker in replay (planner picks shape).
            currentProvider = await visionRouter!.providerForTier(.t2LocalQuality)
            messages = initialMessages  // discard T1's assistant message
            assistantTextSoFar = ""
            await replayLog.record(.escalationAttempt(.t1ToT2), for: currentTurnId)
            continue outer
        }
    }
    await events.send(.turnEnd(turnId: currentTurnId, stopReason: .endTurn))
    await replayLog.endTurn(currentTurnId, stopReason: "end_turn")
    await events.send(.stateChange(.idle))
    currentTurn = nil
    return
```

**Track `turnHadImage` for the broadcaster's frame-attach subscriber** (D-16): expose a way for the AppDelegate-side subscriber to ask "did this turn carry an image?" The cleanest addition: when `runTurn` sees `input.images.nonEmpty`, the orchestrator emits a sentinel event OR maintains an internal `imageBearingTurns: Set<TurnID>` cleared on `.turnEnd`. Planner picks; the actor-internal set is simpler since `turnEnd` is the only release.

---

### Bus message handlers — payload schema (D-10 Claude's discretion)

**Recommended payload field shape** (planner picks; this is the suggested baseline):

`BusInbound.chatSubmit`:
```json
{ "type": "chatSubmit", "text": "<user message>" }
```

`BusInbound.frameAttachRequested`:
```json
{ "type": "frameAttachRequested" }
```

`BusOutbound.submitRejected`:
```json
{ "type": "submitRejected", "reason": "Already thinking — wait or say cancel." }
```

The webview's chat panel renders `submitRejected` as a transient toast (Phase 3's chat-panel surface — `webview/packages/hud/src/components/Chat*.tsx`). Toast duration: 4 s; auto-dismiss; click to dismiss early.

---

## Shared Patterns

### S-1: App-Target Adapter

**Source:** `App/AppDelegate.swift:1097-1120` (`AppDelegateBannerAdapter`)
**Apply to:** `VoiceOrchestratorAdapter`, `VoiceTTSAdapter`, `VoiceBusEmitterAdapter`, any other Phase 9 adapter that bridges a package protocol to an App-target type.

**Pattern:**
```swift
final class XAdapter: ProtocolName, @unchecked Sendable {
    nonisolated(unsafe) private weak var coordinator: SomeMainActorRef?
    init(coordinator: SomeMainActorRef?) { self.coordinator = coordinator }

    func someMethod(...) {
        let coordinator = coordinator
        Task { @MainActor in
            coordinator?.someMethodOnMain(...)
        }
    }
}
```

When the target is an actor (not `@MainActor`), use `actor XAdapter: ProtocolName { ... }` — see `NullOrchestratorAdapter` at `App/Voice/NullVoiceAdapters.swift:20`. When the target is value-typed/Sendable, use `struct XAdapter: ProtocolName { ... }` — see `NullBusEmitterAdapter` at `App/AppDelegate.swift:1128`.

### S-2: Six-Step Install Function

**Source:** `App/AppDelegate.swift:462-537` (`installVoice()`), `:561-635` (`installMemory()`), `:666-748` (`installVision()`)
**Apply to:** New `installAgent()` function.

**Pattern:**
1. Required deps (early return + `systemLogger?.warning` on missing).
2. Construct primary type. Catch init throws → graceful degrade + return.
3. Wire dependent subsystems.
4. Construct secondary infrastructure.
5. Start background tasks.
6. Log success.

**Graceful-degradation cardinal:** every install function returns silently after a warning when a dep is unavailable. The app continues to launch with the affected subsystem dormant. **No `fatalError`, no `NSApp.terminate`** in install functions.

### S-3: Strong Property Lifetime

**Source:** `App/AppDelegate.swift:120-216` (every retained property: `orchToReplayChannel`, `replayLog`, `mcpRuntime`, `voiceController`, `memoryStore`, `memoryExtractionOrchestrator`, `memoryExtractionCoordinator`, `captureSession`, `presenceMonitor`, `presenceSignalBus`, `disablePresence`, `visionRouter`, `cameraDegradationTask`, etc.).
**Apply to:** New properties added by Phase 9 — `agentOrchestrator: AgentOrchestrator?`, `eventBroadcaster: OrchestratorEventBroadcaster?`, `frameAttachController: FrameAttachController?`, `frameAttachReleaseTask: Task<Void, Never>?`, `agentInstallTask: Task<Void, Never>?`.

**Pattern:** Hold strongly on AppDelegate; cancel tasks in `applicationWillTerminate`. The user-visible cardinal is "no subsystem deinits while the app is alive" — the broadcaster's drain Task in particular MUST live for the app's lifetime (D-08).

### S-4: Generic AsyncSequence at Package Boundaries

**Source:** `App/HUD/HudStateCoordinator.swift:135-138`:
```swift
public func attachPresence<S: AsyncSequence & Sendable>(_ stream: S)
    where S.Element: Sendable
```
**Apply to:** `MemoryExtractionCoordinator.start(...)` signature change (was `BoundedAsyncChannel<OrchestratorEvent>`, becomes generic `AsyncSequence` so the broadcaster's `AsyncStream<OrchestratorEvent>` plugs in directly without typecast).

**Why:** Lets the broadcaster choose its own internal channel type (AsyncStream is simpler than BoundedAsyncChannel for fan-out) without forcing every consumer to know about it.

### S-5: Single-Site Drain Task with weak self + isCancelled

**Source:** `packages/AgentCore/Sources/AgentOrchestrator/DevSnapshotEmitter.swift:71-81` (`subscribe(to:)`) + `App/AppDelegate.swift:673-682` (`cameraDegradationTask`).
**Apply to:** `OrchestratorEventBroadcaster.start()`'s drain Task; AppDelegate's `frameAttachReleaseTask`.

**Pattern:**
```swift
task = Task { [weak self] in
    for await event in stream {
        if Task.isCancelled { break }
        guard let self = self else { break }
        await self.handle(event)
    }
}
```

### S-6: SubmitOutcome Surface (D-10 cardinal)

**Source:** `packages/AgentCore/Sources/AgentOrchestrator/SubmitOutcome.swift:13-28`
**Apply to:** `VoiceOrchestratorAdapter.handleOutcome`, AppDelegate's `handleTextOutcome`.

**Cardinal:** never silently drop a `.rejected` outcome. Every code path that calls `submit(_:)` or `cancelAndSubmit(_:)` MUST consume the return value and surface rejections to the user — voice path → HUDBannerCoordinator (banner with id namespaced `voice-rejected-*`); text path → Bus toast (`submitRejected` outbound).

### S-7: Dual-Class Drop Policy with Priority Filter

**Source 1** (drop-oldest with class predicate): `packages/Replay/Sources/Replay/TokenDeltaDropOldestChannel.swift:58-92`
**Source 2** (per-event eligibility): D-07 priority-filter rule.
**Apply to:** `OrchestratorEventBroadcaster.push(_:to:)`.

**Pattern:** Each enqueue checks `isProtectedForPriority(event, priority: subscriber.priority)`. Protected events bypass the buffer cap (the consumer's ring may grow beyond `capacity` until it drains — bounded by upstream's own `capacity: 256` AGENT-10 channel, so worst case is 256 protected events buffered per consumer). Non-protected events drop oldest non-protected on overflow.

### S-8: Single-Emission-Site Grep Gate (consider for Phase 9)

**Source pattern:** `packages/Vision/Tests/VisionTests/FrameAttachDiscardSiteGrepTests.swift` (Phase 7); `scripts/check-presence-vision-isolation.sh` (Phase 7).
**Apply to:** Phase 9 should add an equivalent gate — `scripts/check-orchestrator-events-single-consumer.sh` (planner names) — that asserts:
1. `for await … in orchestrator.events` appears at exactly **one** call site in production code (the broadcaster's drain Task).
2. `agentOrchestratorEvents()` is called at exactly **one** call site (the broadcaster's subscribe-to-memory wiring in `installAgent`).

This freezes the broadcaster as the only consumer of the upstream channel.

---

## No Analog Found

None. Every file's role + flow has at least a strong analog elsewhere in the repo. The novelty in Phase 9 is composition (broadcaster fan-out + priority filter) — both halves of which exist independently (`DevSnapshotEmitter` + `TokenDeltaDropOldestChannel`) and are combined here.

---

## Highest-Risk Scaffolds (planner: spike-test before fanning out)

1. **`MemoryExtractionCoordinator.start(...)` signature change** (line 32-35). Touches Phase 7 tests — `MemoryExtractionOrchestratorTests` exercises this signature. Generic AsyncSequence change is source-compatible at call sites that pass `BoundedAsyncChannel<OrchestratorEvent>` (it conforms to AsyncSequence already), but the test file may use type annotations that break. Spike-test by changing the signature first, running `swift test --filter MemoryTests` before further work.

2. **`AgentOrchestrator` constructor signature change** (lines 59-77). Adding `visionRouter:` and `presenceSnapshot:` as defaulted-optional parameters is non-breaking, but ~30 test files construct the orchestrator manually. Verify by running `swift test --filter AgentOrchestratorTests` after the ctor change with no other code changes — should be zero diffs.

3. **`OrchestratorEventBroadcaster` priority-filter implementation.** D-07 says memory NEVER drops `.turnEnd / .toolCardUpdate(...) / .error`. The implementation must NOT couple consumers — a saturated memory consumer must not block fan-out to others. The recommended implementation lets memory's per-consumer buffer grow beyond `capacity` for protected events (bounded by upstream's 256-cap), accepting unbounded staleness for memory specifically. Verify by writing the stuck-consumer test FIRST.

4. **`installAgent()` ordering** vs `installVision()`. Per D-01, the orchestrator constructor takes `visionRouter: VisionRouter?`. If `installAgent` runs before `installVision` completes, `visionRouter` will be nil at construction time. Two resolutions:
   - (a) Make `installAgent` await `visionInstallTask?.value` first.
   - (b) Make `agentOrchestrator.visionRouter` settable post-init via a method (introduces mutable state on the actor).
   Recommended: **(a)** — sequential install, `installAgent` runs after `installMemory + installVision` complete. AppDelegate's `applicationWillFinishLaunching` already spawns the three install tasks (steps 11/12/13 at lines 387-405); add step 14 `agentInstallTask = Task { @MainActor in await self?.installAgent() }` AFTER awaiting the prior three.

5. **Vision escalation `escalation_attempt` marker shape** (D-02) — the planner picks JSON sidecar vs new `ReplayEvent.escalationAttempt` case. Adding a new `ReplayEvent` case touches the Phase 4 `ReplayEvent` enum + every exhaustive switch on it. JSON sidecar keeps the ReplayEvent surface stable but loses type-safety. Spike-test by counting exhaustive switches: `grep -rn "case .textDelta" packages/ | wc -l`. If > 5, prefer JSON sidecar.

---

## Metadata

**Analog search scope:** `App/`, `packages/AgentCore/`, `packages/AgentOrchestrator/`, `packages/Vision/`, `packages/Memory/`, `packages/Replay/`, `packages/Voice/`, `packages/Bus/`
**Files scanned:** ~120 (greenfield codebase; full survey)
**Pattern extraction date:** 2026-05-01
**Source materials:** 09-CONTEXT.md (D-01..D-16 LOCKED), STATE.md, ROADMAP.md §Phase 9; no RESEARCH.md (skip-research per orchestrator)
