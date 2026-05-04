import Foundation
import OSLog

private let logger = Logger(subsystem: "com.koftwentytwo.jarvis", category: "VoiceController")

/// Top-level voice state machine: the actor stitching the five Phase 6
/// subsystems into one `idle / listening / thinking / speaking` lifecycle.
///
/// Wake word fires → `listening` (STT session opens, chunk pump spawns) → VAD
/// `.speechEnd` + 5-chunk hangover → `thinking` (orchestrator submits) → token
/// stream + tool calls → `speaking` (TTS) → `idle`. Push-to-talk and barge-in
/// take alternate paths through the same actor; the state field is the truth.
///
/// ## Subsystems consumed
/// - `WakeWordDAG.wakeWordStream` (Plan 06-02)
/// - `SileroVAD` + `STTProvider` (Plan 06-03) via factory closures
/// - `VoiceTTSInterface` → `TTSEngineActor` (Plan 06-04)
/// - `VoiceOrchestratorInterface` → `AgentOrchestrator` adapter (Plan 04-04)
/// - `VoiceBannerInterface` → `HUDBannerCoordinator` (Phase 1)
/// - `BusOutboundEmitter` → `OutboundBatcher` (Phase 2) for audio-level RMS
///
/// ## Threading
/// Actor isolation. State mutation only through actor methods. The chunk
/// pump runs as a detached `Task` per session, cancelled on `endSTTSession`
/// and on `shutdown`. The VAD interceptor task forwards chunks to STT and
/// runs Silero per 512-sample window in parallel, never blocking the chunk
/// path.
///
/// ## Anti-patterns enforced (CLAUDE.md voice-stack rules)
/// - **VOICE-14:** single `cancelAndSubmit` call site (in `bargeIn()`) — grep gate.
/// - **T-06-05-03:** `transcriptAccumulator` is NEVER logged.
/// - **T-06-05-02:** AEC banner routes through `VoiceBannerInterface` (AppKit) — no webview modal.
/// - **T-06-05-04:** 200 ms barge-in debounce (`BargeInTests` B4).
/// - **VOICE-12:** `pttDown()` / `pttUp()` work even when wake-word is muted.
///
/// ## See also
/// - `AudioGraphOwner` — owns the engine + ring buffers + broadcaster
/// - `BufferBroadcaster` — multi-consumer fan-out used by the chunk pump
/// - `App/Voice/VoiceOrchestratorAdapter.swift` — bridge to `AgentOrchestrator`
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

    /// Track B-6: per-session VAD interceptor Task. Reads the pump output,
    /// runs Silero VAD inference per 512-sample window, forwards chunks to
    /// the STT continuation, and triggers `endSTTSession` when sustained
    /// silence after `.speechEnd` exceeds the hangover threshold.
    private var vadInterceptorTask: Task<Void, Never>?

    /// P1-3 (audit 2026-05-04, concurrency HIGH-1): per-session STT finalize
    /// drain Task. Drains partials, calls `provider.finalize()`, then
    /// dispatches `handleSTTFinalized`. Stored so `shutdown` can cancel
    /// it and avoid leaking the actor past process teardown.
    private var sttFinalizeTask: Task<Void, Never>?

    /// P1-3 (audit 2026-05-04, concurrency HIGH-1): monotonic STT session
    /// id. Incremented in `startSTTSession`; captured into the finalize
    /// Task; checked in `handleSTTFinalized` to drop stale finalize
    /// callbacks from a prior session whose Whisper / SpeechAnalyzer
    /// `finalize()` returned after a new session already started.
    private var sttSessionId: UInt64 = 0

    /// Track B-6: hangover threshold (number of consecutive 32ms silence
    /// windows after `.speechEnd` before auto-finalize). 5 chunks = 160 ms
    /// — comfortable margin over Silero's frame jitter while still letting
    /// hands-free turns finalize within ~200 ms of the user pausing.
    private static let vadHangoverChunks: Int = 5

    /// Exposed for AppDelegate to wire the audio-level emitter.
    public var audioLevelEmitter: AudioLevelEmitter?

    /// Cross-actor setter for `audioLevelEmitter`. AppDelegate's
    /// `@MainActor` install code can't reach the actor-isolated `var`
    /// directly under Swift 6 mode; this method provides the seam.
    public func setAudioLevelEmitter(_ emitter: AudioLevelEmitter?) {
        self.audioLevelEmitter = emitter
    }

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
        vadInterceptorTask?.cancel()
        // P1-3: cancel the stored finalize Task so it doesn't outlive
        // shutdown. The Task captures `[weak self]` and the controller is
        // about to drop, but explicit cancellation is hygienic and prevents
        // the underlying STT provider's finalize() from running past teardown.
        sttFinalizeTask?.cancel()
        wakeWordTask = nil
        orchestratorTask = nil
        chunkPumpTask = nil
        vadInterceptorTask = nil
        sttFinalizeTask = nil
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
        await endSTTSession()
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
    /// `internal` + `@testable import Voice` keeps this out of the public
    /// ABI so production callers (App, Harness) cannot reach in.
    internal func _forceState(_ newState: VoiceState) async {
        state = newState
    }

    /// Simulate a VAD speech-end + STT finalization with given text. Tests only.
    internal func _testFireSpeechEnd(text: String = "") async {
        await handleSTTFinalized(text: text)
    }

    /// P1-3 stale-text seam (tests only). Invokes the generation-guarded
    /// finalize path with an explicit `sessionId` so tests can simulate a
    /// finalize callback from a prior session arriving after the next
    /// session has started.
    internal func _testFireSpeechEnd(text: String, sessionId: UInt64) async {
        await handleSTTFinalized(text: text, sessionId: sessionId)
    }

    /// P1-3 stale-text seam (tests only). Returns the current session id so
    /// tests can capture it before triggering a session boundary.
    internal func _testCurrentSttSessionId() -> UInt64 {
        sttSessionId
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
        vadInterceptorTask?.cancel()
        vadInterceptorTask = nil
        // P1-3: cancel any prior session's finalize drain so a slow
        // SpeechAnalyzer/WhisperKit finalize from session A doesn't race
        // session B. Generation-id below is the second guard.
        sttFinalizeTask?.cancel()
        sttFinalizeTask = nil

        // P1-3: bump the session id so any in-flight finalize Task whose
        // captured id no longer matches will early-return in handleSTTFinalized.
        sttSessionId &+= 1
        let sessionId = sttSessionId

        let provider = sttFactory()
        let (chunkStream, cont) = AsyncStream<AudioChunk>.makeStream()
        sttChunkCont = cont

        // Track B-5: spawn the audio-chunk pump for this listening session.
        // The default pump is a no-op (back-compat with tests that drive STT
        // via `_testFireSpeechEnd`); production wires a ring-buffer reader
        // via AppDelegate.
        //
        // Track B-6: the pump's chunks no longer flow directly into the STT
        // continuation. Instead they pass through a VAD interceptor that
        // forwards each chunk to STT *and* runs Silero VAD inference per
        // 512-sample window. On sustained silence after `.speechEnd` (the
        // hangover), the interceptor closes the session — exactly as
        // `pttUp` would, but driven by the model rather than a hotkey.
        //
        // Anti-pattern note (Plan 06-03): the VAD `.speechEnd` handler MUST
        // NOT block on `await analyzer.finish()` synchronously — it spawns
        // a Task to call `endSTTSession()` so VAD events don't deadlock on
        // the analyzer completion path. `SpeechAnalyzerSTT` already wraps
        // `finish()` in a Task; this preserves that contract.
        let pump = self.chunkPump
        let (rawStream, rawCont) = AsyncStream<AudioChunk>.makeStream()
        rawCont.onTermination = { _ in /* pump's Task cancellation handles cleanup */ }
        chunkPumpTask = Task.detached { [pump] in
            await pump(rawCont)
        }

        let vad = vadFactory()
        let hangover = Self.vadHangoverChunks
        vadInterceptorTask = Task { [weak self] in
            await self?.runVADInterceptor(
                rawStream: rawStream,
                forwardCont: cont,
                vad: vad,
                hangoverChunks: hangover
            )
        }

        let partials = provider.transcribe(stream: chunkStream)

        // Drain partial results in a stored task (P1-3, audit 2026-05-04).
        // The Task is now retained on `sttFinalizeTask` so `shutdown` can
        // cancel it explicitly. Capture is `[weak self]` instead of `[self]`
        // to avoid retaining the actor past process teardown. The captured
        // `sessionId` plus the check in `handleSTTFinalized` drops finalize
        // callbacks whose session was superseded before `provider.finalize()`
        // returned.
        // T-06-05-03: transcript text is NEVER passed to logger or os.log.
        sttFinalizeTask = Task { [weak self, provider] in
            for await _ in partials { /* partials received but not logged */ }

            let finalText: String
            do {
                finalText = try await provider.finalize()
            } catch {
                logger.warning("VoiceController: STT finalize error (not logged for T-06-05-03)")
                finalText = ""
            }

            await self?.handleSTTFinalized(text: finalText, sessionId: sessionId)
        }
    }

    /// Track B-6: drain `rawStream` (pump output), slice each AudioChunk into
    /// 512-sample VAD windows, forward chunks to STT, and trigger
    /// `endSTTSession()` once `hangoverChunks` consecutive silence windows
    /// follow a `.speechEnd` decision.
    ///
    /// Hangover semantics:
    ///  - `.speechStart` arms the session and resets any pending finalize.
    ///  - `.speechEnd` starts counting silence chunks.
    ///  - `.silence` increments the counter while in pending state.
    ///  - `.speech` (mid-utterance) cancels the pending finalize.
    ///  - When the counter reaches `hangoverChunks`, fire `endSTTSession()`
    ///    via a Task to avoid synchronous re-entry.
    ///
    /// T-06-05-03: PCM samples and chunk content are NEVER logged.
    private func runVADInterceptor(
        rawStream: AsyncStream<AudioChunk>,
        forwardCont: AsyncStream<AudioChunk>.Continuation,
        vad: SileroVAD,
        hangoverChunks: Int
    ) async {
        var armed = false
        var pendingFinalize = false
        var silenceCount = 0
        // Carry-over buffer for chunks whose sample count isn't a multiple
        // of 512. Production AppDelegate yields up to 1024 samples; tests
        // yield exactly 512. Either path is supported.
        var carry: [Float] = []
        // Track whether we've already triggered finalize this session, so
        // we don't double-fire on chunks delivered between trigger and
        // pump cancellation.
        var didTrigger = false

        for await chunk in rawStream {
            // Forward to STT regardless of VAD decision — VAD only gates
            // session end, never chunk content.
            forwardCont.yield(chunk)

            if didTrigger { continue }

            // Build a contiguous sample window: carry + current chunk.
            var samples = carry
            samples.append(contentsOf: chunk.pcm16k)

            var idx = 0
            while idx + 512 <= samples.count {
                let window = Array(samples[idx..<(idx + 512)])
                idx += 512
                let decision: VADDecision
                do {
                    decision = try window.withUnsafeBufferPointer { ptr in
                        try vad.feed(ptr)
                    }
                } catch {
                    // Inference failure: keep the session alive (prefer
                    // letting pttUp / explicit finalize close it).
                    continue
                }

                switch decision {
                case .speechStart:
                    armed = true
                    pendingFinalize = false
                    silenceCount = 0
                case .speech:
                    pendingFinalize = false
                    silenceCount = 0
                case .speechEnd:
                    if armed {
                        pendingFinalize = true
                        silenceCount = 1
                    }
                case .silence:
                    if pendingFinalize {
                        silenceCount += 1
                    }
                }

                if pendingFinalize && silenceCount >= hangoverChunks {
                    didTrigger = true
                    // Wrap in a Task to avoid blocking the VAD loop on the
                    // analyzer finalize path — anti-pattern from Plan 06-03.
                    Task { [weak self] in
                        await self?.endSTTSession()
                    }
                    break
                }
            }

            // Save tail samples (< 512) for next chunk.
            if idx < samples.count {
                carry = Array(samples[idx..<samples.count])
            } else {
                carry.removeAll(keepingCapacity: true)
            }
        }
    }

    private func endSTTSession() async {
        // Stop the audio pump first so it doesn't yield into a closed continuation.
        chunkPumpTask?.cancel()
        chunkPumpTask = nil
        vadInterceptorTask?.cancel()
        vadInterceptorTask = nil
        // Close the audio chunk stream — STT provider will finalize naturally.
        sttChunkCont?.finish()
        sttChunkCont = nil
    }

    private func handleSTTFinalized(text: String) async {
        // Back-compat seam for tests that fire speech-end without a session id.
        await handleSTTFinalized(text: text, sessionId: sttSessionId)
    }

    /// P1-3 (audit 2026-05-04, concurrency HIGH-1): generation-guarded
    /// finalize handler. The captured `sessionId` is compared against the
    /// current `sttSessionId`; mismatches indicate a stale finalize from a
    /// prior session whose `provider.finalize()` returned late, after a
    /// new session has already started. Drop stale text rather than
    /// submit it as if it belonged to the current turn.
    private func handleSTTFinalized(text: String, sessionId: UInt64) async {
        guard sessionId == sttSessionId else {
            logger.debug("VoiceController: stale STT finalize dropped (session=\(sessionId) current=\(self.sttSessionId))")
            return
        }
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
        let priorState = state
        state = newState

        // P1-1 (audit 2026-05-04): drive the audio-level emitter from the
        // listening lifecycle so the HUD ring pulses on real mic RMS.
        // Only actually starts/stops when crossing the listening boundary
        // (idle/thinking/speaking → listening to start; listening → other to stop).
        let wasListening: Bool = { if case .listening = priorState { return true } else { return false } }()
        let isListening: Bool = { if case .listening = newState { return true } else { return false } }()
        if !wasListening && isListening {
            await audioLevelEmitter?.start()
        } else if wasListening && !isListening {
            await audioLevelEmitter?.stop()
        }

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
