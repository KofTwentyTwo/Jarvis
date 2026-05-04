import Foundation
import OSLog

private let logger = Logger(subsystem: "com.koftwentytwo.jarvis", category: "VoiceController")

// MARK: - VoiceController
//
// The top-level actor stitching the five Phase 6 subsystems into one state machine.
//
// Subsystems consumed:
//   - WakeWordDAG.wakeWordStream (Plan 06-02)
//   - SileroVAD + STTProvider (Plan 06-03) via factory closures
//   - VoiceTTSInterface → TTSEngineActor (Plan 06-04)
//   - VoiceOrchestratorInterface → AgentOrchestrator adapter (Plan 04-04)
//   - VoiceBannerInterface → HUDBannerCoordinator (Phase 1)
//   - BusOutboundEmitter → OutboundBatcher (Phase 2) for audio-level RMS
//
// Anti-patterns enforced (CLAUDE.md voice-stack rules):
//   VOICE-14: single cancelAndSubmit call site (in bargeIn()) — grep gate
//   T-06-05-03: transcriptAccumulator NEVER logged
//   T-06-05-02: AEC banner uses VoiceBannerInterface (AppKit) — no webview modal
//   T-06-05-04: 200ms barge-in debounce (BargeInTests B4)
//   VOICE-12: pttDown() / pttUp() work even when wake-word is muted

public actor VoiceController {

    // MARK: - Public API

    /// Current state of the voice pipeline.
    public private(set) var state: VoiceState = .idle

    // MARK: - Dependencies

    private let wakeWordStream: AsyncStream<WakeWordEvent>
    private let vadFactory: @Sendable () -> SileroVAD
    private let sttFactory: @Sendable () -> any STTProvider
    private let chunkPump: @Sendable (AsyncStream<AudioChunk>.Continuation) async -> Void
    private let tts: any VoiceTTSInterface
    private let orchestrator: any VoiceOrchestratorInterface
    private let bannerCoordinator: any VoiceBannerInterface
    private let bus: any BusOutboundEmitter
    private let voiceHudCont: AsyncStream<VoiceHudIntent>.Continuation

    // MARK: - Internal state

    private var aecBannerActive: Bool = false
    /// 200ms barge-in debounce timestamp (T-06-05-04 / BargeInTests B4).
    private var lastBargeInAt: Date = .distantPast

    // MARK: - Background tasks

    private var wakeWordTask: Task<Void, Never>?
    private var orchestratorTask: Task<Void, Never>?

    /// Track B-5: per-session pump Task that drains audio frames into the
    /// STT continuation. Cancelled when listening ends.
    private var chunkPumpTask: Task<Void, Never>?

    /// Exposed for AppDelegate to wire the audio-level emitter.
    public var audioLevelEmitter: AudioLevelEmitter?

    // MARK: - STT session continuations

    private var sttChunkCont: AsyncStream<AudioChunk>.Continuation?

    // MARK: - Init

    /// Creates the voice controller.
    ///
    /// - Parameters:
    ///   - wakeWordStream: `WakeWordDAG.wakeWordStream` from Plan 06-02.
    ///   - vadFactory: Returns a fresh `SileroVAD` per session.
    ///   - sttFactory: Returns a fresh `STTProvider` per turn.
    ///   - tts: TTS engine conforming to `VoiceTTSInterface`.
    ///   - orchestrator: Adapter over `AgentOrchestrator`.
    ///   - bannerCoordinator: Native AppKit banner surface (VOICE-09).
    ///   - bus: Audio-level bus emitter (Plan 03-03 RingMesh wiring).
    ///   - voiceHudCont: HUD voice intent stream continuation.
    public init(
        wakeWordStream: AsyncStream<WakeWordEvent>,
        vadFactory: @escaping @Sendable () -> SileroVAD,
        sttFactory: @escaping @Sendable () -> any STTProvider,
        tts: any VoiceTTSInterface,
        orchestrator: any VoiceOrchestratorInterface,
        bannerCoordinator: any VoiceBannerInterface,
        bus: any BusOutboundEmitter,
        voiceHudCont: AsyncStream<VoiceHudIntent>.Continuation,
        chunkPump: @escaping @Sendable (AsyncStream<AudioChunk>.Continuation) async -> Void = { _ in }
    ) {
        self.wakeWordStream = wakeWordStream
        self.vadFactory = vadFactory
        self.sttFactory = sttFactory
        self.tts = tts
        self.orchestrator = orchestrator
        self.bannerCoordinator = bannerCoordinator
        self.bus = bus
        self.voiceHudCont = voiceHudCont
        self.chunkPump = chunkPump
    }

    // MARK: - Lifecycle

    /// Start the controller: spawn background consumers.
    public func start() async {
        logger.info("VoiceController: starting")
        spawnWakeWordConsumer()
        spawnOrchestratorConsumer()
        await emitHUDIntent(.silent)
    }

    /// Test alias for `start()`.
    public func startForTests() async { await start() }

    /// Shut down all background tasks.
    public func shutdown() async {
        wakeWordTask?.cancel()
        orchestratorTask?.cancel()
        chunkPumpTask?.cancel()
        wakeWordTask = nil
        orchestratorTask = nil
        chunkPumpTask = nil
        await audioLevelEmitter?.stop()
        audioLevelEmitter = nil
        sttChunkCont?.finish()
        sttChunkCont = nil
        voiceHudCont.finish()
        logger.info("VoiceController: shutdown")
    }

    // MARK: - PTT (called by PushToTalk)

    /// Push-to-talk key pressed. Activates STT directly — bypasses wake-word DAG.
    ///
    /// Works even when wake-word is muted (VOICE-12 / PTTTests P3).
    public func pttDown() async {
        logger.debug("VoiceController: pttDown state=\(String(describing: self.state))")
        switch self.state {
        case .idle:
            await doTransition(to: .listening(source: .ptt))
            await startSTTSession()
        case .speaking:
            await bargeIn(source: .ptt)
        case .listening, .thinking, .reconfiguring:
            break
        }
    }

    /// Push-to-talk key released. Finalizes the STT session.
    ///
    /// Works even when wake-word is muted (VOICE-12 / PTTTests P3).
    public func pttUp() async {
        logger.debug("VoiceController: pttUp state=\(String(describing: self.state))")
        guard case .listening(let src) = self.state, src == .ptt else { return }
        endSTTSession()
    }

    // MARK: - Mute / unmute (called by MuteWakeWord)

    /// Pause wake-word inference. PTT remains armed (VOICE-12).
    public func muteWakeWord() async {
        logger.info("VoiceController: wake-word muted — PTT still armed")
        // WakeWordDAG.pause() is called by MuteWakeWord before calling this method.
    }

    /// Resume wake-word inference.
    public func unmuteWakeWord() async {
        logger.info("VoiceController: wake-word unmuted")
        // WakeWordDAG.resume() is called by MuteWakeWord before calling this method.
    }

    // MARK: - AEC degradation (called by AudioGraphOwner.degradationStream consumer)

    /// Show the AEC-off banner (VOICE-09). Uses AppKit path — never webview modal (T-06-05-02).
    public func handleAECUnavailable() async {
        guard !aecBannerActive else { return }
        aecBannerActive = true
        bannerCoordinator.showBanner(message: "AEC unavailable; degraded-mode active")
        logger.warning("VoiceController: AEC unavailable banner shown")
    }

    /// Dismiss the AEC banner when the graph rebuilds with AEC-on.
    public func handleAECRestored() async {
        guard aecBannerActive else { return }
        aecBannerActive = false
        bannerCoordinator.dismissBanner()
        logger.info("VoiceController: AEC restored — banner dismissed")
    }

    // MARK: - Test seams

    /// Force the controller into a specific state. Tests only.
    public func _forceState(_ newState: VoiceState) async {
        state = newState
    }

    /// Simulate a VAD speech-end + STT finalization with given text. Tests only.
    public func _testFireSpeechEnd(text: String = "") async {
        await handleSTTFinalized(text: text)
    }

    // MARK: - Private: background consumers

    private func spawnWakeWordConsumer() {
        let stream = wakeWordStream
        wakeWordTask = Task { [self] in
            for await event in stream {
                await self.handleWakeWord(event)
            }
        }
    }

    private func handleWakeWord(_ event: WakeWordEvent) async {
        switch state {
        case .idle:
            await doTransition(to: .listening(source: .wakeWord))
            await startSTTSession()

        case .listening:
            // Hysteresis re-fires within the same utterance — ignore duplicates.
            break

        case .speaking:
            // Barge-in: single call site in bargeIn() (VOICE-14).
            await bargeIn(source: .wakeWord)

        case .thinking:
            // LLM in flight — ignore.
            break

        case .reconfiguring:
            // Graph rebuilding — ignore.
            break
        }
    }

    private func spawnOrchestratorConsumer() {
        let events = orchestrator.voiceEvents
        orchestratorTask = Task { [self] in
            for await event in events {
                await self.handleOrchestratorEvent(event)
            }
        }
    }

    private func handleOrchestratorEvent(_ event: VoiceOrchestratorEvent) async {
        switch event {
        case .turnEnded(let text):
            // Only proceed if we're still in .thinking
            guard state == .thinking else { return }
            if text.isEmpty {
                await doTransition(to: .idle)
                return
            }
            await doTransition(to: .speaking)
            // Synthesize final turn text. tts.synthesize blocks until done.
            await tts.synthesize(text)
            // After synthesis, return to idle.
            if case .speaking = state {
                await doTransition(to: .idle)
            }

        case .cancelled:
            // Prior turn displaced — controller already in .listening from bargeIn().
            break

        case .error:
            if case .thinking = state {
                await doTransition(to: .idle)
            }
        }
    }

    // MARK: - Private: barge-in (VOICE-14 single cancelAndSubmit call site)

    /// Atomic barge-in sequence (VOICE-14).
    ///
    /// VOICE-14: This method contains the SINGLE `cancelAndSubmit` call site in
    /// VoiceController. Grep gate in verification:
    ///   `grep -nE 'cancelAndSubmit' .../VoiceController.swift | grep -v '//' | wc -l`
    /// must equal 1.
    ///
    /// 200ms debounce (T-06-05-04 / BargeInTests B4): second wake-word within 200ms
    /// of the first is ignored (controller is already in .listening).
    private func bargeIn(source: ListeningSource) async {
        let now = Date()
        guard now.timeIntervalSince(lastBargeInAt) > 0.200 else {
            logger.debug("VoiceController: barge-in debounced (< 200ms)")
            return
        }
        lastBargeInAt = now

        logger.info("VoiceController: barge-in source=\(String(describing: source))")

        // Cancel in-flight TTS (cooperative via TTSEngineActor.cancel).
        await tts.cancelTTS()

        // Single cancelAndSubmit call site — VOICE-14.
        // Empty text = barge-in displacement sentinel. The orchestrator supersedes the
        // prior turn, emitting .cancelled on voiceEvents. The controller then starts
        // listening for the user's next utterance.
        await orchestrator.cancelAndSubmit(text: "") // VOICE-14 — single call site

        await doTransition(to: .listening(source: source))
        await startSTTSession()
    }

    // MARK: - Private: STT session

    private func startSTTSession() async {
        sttChunkCont?.finish()
        sttChunkCont = nil
        chunkPumpTask?.cancel()
        chunkPumpTask = nil

        let provider = sttFactory()
        let (chunkStream, cont) = AsyncStream<AudioChunk>.makeStream()
        sttChunkCont = cont

        // Track B-5: spawn the audio-chunk pump for this listening session.
        // The default pump is a no-op (back-compat with tests that drive STT
        // via `_testFireSpeechEnd`); production wires a ring-buffer reader
        // via AppDelegate. The pump returns when the consumer Task drops the
        // continuation — `cont.onTermination` propagates Task.isCancelled.
        let pump = self.chunkPump
        cont.onTermination = { _ in /* pump's Task cancellation handles cleanup */ }
        chunkPumpTask = Task.detached { [pump] in
            await pump(cont)
        }

        let partials = provider.transcribe(stream: chunkStream)

        // Drain partial results in a detached task.
        // T-06-05-03: transcript text is NEVER passed to logger or os.log.
        Task { [self] in
            for await _ in partials { /* partials received but not logged */ }

            let finalText: String
            do {
                finalText = try await provider.finalize()
            } catch {
                logger.warning("VoiceController: STT finalize error (not logged for T-06-05-03)")
                finalText = ""
            }

            await self.handleSTTFinalized(text: finalText)
        }
    }

    private func endSTTSession() {
        // Stop the audio pump first so it doesn't yield into a closed continuation.
        chunkPumpTask?.cancel()
        chunkPumpTask = nil
        // Close the audio chunk stream — STT provider will finalize naturally.
        sttChunkCont?.finish()
        sttChunkCont = nil
    }

    private func handleSTTFinalized(text: String) async {
        guard case .listening = state else { return }

        if text.isEmpty {
            await doTransition(to: .idle)
            return
        }

        // Transition to thinking + submit.
        // T-06-05-03: text not logged.
        await doTransition(to: .thinking)
        await orchestrator.submit(text: text)
    }

    // MARK: - Private: state machine

    private func doTransition(to newState: VoiceState) async {
        guard newState != state else { return }
        state = newState
        await emitHUDIntent(hudIntentFor(newState))
        logger.debug("VoiceController: → \(String(describing: newState))")
    }

    private func emitHUDIntent(_ intent: VoiceHudIntent) async {
        voiceHudCont.yield(intent)
    }

    private func hudIntentFor(_ s: VoiceState) -> VoiceHudIntent {
        switch s {
        case .listening:    return .listening
        case .reconfiguring: return .reconfiguring
        default:            return .silent
        }
    }
}
