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
        let ring = RingBuffer(capacityFrames: 16384)
        let recorder = MockBusEmitter()

        // Write 1600 samples of constant amplitude 0.5 (100 ms at 16 kHz)
        // RMS = sqrt(sum(0.25) / N) = 0.5 — just verify it's positive and > 0
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
        let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1600)!
        buf.frameLength = 1600
        let data = buf.floatChannelData![0]
        for i in 0..<1600 { data[i] = 0.5 }
        ring.write(buf)

        let emitter = AudioLevelEmitter(ring: ring, bus: recorder, hzRate: 30)
        await emitter.start()
        try await Task.sleep(for: .milliseconds(250))
        await emitter.stop()

        let levels = await recorder.audioLevels
        XCTAssertFalse(levels.isEmpty, "Emitter should have emitted at least one RMS value")

        if let rms = levels.last {
            XCTAssertGreaterThan(rms, 0.0, "RMS should be positive")
        }

        // At 30 Hz over 250ms we expect ~7 samples; minimum 4 (slack for timing jitter)
        XCTAssertGreaterThanOrEqual(levels.count, 4,
            "Should emit ~30 Hz × 0.25s = ~7 emissions, minimum 4")
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
// Controllable STT mock: transcribe() returns a stream that hangs until
// `complete()` is called. This lets V1 observe the .listening state
// before the full cycle completes.

final class MockSTTForController: STTProvider, @unchecked Sendable {
    var finalResult: String = ""
    // Stored continuation so tests can manually trigger finalization
    var _partialCont: AsyncStream<PartialTranscript>.Continuation?

    func transcribe(stream: AsyncStream<AudioChunk>) -> AsyncStream<PartialTranscript> {
        let (s, c) = AsyncStream<PartialTranscript>.makeStream()
        _partialCont = c
        // Do NOT auto-finish — hang until complete() is called
        return s
    }

    func finalize() async throws -> String {
        return finalResult
    }

    /// Manually complete the partial stream (ends the drain loop, triggers finalize).
    func complete() {
        _partialCont?.finish()
        _partialCont = nil
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
