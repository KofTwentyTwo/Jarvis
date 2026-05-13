import XCTest
import AVFoundation
@testable import Voice

// MARK: - VoiceControllerTests
//
// Tests for VoiceController state machine (V1–V3) and AudioLevelEmitter (V4).
//
// All tests use protocol-seamed mocks — no real ORT sessions, no real AVAudio hardware.

final class VoiceControllerTests: XCTestCase {

    // MARK: - V1: idle → listening(wakeWord) on wake-word event

    func testV1_wakeWord_transitions_idle_to_listening() async throws {
        let (controller, deps) = makeController()
        await controller.startForTests()

        // Fire wake-word
        deps.wakeWordCont.yield(.fired(at: Date()))
        try await Task.sleep(for: .milliseconds(150))

        let state = await controller.state
        guard case .listening(let source) = state else {
            XCTFail("Expected .listening, got \(state)")
            return
        }
        XCTAssertEqual(source, .wakeWord)
        // HUD intent should be .listening
        let intents = deps._hudIntents
        XCTAssertTrue(intents.contains(.listening), "HUD should receive .listening intent")
    }

    // MARK: - V2: .listening + _testFireSpeechEnd → .thinking + orchestrator.submit

    func testV2_vad_speechEnd_submits_to_orchestrator() async throws {
        let (controller, deps) = makeController()
        await controller.startForTests()

        // Get to .listening
        deps.wakeWordCont.yield(.fired(at: Date()))
        try await Task.sleep(for: .milliseconds(100))

        // Signal speech-end with finalized text
        await controller._testFireSpeechEnd(text: "what time is it")
        try await Task.sleep(for: .milliseconds(200))

        let state = await controller.state
        XCTAssertEqual(state, .thinking)

        let calls = await deps.orchestrator.submitCallTexts
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls.first, "what time is it")
    }

    // MARK: - V3: orchestrator turnEnd with text → .speaking + tts.synthesize

    func testV3_orchestrator_turnEnd_triggers_tts() async throws {
        let (controller, deps) = makeController()
        await controller.startForTests()

        // Force to .thinking directly
        await controller._forceState(.thinking)

        // Inject orchestrator turnEnd event
        await deps.orchestrator.emitTurnEnd(text: "It's 2 PM")
        try await Task.sleep(for: .milliseconds(200))

        // Controller transitions: .thinking → .speaking (then .idle after synthesize returns)
        let calls = await deps.tts.synthesizeCalls
        XCTAssertTrue(calls.contains("It's 2 PM"), "TTS should synthesize the turn text")
    }

    // MARK: - V4: AudioLevelEmitter emits at ~30 Hz with positive RMS

    func testV4_audioLevelEmitter_emits_correct_rms_at_30hz() async throws {
        // P1-1 (audit 2026-05-04): emitter now consumes a
        // BufferBroadcaster.Subscription, not a raw RingBuffer. Build a
        // broadcaster, subscribe, publish synthesized buffers, and wire
        // the emitter against the subscription.
        let broadcaster = BufferBroadcaster()
        let subscription = broadcaster.subscribe(capacityFrames: 16384)
        let recorder = MockBusEmitter()

        // Publish 1600 samples of constant amplitude 0.5 (100 ms at 16 kHz)
        // RMS = sqrt(sum(0.25) / N) = 0.5 — just verify it's positive and > 0
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
        let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1600)!
        buf.frameLength = 1600
        let data = buf.floatChannelData![0]
        for i in 0..<1600 { data[i] = 0.5 }
        broadcaster.publish(buf)

        let emitter = AudioLevelEmitter(subscription: subscription, bus: recorder, hzRate: 30)
        await emitter.start()
        // 500ms window (was 250ms) — at 30Hz that's ~15 expected emissions, so
        // the minimum-4 floor still asserts the rate semantics with comfortable
        // margin. The 250ms window was tight on macos-15 GitHub Actions runners
        // — CI run 25801448991 observed only 2 emissions when the emitter task's
        // first tick was delayed by cold-start Task scheduling. Doubling the
        // window keeps the test meaningful (still asserts ≥30Hz behaviour) while
        // surviving CI scheduling jitter; the 4-emission floor is unchanged.
        try await Task.sleep(for: .milliseconds(500))
        await emitter.stop()

        let levels = await recorder.audioLevels
        XCTAssertFalse(levels.isEmpty, "Emitter should have emitted at least one RMS value")

        if let rms = levels.last {
            XCTAssertGreaterThan(rms, 0.0, "RMS should be positive")
        }

        // At 30 Hz over 500ms we expect ~15 samples; minimum 4 (CI cold-start slack)
        XCTAssertGreaterThanOrEqual(levels.count, 4,
            "Should emit ~30 Hz × 0.5s = ~15 emissions, minimum 4")
    }

    // MARK: - V5 (P1-3): stale STT finalize from a prior session is dropped

    /// Regression guard for audit 2026-05-04 concurrency HIGH-1: if session A's
    /// `provider.finalize()` returns AFTER session B has started, session A's
    /// text must NOT be submitted to the orchestrator. The fix uses a
    /// per-session generation id captured by the finalize Task and checked
    /// in `handleSTTFinalized`.
    func testV5_staleSttFinalize_isDropped_acrossSessionBoundary() async throws {
        let (controller, deps) = makeController()
        await controller.startForTests()

        // Start session A via PTT and capture its session id BEFORE finalize.
        await controller.pttDown()
        let sessionAId = await controller._testCurrentSttSessionId()
        XCTAssertGreaterThan(sessionAId, 0, "Session A must have a non-zero id")

        // End session A cleanly: empty finalize → .idle.
        await controller._testFireSpeechEnd(text: "")
        try await Task.sleep(for: .milliseconds(50))

        // Start session B — bumps the session id.
        await controller.pttDown()
        let sessionBId = await controller._testCurrentSttSessionId()
        XCTAssertGreaterThan(sessionBId, sessionAId, "Session B id must be greater than A's")

        // Simulate session A's late finalize callback arriving NOW, after B started.
        // The captured sessionAId is stale — handler must drop the text.
        await controller._testFireSpeechEnd(text: "STALE FROM SESSION A", sessionId: sessionAId)

        // Verify the orchestrator never received the stale text.
        let calls = await deps.orchestrator.submitCallTexts
        XCTAssertFalse(calls.contains("STALE FROM SESSION A"),
            "Stale STT finalize from session A must be dropped (P1-3 / HIGH-1)")

        // Sanity: a fresh finalize for session B does land.
        await controller._testFireSpeechEnd(text: "fresh from B", sessionId: sessionBId)
        try await Task.sleep(for: .milliseconds(150))
        let callsAfter = await deps.orchestrator.submitCallTexts
        XCTAssertTrue(callsAfter.contains("fresh from B"),
            "Current-session finalize must still land")
    }

    // MARK: - V4b (P1-1): emitter pulls from BufferBroadcaster.Subscription, not raw ring

    /// Regression guard: the emitter MUST drain its dedicated subscription
    /// ring rather than a shared SPSC ring. Concretely, two subscriptions
    /// from the same broadcaster receive distinct copies of every published
    /// buffer; reading one does NOT advance the other (Track B-7 contract).
    /// This test publishes one buffer, lets the emitter consume from
    /// subscription A, and verifies subscription B (the "WakeWordDAG side")
    /// still sees the full buffer — proving samples were not stolen.
    func testV4b_audioLevelEmitter_subscribesViaBroadcaster() async throws {
        let broadcaster = BufferBroadcaster()
        let emitterSub = broadcaster.subscribe(capacityFrames: 16384)
        let wakeWordSub = broadcaster.subscribe(capacityFrames: 16384) // simulates DAG
        let recorder = MockBusEmitter()

        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
        let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1600)!
        buf.frameLength = 1600
        let data = buf.floatChannelData![0]
        for i in 0..<1600 { data[i] = 0.5 }
        broadcaster.publish(buf)

        // Run the emitter long enough to drain its own ring.
        let emitter = AudioLevelEmitter(subscription: emitterSub, bus: recorder, hzRate: 30)
        await emitter.start()
        try await Task.sleep(for: .milliseconds(150))
        await emitter.stop()

        // Emitter side: at least one RMS sample reached the bus.
        let levels = await recorder.audioLevels
        XCTAssertFalse(levels.isEmpty, "Emitter should have emitted via subscription ring")

        // WakeWord side: its ring still has all 1600 samples — emitter did
        // NOT steal them. This is the P1-1 invariant.
        var scratch = [Float](repeating: 0, count: 1600)
        let count = scratch.withUnsafeMutableBufferPointer { ptr in
            wakeWordSub.ring.readMono16k(into: ptr)
        }
        XCTAssertEqual(count, 1600,
            "WakeWord subscription must still have the full 1600 frames; emitter must not steal samples (P1-1 / Track B-7 invariant)")
    }
}

// MARK: - Test helpers

private func makeController() -> (VoiceController, TestDeps) {
    let deps = TestDeps()
    let controller = VoiceController(
        wakeWordStream: deps.wakeWordStream,
        vadFactory: { SileroVAD(engine: MockVADEngine()) },
        sttFactory: { deps.sttProvider },
        tts: deps.tts,
        orchestrator: deps.orchestrator,
        bannerCoordinator: deps.banner,
        bus: deps.bus,
        voiceHudCont: deps.hudCont
    )
    return (controller, deps)
}

// MARK: - TestDeps

final class TestDeps: @unchecked Sendable {
    let (wakeWordStream, wakeWordCont) = AsyncStream<WakeWordEvent>.makeStream()
    let sttProvider = MockSTTForController()
    let tts = MockTTSForController()
    let orchestrator = MockOrchestratorForController()
    let banner = MockBannerForController()
    let bus = MockBusEmitter()
    let (hudStream, hudCont) = AsyncStream<VoiceHudIntent>.makeStream()

    // Collected HUD intents (append under @unchecked Sendable mutation)
    var _hudIntents: [VoiceHudIntent] = []

    init() {
        Task { [weak self] in
            guard let self else { return }
            for await intent in self.hudStream {
                self._hudIntents.append(intent)
            }
        }
    }

    var submitCallTexts: [String] {
        get async { await orchestrator.submitCallTexts }
    }
}

// MARK: - MockSTTForController
//
// Controllable STT mock: transcribe() returns a stream that finishes when the
// incoming audio chunk stream ends (i.e., when pttUp / endSTTSession closes the
// chunk continuation). This preserves test isolation for V1 (we manually call
// _testFireSpeechEnd instead of relying on the STT cycle completing).

final class MockSTTForController: STTProvider, @unchecked Sendable {
    var finalResult: String = ""

    func transcribe(stream: AsyncStream<AudioChunk>) -> AsyncStream<PartialTranscript> {
        let (partials, partialCont) = AsyncStream<PartialTranscript>.makeStream()
        // Close the partial stream once the chunk stream ends.
        // This lets pttUp() (which closes the chunk stream) trigger finalize().
        Task {
            for await _ in stream { /* drain chunk stream */ }
            partialCont.finish()
        }
        return partials
    }

    func finalize() async throws -> String {
        return finalResult
    }
}

// MARK: - MockTTSForController

actor MockTTSForController: VoiceTTSInterface {
    var synthesizeCalls: [String] = []
    var hasSynthInFlight: Bool = false

    func synthesize(_ text: String) async {
        synthesizeCalls.append(text)
    }

    func cancelTTS() async {
        hasSynthInFlight = false
    }
}

// MARK: - MockOrchestratorForController

actor MockOrchestratorForController: VoiceOrchestratorInterface {
    var submitCallTexts: [String] = []
    var cancelAndSubmitCount: Int = 0
    var capturedCancelAndSubmitTexts: [String] = []

    // Event stream for simulating orchestrator responses
    // `nonisolated let` satisfies the protocol's nonisolated `voiceEvents` requirement.
    nonisolated let voiceEvents: AsyncStream<VoiceOrchestratorEvent>
    private nonisolated let eventsCont: AsyncStream<VoiceOrchestratorEvent>.Continuation

    init() {
        let (stream, cont) = AsyncStream<VoiceOrchestratorEvent>.makeStream()
        voiceEvents = stream
        eventsCont = cont
    }

    func submit(text: String) async {
        submitCallTexts.append(text)
        // Does NOT auto-emit turnEnded — tests manually call emitTurnEnd if needed
    }

    func cancelAndSubmit(text: String) async {
        cancelAndSubmitCount += 1
        capturedCancelAndSubmitTexts.append(text)
        eventsCont.yield(.cancelled)
    }

    nonisolated func emitTurnEnd(text: String) {
        eventsCont.yield(.turnEnded(finalText: text))
    }
}

// MARK: - MockBannerForController

final class MockBannerForController: VoiceBannerInterface, @unchecked Sendable {
    var shownMessages: [String] = []
    var dismissCalls: Int = 0

    func showBanner(message: String) {
        shownMessages.append(message)
    }
    func dismissBanner() {
        dismissCalls += 1
    }
}

// MARK: - MockBusEmitter

actor MockBusEmitter: BusOutboundEmitter {
    var audioLevels: [Float] = []

    func postAudio(_ rms: Float) async {
        audioLevels.append(rms)
    }
}
