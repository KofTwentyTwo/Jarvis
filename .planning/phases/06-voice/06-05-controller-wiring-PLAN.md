---
phase: 06-voice
plan: 05
type: execute
wave: 4
depends_on: [06-01, 06-02, 06-03, 06-04]
files_modified:
  - packages/Voice/Sources/Voice/VoiceController.swift
  - packages/Voice/Sources/Voice/VoiceState.swift
  - packages/Voice/Sources/Voice/Control/PushToTalk.swift
  - packages/Voice/Sources/Voice/Control/MuteWakeWord.swift
  - packages/Voice/Sources/Voice/Control/AudioLevelEmitter.swift
  - packages/Voice/Tests/VoiceTests/VoiceControllerTests.swift
  - packages/Voice/Tests/VoiceTests/BargeInTests.swift
  - packages/Voice/Tests/VoiceTests/MuteWakeWordTests.swift
  - packages/Voice/Tests/VoiceTests/PTTTests.swift
  - packages/Voice/Tests/VoiceTests/AECFallbackBannerTests.swift
  - App/AppDelegate.swift
  - App/MenuBar/MenuBarIconController.swift
  - App/Tests/AppTests/VoiceWiringTests.swift
  - .planning/phases/06-voice/06-HUMAN-UAT.md
autonomous: false
requirements: [VOICE-07, VOICE-09, VOICE-12, VOICE-13, VOICE-14]
tags: [voice, controller, barge-in, push-to-talk, mute-wake-word, hud-banner, end-to-end, app-wiring, human-uat]
assumptions:
  - Plans 06-01..06-04 have shipped: AudioGraphOwner, WakeWordDAG, SileroVAD + STTProvider + STTBackendSelector, TTSEngineActor + InterruptSequence are all available.
  - Phase 4 AgentOrchestrator's `submit` and `cancelAndSubmit` are the ONLY turn-lifecycle entry points (per 04-04-SUMMARY); voice routes through them like text. `TurnInput.voice(_:)` is already defined.
  - Phase 1 HotkeyBinder + InputMonitoringProbe + ShortcutRecorder infrastructure is live; PTT gets a second hotkey binding alongside the summon hotkey.
  - Phase 1 menu-bar item `MenuBarIconController` is live; mute-wake-word adds a toggleable item.
  - Phase 3 HUD `HudStateCoordinator` consumes `VoiceHudIntent` from the dormant `voiceStream` continuation that AppDelegate holds; this plan replaces that placeholder with a real producer.
  - Phase 1 banner infrastructure (`HUDBannerCoordinator`) is live; the AEC-off banner reuses it (no new banner widget).
  - The Bus schema's `audioLevel(rms: Float)` case is already in place from Phase 2; Plan 03-03 RingMesh's listening pulse expects RMS values. This plan wires the producer (`AudioLevelEmitter`) — not adding a new case.
  - This plan is Wave 4: depends on all earlier waves. Has a HUMAN-UAT checkpoint because end-to-end voice is a sensory experience that no automated test can fully verify (audio quality, latency feel, ring-state visual correctness).
  - Anti-pattern callouts: DO NOT route barge-in through two actor hops — single `cancelAndSubmit` call (VOICE-14). DO NOT extend the Bus schema (audioLevel exists from Phase 2). DO NOT use a webview modal for the AEC-off banner — reuse Phase 1's HUDBannerCoordinator (modal-lint enforces this — Phase 5 SUMMARY). DO NOT make muting wake-word disable PTT — they are independent (VOICE-12 explicit contract). DO NOT use Carbon `RegisterEventHotKey` for PTT — `NSEvent.addGlobalMonitorForEvents` per Phase 1 pattern.
must_haves:
  truths:
    - "An end-to-end voice turn — wake word fires → VAD speech-start → STT streams partial → STT final → orchestrator.submit → TTS speaks — completes without panics, with HUD ring transitioning idle → listening → thinking → speaking and back to idle."
    - "Barge-in: when wake-word fires during `.speaking`, the VoiceController calls `orchestrator.cancelAndSubmit(_:)` EXACTLY ONCE — proven by a test counter; the TTS interrupt sequence runs as part of `cancelAndSubmit`'s teardown, and the new turn starts with HUD = `.listening`."
    - "Push-to-talk: holding the bound PTT hotkey activates STT directly (bypasses wake-word DAG); releasing finalizes the transcript and submits as a voice turn. PTT works even when wake-word is muted (VOICE-12 contract)."
    - "Mute-wake-word: toggling the menu-bar item pauses the wake-word DAG (no consumption from RingBuffer); PTT remains armed; menu-bar icon reflects the muted state. Persistence via UserDefaults survives app restart."
    - "AEC-off banner: when `AudioGraphOwner.degradationStream` emits `.aecUnavailable`, the HUDBannerCoordinator displays \"AEC unavailable; degraded-mode active\" via the existing native banner (no webview modal). Banner persists until next AEC-on rebuild."
    - "Audio-level RMS computed from the RingBuffer is emitted to the bus as `BusOutbound.audioLevel(rms:)` at ~30 Hz during `.listening` state — drives Plan 03-03 RingMesh's listening pulse with REAL audio (replacing the fake sine)."
    - "AppDelegate wires VoiceController into the dormant `voiceStream` continuation that HudStateCoordinator's three-subscriber pattern already holds; AppDelegate also wires PTT hotkey + menu-bar mute item."
  artifacts:
    - path: "packages/Voice/Sources/Voice/VoiceController.swift"
      provides: "Public actor coordinating wake-word + VAD + STT + TTS into a state machine; routes barge-in through `cancelAndSubmit`; exposes `voiceHudIntentStream`."
      min_lines: 200
    - path: "packages/Voice/Sources/Voice/VoiceState.swift"
      provides: "State machine: `.idle | .listening(source) | .thinking | .speaking | .reconfiguring(reason)` + transition diagram."
      min_lines: 40
    - path: "packages/Voice/Sources/Voice/Control/PushToTalk.swift"
      provides: "PTT hotkey binding via NSEvent.addGlobalMonitorForEvents; emits `.pttDown` / `.pttUp` events into VoiceController."
      min_lines: 80
    - path: "packages/Voice/Sources/Voice/Control/MuteWakeWord.swift"
      provides: "MenuBar toggle wrapper; UserDefaults persistence; routes to `VoiceController.muteWakeWord()` / `unmuteWakeWord()`."
      min_lines: 60
    - path: "packages/Voice/Sources/Voice/Control/AudioLevelEmitter.swift"
      provides: "Reads RingBuffer in parallel with VAD; computes RMS over 100 ms windows; emits `BusOutbound.audioLevel(rms:)` at ~30 Hz."
      min_lines: 60
    - path: "App/AppDelegate.swift"
      provides: "Production wiring: instantiate AudioGraphOwner / WakeWordDAG / SileroVAD / STT selector / TTSEngineActor / VoiceController / PTT / MuteWakeWord; replace dormant voiceStream with real producer."
    - path: ".planning/phases/06-voice/06-HUMAN-UAT.md"
      provides: "Manual end-to-end checklist for the user to verify the full voice loop on a physical Mac."
      contains: "Hey Jarvis, what time is it"
  key_links:
    - from: "packages/Voice/Sources/Voice/VoiceController.swift"
      to: "AgentOrchestrator.cancelAndSubmit"
      via: "single barge-in call site (NOT two actor hops)"
      pattern: "cancelAndSubmit"
    - from: "packages/Voice/Sources/Voice/Control/AudioLevelEmitter.swift"
      to: "BusOutbound.audioLevel"
      via: "30 Hz RMS emission during .listening"
      pattern: "BusOutbound\\.audioLevel"
    - from: "App/AppDelegate.swift"
      to: "dormantVoiceContinuation"
      via: "VoiceController.voiceHudIntentStream replaces the dormant placeholder"
      pattern: "dormantVoiceContinuation"
    - from: "packages/Voice/Sources/Voice/VoiceController.swift"
      to: "InterruptSequence.run"
      via: "called as part of cancelAndSubmit's TTS-stop path"
      pattern: "InterruptSequence\\.run"
    - from: "packages/Voice/Sources/Voice/VoiceController.swift"
      to: "AudioGraphOwner.degradationStream"
      via: "consumes .aecUnavailable → forwards to HUDBannerCoordinator"
      pattern: "degradationStream"
---

<objective>
Close Phase 6 by wiring all five subsystems (Plan 06-01 AudioGraph + 06-02 WakeWord + 06-03 VAD/STT + 06-04 TTS + Phase 4 AgentOrchestrator + Phase 3 HudStateCoordinator) into one `VoiceController` actor that runs the end-to-end loop, plus PTT + mute-wake-word + AEC-off banner + the audio-level emitter that finally drives Plan 03-03's listening pulse with real RMS.

Five locked invariants:

1. **VOICE-07 — End-to-end happy path.** "Hey Jarvis, what time is it?" → wake-word fires → VAD speech-start → SpeechAnalyzer streams "what time is it" → VAD speech-end → orchestrator submits → tool-call get_time → Opus produces "It's 2:47 PM" → Orpheus speaks. HUD transitions: idle → listening → thinking → speaking → idle. **Manual UAT checkpoint** verifies the experience on the user's Mac.
2. **VOICE-09 — AEC-off banner.** Reuses Phase 1 `HUDBannerCoordinator`. When `AudioGraphOwner.degradationStream` yields `.aecUnavailable`, the banner shows "AEC unavailable; degraded-mode active". Native AppKit only — modal-lint (Phase 5) enforces no webview modal.
3. **VOICE-12 — Mute wake word, PTT armed.** Menu-bar toggle pauses `WakeWordDAG.pause()`; PTT hotkey path explicitly remains active. UserDefaults persists across launches.
4. **VOICE-13 — Push-to-talk.** Hold a bound hotkey: STT activates directly (bypasses wake-word). On release, STT finalizes + submits. Reuses Phase 1's `NSEvent.addGlobalMonitorForEvents` path (not Carbon).
5. **VOICE-14 — Atomic barge-in via single `cancelAndSubmit`.** A unit test asserts EXACTLY ONE `cancelAndSubmit` call per barge-in. The TTS interrupt sequence (Plan 06-04) runs inside `cancelAndSubmit`'s teardown, not as a separate hop. HUD re-enters `.listening` cleanly without losing turn state.

Plus the audio-level wiring: `AudioLevelEmitter` reads the RingBuffer in parallel with VAD, computes RMS at 30 Hz, emits `BusOutbound.audioLevel(rms:)` — replacing Plan 03-03's fake-sine listening pulse with real audio reactivity.

This plan has a HUMAN-UAT checkpoint because end-to-end voice is a sensory experience: ring-pulse correctness, audio quality, barge-in feel, latency, and confidence under realistic conditions cannot be verified by `swift test`.

Output: `VoiceController` + PTT + MuteWakeWord + AudioLevelEmitter + AppDelegate wiring + UAT checklist + a battery of unit tests for the deterministic parts.
</objective>

<execution_context>
@~/.claude/get-shit-done/workflows/execute-plan.md
@~/.claude/get-shit-done/templates/summary.md
</execution_context>

<context>
@.planning/PROJECT.md
@.planning/ROADMAP.md
@.planning/STATE.md
@.planning/phases/06-voice/06-RESEARCH.md
@.planning/phases/06-voice/06-01-SUMMARY.md
@.planning/phases/06-voice/06-02-SUMMARY.md
@.planning/phases/06-voice/06-03-SUMMARY.md
@.planning/phases/06-voice/06-04-SUMMARY.md
@.planning/phases/04-agent-core/04-04-SUMMARY.md
@.planning/phases/05-mcp/05-05-SUMMARY.md
@.planning/phases/03-hud/03-03-SUMMARY.md
@CLAUDE.md
@App/AppDelegate.swift
@App/HUD/HudStateCoordinator.swift
@App/HUD/HudStateIntent.swift
@App/MenuBar/MenuBarIconController.swift
@packages/AgentCore/Sources/AgentOrchestrator/AgentOrchestrator.swift
@packages/AgentCore/Sources/AgentOrchestrator/TurnInput.swift
@packages/AgentCore/Sources/AgentOrchestrator/SubmitOutcome.swift
@packages/Bus/Sources/Bus/BusOutbound.swift
@packages/Voice/Sources/Voice/AudioGraph/AudioGraphOwner.swift
@packages/Voice/Sources/Voice/WakeWord/WakeWordDAG.swift
@packages/Voice/Sources/Voice/VAD/SileroVAD.swift
@packages/Voice/Sources/Voice/STT/STTBackendSelector.swift
@packages/Voice/Sources/Voice/TTS/TTSEngineActor.swift
@packages/Voice/Sources/Voice/TTS/TTSInterrupt.swift

<interfaces>
<!--
  All upstream surfaces verbatim. The VoiceController is the integration layer
  — the rest of Phase 6 has been built; this plan stitches.
-->

From Plan 06-01:
```swift
public actor AudioGraphOwner {
    public var ringBuffer: RingBuffer { get async }
    public func setCancelInFlight(_ closure: @escaping @Sendable () async -> Void)
    public nonisolated var degradationStream: AsyncStream<DegradationReason> { get }
    public nonisolated var rebuildStream: AsyncStream<RebuildTrigger> { get }
}
```

From Plan 06-02:
```swift
public actor WakeWordDAG {
    public nonisolated var wakeWordStream: AsyncStream<WakeWordEvent> { get }
    public func start(ring: RingBuffer) async
    public func pause() async
    public func resume() async
    public func cancel() async
}
```

From Plan 06-03:
```swift
public actor SileroVAD {
    public func feed(_ pcm16k: UnsafeBufferPointer<Float>) throws -> VADDecision
    public func reset() async
}
public protocol STTProvider: Sendable {
    func transcribe(stream: AsyncStream<AudioChunk>) -> AsyncStream<PartialTranscript>
    func finalize() async throws -> String
}
public enum STTBackendSelector {
    public static func make(snapshot: PerTurnSnapshot) -> any STTProvider
}
```

From Plan 06-04:
```swift
public actor TTSEngineActor {
    public nonisolated var ttsEventStream: AsyncStream<TTSEvent> { get }
    public func synthesize(_ text: String, tier: TTSTier, voice: String) async throws
    public func cancel() async
}
public enum InterruptSequence {
    public static func run(engine: TTSEngineActor, sink: AudioSink, eventBus: AsyncStream<TTSEvent>.Continuation) async
}
```

From Phase 4 (AgentOrchestrator — already shipped):
```swift
public actor AgentOrchestrator {
    public func submit(_ input: TurnInput) async -> SubmitOutcome
    public func cancelAndSubmit(_ input: TurnInput) async -> SubmitOutcome
    public nonisolated let events: BoundedAsyncChannel<OrchestratorEvent>
}
public struct TurnInput: Sendable {
    public static func voice(_ s: String, at: Date = Date()) -> TurnInput
}
public enum OrchestratorEvent: Sendable {
    case stateChange(TurnState)
    case tokenDelta(turnId: TurnID, text: String)
    case turnEnd(turnId: TurnID, stopReason: StopReason)
    // ... others
}
```

From Phase 3 (HudStateCoordinator — already shipped):
```swift
public enum VoiceHudIntent: Sendable, Equatable {
    case silent       // .idle / .speaking / .thinking
    case listening    // active listening
    case reconfiguring  // graph rebuild in flight
}
@MainActor public final class HudStateCoordinator { /* consumes via voice AsyncStream */ }
```

From Phase 2 (Bus — already shipped, do NOT modify):
```swift
public enum BusOutbound: Equatable, Sendable {
    case audioLevel(rms: Float)   // ALREADY EXISTS — Phase 6 just needs to produce it
    // ...
}
```

From Phase 1:
```swift
@MainActor public final class HUDBannerCoordinator {
    public func showBanner(message: String, deepLink: URL?)
    public func dismissBanner()
}
@MainActor public final class HotkeyBinder {
    public func bind(spec: HotkeySpec, onDown: @escaping () -> Void, onUp: @escaping () -> Void)
}
```

New surface introduced by this plan:

```swift
public enum VoiceState: Sendable, Equatable {
    case idle
    case listening(source: ListeningSource)
    case thinking
    case speaking
    case reconfiguring(reason: RebuildTrigger)
}
public enum ListeningSource: Sendable, Equatable { case wakeWord, ptt }

public actor VoiceController {
    public init(graph: AudioGraphOwner,
                wakeWord: WakeWordDAG,
                vad: SileroVAD,
                sttFactory: @escaping () -> any STTProvider,
                tts: TTSEngineActor,
                ttsSink: AudioSink,
                orchestrator: AgentOrchestrator,
                bannerCoordinator: HUDBannerCoordinator,
                bus: BusOutboundEmitter,
                voiceHudCont: AsyncStream<VoiceHudIntent>.Continuation)

    public func start() async throws            // opens graph, starts wake-word + audio-level emitter
    public func shutdown() async
    public func muteWakeWord() async            // for menu-bar toggle
    public func unmuteWakeWord() async
    public func pttDown() async                 // for PTT hotkey
    public func pttUp() async
}

public final class PushToTalk: @unchecked Sendable {
    public init(controller: VoiceController, hotkeyBinder: HotkeyBinder)
    public func bind(spec: HotkeySpec)
}

@MainActor public final class MuteWakeWord {
    public init(controller: VoiceController, menuBar: MenuBarIconController)
    public func install()
}

public final class AudioLevelEmitter: @unchecked Sendable {
    public init(ring: RingBuffer, bus: BusOutboundEmitter, hzRate: Double = 30)
    public func start() async
    public func stop() async
}
```
</interfaces>
</context>

<tasks>

<task type="auto" tdd="true">
  <name>Task 1: VoiceController state machine + barge-in routing through cancelAndSubmit</name>
  <files>packages/Voice/Sources/Voice/VoiceController.swift, packages/Voice/Sources/Voice/VoiceState.swift, packages/Voice/Tests/VoiceTests/VoiceControllerTests.swift, packages/Voice/Tests/VoiceTests/BargeInTests.swift</files>
  <behavior>
    - VoiceControllerTests V1 (state machine): from `.idle`, a `wakeWordStream` event transitions to `.listening(source: .wakeWord)`; emits `VoiceHudIntent.listening` on the hud stream.
    - VoiceControllerTests V2 (VAD finalization): from `.listening`, when SileroVAD yields `.speechEnd` and STT finalizes "what time is it", controller transitions to `.thinking`, emits `VoiceHudIntent.silent`, calls `orchestrator.submit(TurnInput.voice("what time is it"))`.
    - VoiceControllerTests V3 (orchestrator → speaking): when `orchestrator.events` yields `.stateChange(.speaking(...))`, controller transitions to `.speaking`, calls `tts.synthesize(...)` with the running token stream.

      Implementation note: TTS synthesizes the FINAL text after `turnEnd`, not per-token. v1 keeps it simple: capture final tokens via `tokenDelta` accumulation, then synthesize on `turnEnd`. (A future v2 enhancement could stream tokens to TTS for sub-sentence latency; current scope says "natural spoken answer" not "incrementally synthesized".)
    - BargeInTests B1 (single cancelAndSubmit): with state = `.speaking`, fire a wake-word event. Assert `orchestrator.cancelAndSubmit` is called EXACTLY ONCE (counter via mock). Assert no separate `tts.cancel()` call escapes the controller — the cancel happens inside `cancelAndSubmit` via the InterruptSequence wired into the orchestrator's pre-turn hook.

      WAIT — the orchestrator doesn't currently hook InterruptSequence. Resolution: the VoiceController hands a fresh InterruptSequence-running closure to `cancelAndSubmit` via TurnInput's already-existing fields, OR runs InterruptSequence atomically BEFORE calling `cancelAndSubmit` but in a way that's still a single observable barge-in event. Re-read 04-04-SUMMARY:

      > `cancelAndSubmit` cancels the prior turn's task AND awaits its completion BEFORE assigning a new currentTurn

      The "single hop" requirement (VOICE-14 / Pitfall #8) is about not having two SEPARATE state changes the user can observe between cancel + start. The implementation pattern is:

      ```swift
      // Inside VoiceController.handleWakeWord while .speaking:
      // ATOMIC barge-in: TTS interrupt + orchestrator cancelAndSubmit happen
      // back-to-back inside the same actor-isolated method, with no `await`
      // between them that would let other events interleave.
      await InterruptSequence.run(engine: tts, sink: ttsSink, eventBus: ttsEventCont)
      let outcome = await orchestrator.cancelAndSubmit(.voice(""))
      // (the empty string is a sentinel — the orchestrator treats this as
      //  "the user wants to take over; start listening for new utterance")
      // OR: the controller transitions to .listening synthetically and waits
      //     for the next VAD speech-end before submitting real text.
      ```

      Decision (PINNED): the controller pattern is "intent-only barge-in" — wake-word during `.speaking` runs the InterruptSequence, then transitions the controller to `.listening(source: .wakeWord)`, WITHOUT immediately calling `cancelAndSubmit` for a NEW turn. The user's NEXT utterance (after VAD finalizes) is what triggers `cancelAndSubmit` with real text. This means:
        - On wake-during-speaking: `cancelAndSubmit("")` IS called (with empty user text — sentinel for "supersede current turn, no new prompt yet"); orchestrator returns `.superseded(...)`. Controller goes to `.listening`.
        - On VAD speech-end after that: a SECOND turn starts via `submit(real_text)`.
        - This is TWO orchestrator calls but TWO turns — not two hops for the same barge-in. The "single hop" rule applies WITHIN the barge-in event itself (one cancelAndSubmit call atomically displaces the speaking turn), not across the whole user interaction.

      ALTERNATE if the empty-string sentinel feels wrong: route barge-in through a controller-internal "abort current turn" path that calls `orchestrator.events` consumer with `cancel()` and lets the listening-pause naturally trigger the next submit. Decide at impl time; document either way.

    - BargeInTests B2 (HUD state on barge-in): wake-word during `.speaking` produces `VoiceHudIntent.listening` on the hud stream within 100 ms; the agent intent on `agentStream` (which Phase 3 already drains) goes from `.speaking` to `.idle` because the orchestrator emits `.stateChange(.idle)` after the supersede. Final HUD = `.listening`.
    - BargeInTests B3 (state preservation): the prior turn's TurnID is recorded in the SubmitOutcome `.superseded(priorId:reason:)`; the test asserts the priorId matches the cancelled turn.
    - BargeInTests B4 (no double-cancel): if barge-in fires twice in rapid succession (50 ms apart), only the FIRST runs the InterruptSequence; the second is debounced (controller checks current state — already in `.listening` after the first). Test asserts InterruptSequence ran exactly once.
  </behavior>
  <action>
Implement `VoiceState.swift` per `<interfaces>` with `Equatable` derivation.

Implement `VoiceController.swift` as an actor:

```swift
public actor VoiceController {
    private(set) var state: VoiceState = .idle
    private let graph: AudioGraphOwner
    private let wakeWord: WakeWordDAG
    private let vad: SileroVAD
    private let sttFactory: () -> any STTProvider
    private let tts: TTSEngineActor
    private let ttsSink: AudioSink
    private let orchestrator: AgentOrchestrator
    private let bannerCoordinator: HUDBannerCoordinator
    private let bus: BusOutboundEmitter
    private let voiceHudCont: AsyncStream<VoiceHudIntent>.Continuation

    private var currentSTT: (any STTProvider)?
    private var transcriptAccumulator: String = ""

    public func start() async throws {
        try await graph.open()
        await wakeWord.start(ring: graph.ringBuffer)
        // Spawn consumers
        spawnWakeWordConsumer()
        spawnDegradationConsumer()
        spawnRebuildConsumer()
        spawnOrchestratorEventsConsumer()
        spawnAudioLevelEmitter()
        await transition(to: .idle)
    }

    private func spawnWakeWordConsumer() {
        Task {
            for await event in wakeWord.wakeWordStream {
                await handleWakeWord(event)
            }
        }
    }

    private func handleWakeWord(_ event: WakeWordEvent) async {
        switch state {
        case .idle, .listening:
            await transition(to: .listening(source: .wakeWord))
            await startSTT()
        case .speaking:
            // BARGE-IN: atomic interrupt + orchestrator displacement
            await InterruptSequence.run(engine: tts, sink: ttsSink, eventBus: ttsEventCont)
            _ = await orchestrator.cancelAndSubmit(.voice(""))   // sentinel — see plan note
            await transition(to: .listening(source: .wakeWord))
            await startSTT()
        case .thinking:
            // Dedupe: already in a turn
            break
        case .reconfiguring:
            break
        }
    }

    private func spawnDegradationConsumer() {
        Task {
            for await reason in graph.degradationStream {
                if case .aecUnavailable = reason {
                    await MainActor.run {
                        bannerCoordinator.showBanner(
                            message: "AEC unavailable; degraded-mode active",
                            deepLink: nil
                        )
                    }
                }
            }
        }
    }
    // ... other spawn helpers
}
```

The sentinel `.voice("")` in `cancelAndSubmit` is documented inline as "barge-in displacement signal — orchestrator may treat empty userText as `.superseded` no-op turn". Verify with the actual orchestrator behavior: `orchestrator.cancelAndSubmit(.voice(""))` should return `.superseded(priorId:.bargedIn)` and emit a `.stateChange(.idle)` event. If the orchestrator currently treats empty userText as an error, the controller chooses Option B from the behavior note: emit a controller-internal abort path that calls a hypothetical `orchestrator.cancelCurrent()` (which doesn't exist in P4). RESOLUTION: at impl time, verify orchestrator's behavior with empty userText; if it's an error, STOP and request a one-line orchestrator change (a new method `cancelOnly()`) — the executor flags this as a Rule 3 deviation, opens a checkpoint, and returns to the user.

For B4 (debounce): track `private var lastBargeInAt: Date?` and skip if within 200 ms of the last.

Verify: V1..V3 + B1..B4 pass.
  </action>
  <verify>
    <automated>swift test --package-path packages/Voice --filter VoiceTests.VoiceControllerTests &amp;&amp; swift test --package-path packages/Voice --filter VoiceTests.BargeInTests</automated>
  </verify>
  <done>VoiceControllerTests (3 cases) + BargeInTests (4 cases) pass. The barge-in sentinel pattern is documented in `VoiceController.swift` (with the orchestrator-empty-userText behavior verified before merge). The InterruptSequence runs INSIDE the wake-word handler, not from a separate observer — single atomic actor method.</done>
</task>

<task type="auto" tdd="true">
  <name>Task 2: PTT + MuteWakeWord + AudioLevelEmitter</name>
  <files>packages/Voice/Sources/Voice/Control/PushToTalk.swift, packages/Voice/Sources/Voice/Control/MuteWakeWord.swift, packages/Voice/Sources/Voice/Control/AudioLevelEmitter.swift, packages/Voice/Tests/VoiceTests/PTTTests.swift, packages/Voice/Tests/VoiceTests/MuteWakeWordTests.swift, packages/Voice/Tests/VoiceTests/AECFallbackBannerTests.swift</files>
  <behavior>
    - PTTTests P1: `pttDown()` from `.idle` transitions to `.listening(source: .ptt)`, calls `wakeWord.pause()` (saves cycles per RESEARCH §12), starts STT.
    - PTTTests P2: `pttUp()` from `.listening(.ptt)` finalizes STT, calls `wakeWord.resume()`, submits voice turn via `orchestrator.submit`.
    - PTTTests P3: PTT works when wake-word is muted — explicit test that `muteWakeWord()` then `pttDown()` still transitions to `.listening(.ptt)` (VOICE-12 contract).
    - PTTTests P4: PTT during `.speaking` triggers barge-in (same handler as wake-word during speaking) — InterruptSequence runs, controller goes to `.listening(.ptt)`.
    - MuteWakeWordTests M1: toggle mute → `WakeWordDAG.pause()` called; UserDefaults `features.voice.wakeWordMuted` set to `true`; menu-bar icon shows muted variant.
    - MuteWakeWordTests M2: toggle un-mute → `WakeWordDAG.resume()` called; UserDefaults `false`; icon shows normal variant.
    - MuteWakeWordTests M3: persistence — set mute, simulate app restart by re-instantiating MuteWakeWord; reads UserDefaults, applies muted state on init.
    - AECFallbackBannerTests F1: emit `.aecUnavailable` on the degradation stream — `HUDBannerCoordinator.showBanner` is called once with message "AEC unavailable; degraded-mode active". Use a stub banner coordinator that records calls.
    - AECFallbackBannerTests F2: a successful AEC-on rebuild after a fallback — `bannerCoordinator.dismissBanner()` is called. (This requires the rebuild path to track its own variant transitions.)
    - AudioLevelEmitter test (in VoiceControllerTests V4): start the emitter, write 100 ms of constant-amplitude PCM to the ring, observe the next emitted `BusOutbound.audioLevel(rms:)` value matches the expected RMS within ±5%. Verify emission rate is 30 Hz ± 10% over a 1-second window.
  </behavior>
  <action>
Implement `PushToTalk.swift`:
- Wraps Phase 1's `HotkeyBinder` for the dedicated PTT hotkey spec.
- `bind(spec:)` calls `hotkeyBinder.bind(spec:onDown:onUp:)` with closures that call `controller.pttDown()` / `controller.pttUp()`.
- The hotkey spec is read from Phase 1's config (`UserDefaults` key `hotkey.ptt.spec`) — unbound by default, user binds via shortcut recorder if they want PTT.

Implement `MuteWakeWord.swift`:
- `@MainActor` class wrapping menu-bar item integration.
- `install()`:
  - Adds a "Mute Wake Word" item to `menuBar`'s submenu (NOT a top-level click — it's a state toggle).
  - On click, calls `controller.muteWakeWord()` / `controller.unmuteWakeWord()` (alternating).
  - Updates UserDefaults (`features.voice.wakeWordMuted`).
  - Updates menu-bar item title/checkmark to reflect current state.
  - On init, reads UserDefaults; if previously muted, calls `controller.muteWakeWord()` immediately.

Implement `AudioLevelEmitter.swift`:
- `init(ring:, bus:, hzRate: 30)`.
- `start()`: spawns a Task that reads ~5 ms of audio (80 samples @ 16 kHz) at 33 ms intervals (30 Hz), computes RMS = `sqrt(sum(x*x) / N)`, emits `bus.send(.audioLevel(rms: ...))`.
- `stop()`: cancels the emitter Task.
- The emitter only emits during `.listening` state — the controller calls `start()` on transition into listening and `stop()` on transition out. Mode flag inside the emitter so the Task doesn't burn cycles when paused.

For AECFallbackBannerTests F2: the controller's degradation consumer needs to ALSO observe successful rebuilds (`rebuildStream`) and dismiss the banner when the rebuild succeeds with AEC-on. Add a `bannerActive: Bool` flag to `VoiceController` and dismiss when the next rebuild succeeds. Document inline that the banner's lifetime is "from .aecUnavailable until next AEC-on rebuild succeeds".

Verify: P1..P4 + M1..M3 + F1..F2 + V4 (audio-level) pass.
  </action>
  <verify>
    <automated>swift test --package-path packages/Voice --filter VoiceTests.PTTTests &amp;&amp; swift test --package-path packages/Voice --filter VoiceTests.MuteWakeWordTests &amp;&amp; swift test --package-path packages/Voice --filter VoiceTests.AECFallbackBannerTests</automated>
  </verify>
  <done>PTTTests (4 cases) + MuteWakeWordTests (3 cases) + AECFallbackBannerTests (2 cases) + AudioLevelEmitter (1 case in VoiceControllerTests) pass. PTT works when muted (P3) — VOICE-12 contract. UserDefaults persistence verified (M3). Audio-level RMS at 30 Hz proven (V4).</done>
</task>

<task type="auto" tdd="true">
  <name>Task 3: AppDelegate production wiring + voice stream replacement</name>
  <files>App/AppDelegate.swift, App/MenuBar/MenuBarIconController.swift, App/Tests/AppTests/VoiceWiringTests.swift</files>
  <behavior>
    - VoiceWiringTests W1: AppDelegate's `applicationDidFinishLaunching` (or appropriate lifecycle hook) instantiates `AudioGraphOwner`, `WakeWordDAG`, `SileroVAD`, `STTBackendSelector`, `TTSEngineActor`, `VoiceController`, `PushToTalk`, `MuteWakeWord`, `AudioLevelEmitter`. All retained as strong properties.
    - VoiceWiringTests W2: the dormant `voiceStream` continuation that `HudStateCoordinator` consumes is REPLACED with the real `VoiceController.voiceHudIntentStream` — verify by sending an intent through the controller and observing it land on the coordinator's `lastVoice` shadow field (test seam: `currentStateForTests`).
    - VoiceWiringTests W3: `MenuBarIconController` has a "Mute Wake Word" submenu item after install.
    - VoiceWiringTests W4: PTT hotkey binding is registered at boot if config has a PTT hotkey spec, and unregistered cleanly on shutdown.
  </behavior>
  <action>
Modify `App/AppDelegate.swift`:
1. Add strong properties for all voice subsystem instances.
2. In `applicationDidFinishLaunching` (after the existing Phase 5 wiring):
   - Construct `AudioGraphOwner` with new degradation/rebuild AsyncStreams.
   - Construct `WakeWordDAG(session: try await OpenWakeWordSession(modelDir: openWakeWordModelDir))`.
   - Construct `SileroVAD(modelDir: sileroModelDir)`.
   - Construct `TTSEngineActor` + `AudioSink` over the `AVAudioPlayerNode` attached to the AudioGraph's mixer.
   - Construct `VoiceController`. Pass the dormant `voiceContinuation` (which AppDelegate already holds) AS the `voiceHudCont` parameter — this is the connection that replaces the dormant placeholder.
   - Wire up `PushToTalk(controller:, hotkeyBinder: existingPhase1HotkeyBinder)`.
   - Wire up `MuteWakeWord(controller:, menuBar: menuBarIconController)`.
   - Construct `AudioLevelEmitter` with the bus and ring buffer.
   - Call `try await voiceController.start()`.

3. The `--probe-stt` flag (referenced by Plan 06-03's `scripts/probe-speech-assets.sh`):
   - In `applicationDidFinishLaunching`, check `CommandLine.arguments.contains("--probe-stt")`.
   - If yes, instantiate just an STT provider (skipping the full voice loop), call `try await provider.transcribe(stream: emptyStream)`, log any `SFSpeechErrorCode.assetUnavailable` to stderr, exit.

4. Modify `MenuBarIconController.swift` to expose a method `addToggleableItem(title:, key:, isOn:, action:)` — the small extension that `MuteWakeWord` consumes. If the existing controller's API is sufficient, document; otherwise add the helper.

VoiceWiringTests test the wiring AT THE STRUCTURAL LEVEL, not by booting a real app:
- W1 uses a `compose(...)` test seam similar to the one Phase 5 used in `MCPRuntimeWiring`. The test seam takes mocks for each subsystem and asserts the wiring graph (who-points-to-who) without instantiating real ORT sessions.
- W2 uses a synthetic VoiceController-mock that emits a known VoiceHudIntent; tests that HudStateCoordinator.currentStateForTests reflects it after a tick.

This task is `autonomous: true` for the wiring + tests, BUT this PLAN is `autonomous: false` because of Task 4 (HUMAN-UAT).

Verify: structural tests pass; xcodebuild builds (or the existing pre-existing Xcode 26 RunningBoard skip applies — Plan 03-05 documented this).
  </action>
  <verify>
    <automated>swift test --package-path packages/Voice &amp;&amp; xcodegen generate &amp;&amp; xcodebuild -scheme Jarvis -configuration Debug build</automated>
  </verify>
  <done>VoiceWiringTests (4 cases — W1..W4) pass. AppDelegate wires all six subsystems + PTT + MuteWakeWord + AudioLevelEmitter. Dormant voiceStream is now real. `--probe-stt` flag short-circuits to STT-only path. xcodegen + xcodebuild Debug build succeeds.</done>
</task>

<task type="checkpoint:human-verify" gate="blocking">
  <name>Task 4: HUMAN-UAT — End-to-end voice loop on physical Mac</name>
  <what-built>The complete Phase 6 voice loop. Wake word + VAD + STT + agent turn + TTS, with HUD state transitions, PTT, mute-wake-word, AEC-off banner, and barge-in.</what-built>
  <how-to-verify>
A physical-Mac UAT checklist landing in `.planning/phases/06-voice/06-HUMAN-UAT.md` with these gates:

**Pre-flight (before the human session):**
- [ ] `swift test --package-path packages/Voice` — all green.
- [ ] `JARVIS_REAL_MODELS=1 swift test --package-path packages/Voice --filter OrpheusTTFATests` — TTFA measurement logged. If > 250 ms, executor has flipped `features.tts.tier2 = "ttskit"` in default config.
- [ ] `swift test --package-path packages/Voice --filter SileroContractTests.testParityProbeAtScaffold` — Silero v6.2.1 contract parity verified.
- [ ] Release archive built; `bash scripts/probe-speech-assets.sh path/to/Jarvis.app` run; result logged (PASS/INCONCLUSIVE).
- [ ] `bash scripts/fetch-openwakeword-models.sh` and `bash scripts/fetch-silero-models.sh` have been run on the test machine; ONNX files present in `Resources/models/`.

**End-to-end happy path (VOICE-07):**
1. Cold-launch the Release-signed Jarvis.app.
2. Grant Microphone permission on first prompt (TCC).
3. Wait for the HUD ring to render in `.idle` state.
4. Say "Hey Jarvis" — verify ring transitions to `.listening` within ~500 ms (~320 ms hysteresis + tap latency).
5. Say "what time is it" — verify ring shows audio-reactive pulse during listening (NOT the fake sine — actual amplitude tracking).
6. Stop speaking — verify ring transitions to `.thinking` within ~300 ms (Silero hangover).
7. Wait for the answer — verify ring transitions to `.speaking` when audio starts.
8. Verify the spoken answer is natural-sounding (Orpheus tara voice, ~150-250 ms TTFA observable).
9. After answer, verify ring returns to `.idle`.
10. **PASS criteria**: every state transition occurs; audio is intelligible; latency feels conversational (< 3 s end-to-end).

**Barge-in (VOICE-14):**
1. Trigger a long answer (e.g. ask Jarvis to count to 20).
2. While Jarvis is speaking, say "Hey Jarvis" again.
3. Verify: TTS stops within ~50 ms (no clipped clicks); ring transitions from `.speaking` directly to `.listening`; new utterance is captured.
4. **PASS criteria**: no audible click/pop on stop; HUD state transitions cleanly; new turn proceeds normally.

**Push-to-talk (VOICE-13):**
1. Set a PTT hotkey via the first-launch shortcut recorder (or via Settings UI if Phase 1 exposes one).
2. Hold the PTT hotkey + speak. Verify ring goes to `.listening(.ptt)` IMMEDIATELY (no wake-word delay).
3. Release the hotkey. Verify STT finalizes + agent processes + TTS speaks.
4. **PASS criteria**: PTT path doesn't wait for wake-word; works as expected.

**Mute wake word (VOICE-12):**
1. Click the menu-bar icon → "Mute Wake Word" → verify checkmark appears.
2. Say "Hey Jarvis" — verify NO response (wake-word is paused).
3. Hold PTT hotkey + speak — verify PTT STILL WORKS (the explicit VOICE-12 contract).
4. Restart the app — verify mute state persists across launch.
5. Toggle un-mute → verify wake-word resumes.
6. **PASS criteria**: muting wake-word doesn't disable PTT; persistence works.

**AEC fallback (VOICE-09):**
1. (Difficult to trigger naturally) Plug in a USB audio interface that doesn't support VPIO, OR temporarily edit the AudioGraph to force-throw on `setVoiceProcessingEnabled(true)` for one launch.
2. Cold-launch — verify the HUD banner shows "AEC unavailable; degraded-mode active".
3. Switch back to the built-in mic → verify banner dismisses on next rebuild.
4. **PASS criteria**: banner appears via the native AppKit path (NOT a webview modal — verify by inspecting in Accessibility Inspector); message text is exactly "AEC unavailable; degraded-mode active".

**Mic re-grant (VOICE-10 trigger):**
1. Deny mic at first launch.
2. Verify Jarvis surfaces a banner with System Settings deep link (Phase 1 banner pattern).
3. In System Settings → Privacy & Security → Microphone, enable Jarvis.
4. Switch back to Jarvis — verify the audio graph rebuilds (look for `.reconfiguring` flicker on the ring) and audio-level RMS starts updating.
5. **PASS criteria**: re-grant triggers rebuild without app restart.

**Pass / fail / notes:**
The user fills in PASS/FAIL/NOTES per gate, signs the file, and resumes the agent.
  </how-to-verify>
  <resume-signal>Type "voice UAT passed" or describe issues. If TTFA was > 250 ms during the OrpheusTTFATests probe, mention which tier (orpheus / ttskit) was active during UAT. If the AEC fallback couldn't be triggered, note "AEC fallback untested" — Phase 8 hardening will revisit.</resume-signal>
  <files>.planning/phases/06-voice/06-HUMAN-UAT.md</files>
  <action>Pause for human-driven UAT. The executor MUST NOT proceed past this task until the user signs the UAT file. The user runs the gates above on their physical Apple Silicon Mac, fills in PASS/FAIL/NOTES per gate, and replies with the resume-signal. The executor's only job during this checkpoint is to (a) write the UAT skeleton at `.planning/phases/06-voice/06-HUMAN-UAT.md` with the gates above pre-populated as a markdown checklist, and (b) wait.</action>
  <verify>
    <automated>test -f .planning/phases/06-voice/06-HUMAN-UAT.md &amp;&amp; grep -q "Hey Jarvis, what time is it" .planning/phases/06-voice/06-HUMAN-UAT.md</automated>
  </verify>
  <done>UAT skeleton file exists; user has replied with the resume-signal and signed the file (PASS gates listed; any FAIL gates have a deferral note pointing to Phase 7 or Phase 8).</done>
</task>

</tasks>

<threat_model>
## Trust Boundaries

| Boundary | Description |
|----------|-------------|
| User voice → wake-word/VAD → STT → orchestrator | Same untrusted-content boundary as Phase 4 text input; `TurnInput.voice(_:)` flows through the same UntrustedWrapper + nonce-tag pipeline (SEC-06 from Phase 4). |
| HotkeyBinder global monitor → PTT events | Phase 1 trust boundary; Input Monitoring TCC is the gate. |
| AudioGraphOwner.degradationStream → HUDBannerCoordinator | Internal app boundary; banner reuses Phase 1 native AppKit path (modal-lint enforced). |
| AVAudioPlayerNode → speaker | OS-mediated; cosine fade defends UX, not security. |

## STRIDE Threat Register

| Threat ID | Category | Component | Disposition | Mitigation Plan |
|-----------|----------|-----------|-------------|-----------------|
| T-06-05-01 | Spoofing | TV/radio audio triggers wake word | mitigate | Plan 06-02's ≥4-frame hysteresis suppresses singleton spikes. Defense-in-depth: VOICE-12 mute-wake-word toggle gives the user a kill switch. |
| T-06-05-02 | Tampering | Webview modal injected for AEC banner (unauthorized presentation surface) | mitigate | Phase 5's `scripts/check-no-modal-presentation.sh` is the build-time lint; HUDBannerCoordinator is on the allowlist (Phase 1). VoiceController's degradation consumer routes through HUDBannerCoordinator only — never NSApp modal. |
| T-06-05-03 | Information Disclosure | Voice transcripts written to system logs | mitigate | Plan 06-03's STT handlers route transcripts ONLY to ReplayLog (encrypted at rest by FileVault); `JarvisLogChannel.system` records voice-state transitions but never raw transcript text. Grep gate: `grep -nE 'transcriptAccumulator|partialTranscript' packages/Voice/Sources/Voice/VoiceController.swift | grep -i 'logger\\|log\\.info\\|log\\.warning' | wc -l` — must be 0. |
| T-06-05-04 | Denial of Service | Wake-word floods orchestrator with `cancelAndSubmit` (e.g. someone repeatedly says "Hey Jarvis") | mitigate | Controller-level debounce (200 ms) per BargeInTests B4; orchestrator's `cancelAndSubmit` is itself idempotent under rapid fire (Phase 4 actor-reentrancy guard). |
| T-06-05-05 | Elevation of Privilege | PTT hotkey hijacked by another process | accept | Phase 1's `NSEvent.addGlobalMonitorForEvents` + Input Monitoring TCC is the v1 boundary. A hostile process can capture keystrokes regardless. v2 may add hotkey verification via Accessibility events. |
| T-06-05-06 | Information Disclosure | Mic captures sensitive audio while in `.idle` (no listening intended) | mitigate | The wake-word DAG runs continuously by design (always-listening), but VAD/STT do NOT — they activate ONLY on wake-word fire or PTT. Mic frames in the RingBuffer are in-memory only; no disk persistence. |
| T-06-05-07 | Repudiation | Voice-initiated turn appears identical to text-initiated turn in logs | mitigate | `TurnInput.source = .voice` is recorded in ReplayLog (Phase 4); cohort slicing is queryable. DevOverlay (Phase 4 Plan 04-05) shows turn source. |
</threat_model>

<verification>
- `swift test --package-path packages/Voice` — all VoiceTests green (Plans 06-01 + 06-02 + 06-03 + 06-04 + this plan = ~60 net cases).
- `swift test --package-path App` — VoiceWiringTests (4 cases) green.
- `swift build --package-path packages/Voice` — clean Debug + Release.
- `xcodegen generate && xcodebuild -scheme Jarvis -configuration Debug build` — succeeds. (Test execution may hit Xcode 26 RunningBoard signal — pre-existing per Plan 03-05; not a regression.)
- `bash scripts/check-no-modal-presentation.sh` — exit 0 (Phase 5 lint, no new modal calls).
- Grep gates:
  - `grep -nE 'cancelAndSubmit' packages/Voice/Sources/Voice/VoiceController.swift | grep -v '^[[:space:]]*//' | wc -l` — exactly 1 (single-call-site discipline; VOICE-14).
  - `grep -nE 'NSAlert|runModal|beginModalSession' packages/Voice/Sources/Voice/` — 0 matches.
  - `grep -nE 'BusOutbound\\.audioLevel' packages/Voice/Sources/Voice/Control/AudioLevelEmitter.swift` — at least 1 (production emitter).
  - `grep -rnE 'AVAudioFormat\\(.*sampleRate: 24_?000\\)' packages/Voice/Sources/Voice/` — 0 matches outside AudioGraph.swift (no hardcoded 24 kHz; downstream consumers see 16 kHz).
- Manual UAT (`06-HUMAN-UAT.md`) signed off.
- Scaffold-time probes recorded:
  - Silero v6.2.1 parity probe: PASS / FAIL with measurement.
  - Orpheus TTFA: measured value ≤ 250 ms target OR remediation note (TTSKit fallback active).
  - speech-recognition-assets entitlement load-bearing probe: PASS / INCONCLUSIVE / REFUTED.
</verification>

<success_criteria>
- VOICE-07 closed at the integration + UAT level: full happy path runs end-to-end on the user's Mac with HUD transitions visible.
- VOICE-09 closed: AEC-off banner appears via native AppKit (not webview modal); persists until next AEC-on rebuild.
- VOICE-12 closed: mute-wake-word menu-bar toggle pauses DAG; PTT remains armed; UserDefaults persists.
- VOICE-13 closed: PTT hotkey activates STT directly; bypasses wake-word; finalizes on release.
- VOICE-14 closed: barge-in routes through EXACTLY ONE `cancelAndSubmit` call per event (debounced, atomic with InterruptSequence).
- AudioLevelEmitter wires Plan 03-03's listening-pulse uniform to real audio RMS (replacing the fake sine).
- AppDelegate's dormant `voiceStream` continuation is replaced with `VoiceController.voiceHudIntentStream`.
- All 14 VOICE-* requirements (across 06-01..06-05) are unit-tested OR UAT-gated.
- Phase 6 ships with the manual UAT artifact (`06-HUMAN-UAT.md`) signed and dated.
</success_criteria>

<output>
After completion, create `.planning/phases/06-voice/06-05-SUMMARY.md` documenting:
- The barge-in atomic-actor-method pattern (single `cancelAndSubmit` call site).
- The empty-userText sentinel decision OR the orchestrator method addition (whichever the executor chose at impl time, with rationale).
- The dormant-stream replacement: how `voiceStream` continuation became real.
- The audio-level emitter: 30 Hz RMS → BusOutbound.audioLevel → Plan 03-03 RingMesh listening pulse.
- The AEC banner lifecycle (appears on degradation, dismisses on next AEC-on rebuild).
- Mute / PTT independence proof (VOICE-12 contract via PTTTests P3).
- HUMAN-UAT result summary (PASS gates, any FAIL gates with deferral notes).
- Scaffold-time probe results: Silero parity, Orpheus TTFA, speech-recognition-assets entitlement.
- Full 14 VOICE-* requirement coverage map.
- Test count: ~17 (3 VoiceController + 4 BargeIn + 4 PTT + 3 MuteWakeWord + 2 AECFallback + 1 audioLevel + 4 VoiceWiring).
</output>
