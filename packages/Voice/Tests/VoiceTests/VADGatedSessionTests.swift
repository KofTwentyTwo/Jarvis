import XCTest
@testable import Voice

// MARK: - VADGatedSessionTests
//
// Track B-6 (2026-05-03 voice audit fix): VAD-gated STT session end.
//
// Today only `pttUp()` closes the chunk continuation. The hands-free wake-word
// path (Hey Jarvis → speak → pause → auto-finalize) needs Silero VAD's
// `.speechEnd` decision to also trigger `endSTTSession`, otherwise the user
// has no way to release a hotkey they didn't press.
//
// What's exercised:
//   1. The chunk-pump path (Track B-5) feeds AudioChunks of variable size.
//      VoiceController slices each chunk into 512-sample VAD windows.
//   2. After a `.speechStart` decision arms the session, sustained silence
//      after `.speechEnd` (hangover threshold) triggers `endSTTSession`
//      automatically — exactly as `pttUp` would.
//   3. Brief silence shorter than the hangover does NOT prematurely finalize.
//   4. PTT path continues to work unchanged (regression).
//
// Anti-pattern callouts:
//   - DO NOT block on `await analyzer.finish()` synchronously inside the VAD
//     handler — wrap in a Task so VAD events don't deadlock on the analyzer
//     completion path. Verified by testVAD1 (which does see an end-driven
//     finalize).
//   - T-06-05-03: VAD chunk PCM never logged. The implementation does NOT
//     emit log messages with chunk content; only state-machine transitions.

final class VADGatedSessionTests: XCTestCase {

    // MARK: - Helpers

    /// Build a chunkPump that yields N 512-sample AudioChunks then idles
    /// until cancelled. One AudioChunk produces one VAD decision.
    private func makePump(chunkCount: Int) -> @Sendable (AsyncStream<AudioChunk>.Continuation) async -> Void {
        return { cont in
            for _ in 0..<chunkCount {
                guard !Task.isCancelled else { cont.finish(); return }
                cont.yield(AudioChunk(pcm16k: Array(repeating: Float(0.1), count: 512)))
                try? await Task.sleep(nanoseconds: 2_000_000)  // 2ms
            }
            // Idle until cancelled so any session-end driver is exercised.
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 5_000_000)
            }
            cont.finish()
        }
    }

    // MARK: - VAD-1: speechEnd + hangover triggers session end

    func testVAD1_speechEnd_after_hangover_finalizes_and_submits() async throws {
        // Probabilities chosen to produce: speechStart, speech, speechEnd,
        // silence×8 (well past 5-chunk hangover).
        let probs: [Float] = [0.9, 0.9, 0.1, 0.1, 0.1, 0.1, 0.1, 0.1, 0.1, 0.1, 0.1]
        let mockEngine = MockVADEngine(probabilities: probs)

        let stt = CapturingSTTProvider(finalResult: "vad gated finalize")
        let orchestrator = MockOrchestratorForController()
        let tts = MockTTSForController()
        let banner = MockBannerForController()
        let bus = MockBusEmitter()
        let (_, hudCont) = AsyncStream<VoiceHudIntent>.makeStream()
        let (wwStream, _) = AsyncStream<WakeWordEvent>.makeStream()

        let controller = VoiceController(
            wakeWordStream: wwStream,
            vadFactory: { SileroVAD(engine: mockEngine) },
            sttFactory: { stt },
            tts: tts,
            orchestrator: orchestrator,
            bannerCoordinator: banner,
            bus: bus,
            voiceHudCont: hudCont,
            chunkPump: makePump(chunkCount: probs.count)
        )

        await controller.startForTests()
        await controller.pttDown()

        // Allow the pump to deliver chunks + VAD to process them + hangover
        // counter to trip + submit to land.
        try await Task.sleep(for: .milliseconds(300))

        let submits = await orchestrator.submitCallTexts
        XCTAssertEqual(submits, ["vad gated finalize"],
            "VAD-1: VAD-driven .speechEnd + hangover should trigger orchestrator.submit (got \(submits))")

        // Session should be back in idle or transitioning out of listening
        // (orchestrator.submit moves us to .thinking).
        let state = await controller.state
        XCTAssertNotEqual(state, .listening(source: .ptt),
            "VAD-1: controller must leave .listening once VAD finalizes")
        XCTAssertNotEqual(state, .listening(source: .wakeWord),
            "VAD-1: controller must leave .listening once VAD finalizes")

        await controller.shutdown()
    }

    // MARK: - VAD-2: PTT regression — pttUp still works

    func testVAD2_pttUp_still_finalizes_when_VAD_silent() async throws {
        // VAD never sees speech (probs all silence), so it never triggers end.
        // pttUp must still close the session.
        let probs: [Float] = Array(repeating: 0.1, count: 20)
        let mockEngine = MockVADEngine(probabilities: probs)

        let stt = CapturingSTTProvider(finalResult: "ptt path still works")
        let orchestrator = MockOrchestratorForController()
        let tts = MockTTSForController()
        let banner = MockBannerForController()
        let bus = MockBusEmitter()
        let (_, hudCont) = AsyncStream<VoiceHudIntent>.makeStream()
        let (wwStream, _) = AsyncStream<WakeWordEvent>.makeStream()

        let controller = VoiceController(
            wakeWordStream: wwStream,
            vadFactory: { SileroVAD(engine: mockEngine) },
            sttFactory: { stt },
            tts: tts,
            orchestrator: orchestrator,
            bannerCoordinator: banner,
            bus: bus,
            voiceHudCont: hudCont,
            chunkPump: makePump(chunkCount: 4)
        )

        await controller.startForTests()
        await controller.pttDown()
        try await Task.sleep(for: .milliseconds(50))
        await controller.pttUp()
        try await Task.sleep(for: .milliseconds(120))

        let submits = await orchestrator.submitCallTexts
        XCTAssertEqual(submits, ["ptt path still works"],
            "VAD-2: pttUp must still finalize the session even with VAD wired")

        await controller.shutdown()
    }

    // MARK: - VAD-4: speechStart without speechEnd does not close

    func testVAD4_speechStart_without_speechEnd_keeps_session_open() async throws {
        // speechStart followed by sustained speech — no .speechEnd — must NOT
        // finalize.
        let probs: [Float] = [0.9, 0.9, 0.9, 0.9, 0.9, 0.9, 0.9, 0.9]
        let mockEngine = MockVADEngine(probabilities: probs)

        let stt = CapturingSTTProvider(finalResult: "should not be submitted")
        let orchestrator = MockOrchestratorForController()
        let tts = MockTTSForController()
        let banner = MockBannerForController()
        let bus = MockBusEmitter()
        let (_, hudCont) = AsyncStream<VoiceHudIntent>.makeStream()
        let (wwStream, _) = AsyncStream<WakeWordEvent>.makeStream()

        let controller = VoiceController(
            wakeWordStream: wwStream,
            vadFactory: { SileroVAD(engine: mockEngine) },
            sttFactory: { stt },
            tts: tts,
            orchestrator: orchestrator,
            bannerCoordinator: banner,
            bus: bus,
            voiceHudCont: hudCont,
            chunkPump: makePump(chunkCount: probs.count)
        )

        await controller.startForTests()
        await controller.pttDown()

        // Long enough for all chunks + VAD inference to run.
        try await Task.sleep(for: .milliseconds(150))

        let submits = await orchestrator.submitCallTexts
        XCTAssertTrue(submits.isEmpty,
            "VAD-4: sustained speech (no .speechEnd) must NOT trigger submit (got \(submits))")

        // Still listening because session has not been ended.
        let state = await controller.state
        if case .listening = state {
            // expected
        } else {
            XCTFail("VAD-4: controller should remain .listening; got \(state)")
        }

        await controller.shutdown()
    }

    // MARK: - VAD-5: brief silence (shorter than hangover) followed by speech does not close

    func testVAD5_speechResume_within_hangover_cancels_finalize() async throws {
        // Sequence: speechStart, speech, speechEnd, silence×2 (under
        // hangover threshold of 5), speechStart (resume), speech×4
        // — must NOT submit.
        let probs: [Float] = [
            0.9,  // speechStart
            0.9,  // speech
            0.1,  // speechEnd
            0.1,  // silence (1)
            0.1,  // silence (2)
            0.9,  // speechStart (resume — cancels pending finalize)
            0.9, 0.9, 0.9, 0.9
        ]
        let mockEngine = MockVADEngine(probabilities: probs)

        let stt = CapturingSTTProvider(finalResult: "should not finalize prematurely")
        let orchestrator = MockOrchestratorForController()
        let tts = MockTTSForController()
        let banner = MockBannerForController()
        let bus = MockBusEmitter()
        let (_, hudCont) = AsyncStream<VoiceHudIntent>.makeStream()
        let (wwStream, _) = AsyncStream<WakeWordEvent>.makeStream()

        let controller = VoiceController(
            wakeWordStream: wwStream,
            vadFactory: { SileroVAD(engine: mockEngine) },
            sttFactory: { stt },
            tts: tts,
            orchestrator: orchestrator,
            bannerCoordinator: banner,
            bus: bus,
            voiceHudCont: hudCont,
            chunkPump: makePump(chunkCount: probs.count)
        )

        await controller.startForTests()
        await controller.pttDown()

        try await Task.sleep(for: .milliseconds(200))

        let submits = await orchestrator.submitCallTexts
        XCTAssertTrue(submits.isEmpty,
            "VAD-5: speech resumption within hangover must cancel pending finalize (got \(submits))")

        await controller.shutdown()
    }
}
