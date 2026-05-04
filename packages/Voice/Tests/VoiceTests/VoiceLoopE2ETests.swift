import AVFoundation
import XCTest
@testable import Voice

// MARK: - VoiceLoopE2ETests
//
// Track B-5 (2026-05-03 voice audit fix): end-to-end wiring proof for the
// chunk-pump → STT → orchestrator chain landed under track B-4 + B-5.
//
// What's exercised:
//   1. VoiceController spawns the production-style chunk pump on transition
//      to `.listening`.
//   2. The pump yields a deterministic batch of `AudioChunk`s into the STT
//      provider's input stream.
//   3. The STT provider records the chunks it received and returns a known
//      final transcript when the chunk stream ends.
//   4. `endSTTSession` (driven by `pttUp`) closes the chunk continuation,
//      which (via `cont.onTermination` + Task cancellation) shuts the pump
//      down — no leaked Task on session end.
//   5. The transcript propagates `STTProvider.finalize → handleSTTFinalized
//      → orchestrator.submit`.
//
// What's NOT exercised here (Track B-5+ work):
//   - Real `AudioGraphOwner` hardware path. That requires a mic + entitlement
//     and is HUMAN-UAT territory (Plan 06-05 Task 4).
//   - VAD-gated speech-end detection. The current pipeline closes the STT
//     session on `pttUp`; a follow-up wires Silero `.speechEnd` to the same
//     path.
//   - Real macOS 26 `SpeechAnalyzer`. Covered by `LiveSpeechAnalyzerBridge`'s
//     internal wiring (Track B-4) — exercised in HUMAN-UAT, not unit tests.

final class VoiceLoopE2ETests: XCTestCase {

    // MARK: - E1: chunk-pump audio flows STT → orchestrator.submit

    func testE1_chunkPump_audio_reaches_orchestrator_as_transcript() async throws {
        let presetChunks: [AudioChunk] = [
            AudioChunk(pcm16k: Array(repeating: 0.10, count: 1024)),
            AudioChunk(pcm16k: Array(repeating: 0.12, count: 1024)),
            AudioChunk(pcm16k: Array(repeating: 0.08, count: 1024))
        ]
        let expectedTranscript = "track b-five wiring proof"

        let stt = CapturingSTTProvider(finalResult: expectedTranscript)
        let orchestrator = MockOrchestratorForController()
        let tts = MockTTSForController()
        let banner = MockBannerForController()
        let bus = MockBusEmitter()
        let (_, hudCont) = AsyncStream<VoiceHudIntent>.makeStream()
        let (wwStream, _) = AsyncStream<WakeWordEvent>.makeStream()

        // Chunk pump: yield each preset chunk, then idle until cancelled.
        // The pump exits cleanly via `Task.isCancelled` once endSTTSession
        // tears down its task.
        let chunkPump: @Sendable (AsyncStream<AudioChunk>.Continuation) async -> Void = { cont in
            for chunk in presetChunks {
                guard !Task.isCancelled else { cont.finish(); return }
                cont.yield(chunk)
                try? await Task.sleep(nanoseconds: 5_000_000)  // 5ms between chunks
            }
            // Idle so pttUp's cancel is what ends the session, not pump exhaustion.
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 10_000_000)
            }
            cont.finish()
        }

        let controller = VoiceController(
            wakeWordStream: wwStream,
            vadFactory: { SileroVAD(engine: MockVADEngine()) },
            sttFactory: { stt },
            tts: tts,
            orchestrator: orchestrator,
            bannerCoordinator: banner,
            bus: bus,
            voiceHudCont: hudCont,
            chunkPump: chunkPump
        )

        await controller.startForTests()

        // Drive the listening transition via PTT (bypasses wake-word DAG).
        await controller.pttDown()

        // Allow time for the pump to deliver its presets.
        try await Task.sleep(for: .milliseconds(80))

        // End the STT session — pttUp closes the chunk continuation, which
        // lets `CapturingSTTProvider.transcribe`'s drain Task finish, which
        // unblocks `provider.finalize() → handleSTTFinalized → submit(text:)`.
        await controller.pttUp()

        // Wait for the submit to land.
        try await Task.sleep(for: .milliseconds(120))

        // Assertions
        let submitTexts = await orchestrator.submitCallTexts
        XCTAssertEqual(submitTexts, [expectedTranscript],
            "E1: orchestrator should receive exactly the STT final transcript once")

        let chunksSeen = await stt.receivedChunkCount
        XCTAssertGreaterThanOrEqual(chunksSeen, 1,
            "E1: STT should observe at least one chunk from the pump (got \(chunksSeen))")
        XCTAssertLessThanOrEqual(chunksSeen, presetChunks.count,
            "E1: STT should not see more chunks than the pump yields (got \(chunksSeen))")

        await controller.shutdown()
    }

    // MARK: - E2: empty pump → STT finalizes empty → no submit

    func testE2_pumpYieldsNoChunks_emptyTranscript_skipsSubmit() async throws {
        let stt = CapturingSTTProvider(finalResult: "")
        let orchestrator = MockOrchestratorForController()
        let tts = MockTTSForController()
        let banner = MockBannerForController()
        let bus = MockBusEmitter()
        let (_, hudCont) = AsyncStream<VoiceHudIntent>.makeStream()
        let (wwStream, _) = AsyncStream<WakeWordEvent>.makeStream()

        // Pump that yields nothing, just idles.
        let chunkPump: @Sendable (AsyncStream<AudioChunk>.Continuation) async -> Void = { cont in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 10_000_000)
            }
            cont.finish()
        }

        let controller = VoiceController(
            wakeWordStream: wwStream,
            vadFactory: { SileroVAD(engine: MockVADEngine()) },
            sttFactory: { stt },
            tts: tts,
            orchestrator: orchestrator,
            bannerCoordinator: banner,
            bus: bus,
            voiceHudCont: hudCont,
            chunkPump: chunkPump
        )

        await controller.startForTests()
        await controller.pttDown()
        try await Task.sleep(for: .milliseconds(40))
        await controller.pttUp()
        try await Task.sleep(for: .milliseconds(80))

        // VoiceController.handleSTTFinalized treats empty text as
        // "transition straight to .idle without submitting" — see line 336.
        let submits = await orchestrator.submitCallTexts
        XCTAssertEqual(submits.count, 0,
            "E2: empty STT result must NOT trigger orchestrator.submit")

        let state = await controller.state
        XCTAssertEqual(state, .idle,
            "E2: after empty STT cycle, controller should return to .idle")

        await controller.shutdown()
    }

    // MARK: - E3: pump task is cancelled on session end (no leak)

    func testE3_chunkPumpTask_cancelledOnSessionEnd() async throws {
        let pumpExited = AtomicFlag()
        let stt = CapturingSTTProvider(finalResult: "anything")
        let orchestrator = MockOrchestratorForController()
        let tts = MockTTSForController()
        let banner = MockBannerForController()
        let bus = MockBusEmitter()
        let (_, hudCont) = AsyncStream<VoiceHudIntent>.makeStream()
        let (wwStream, _) = AsyncStream<WakeWordEvent>.makeStream()

        let chunkPump: @Sendable (AsyncStream<AudioChunk>.Continuation) async -> Void = { [pumpExited] cont in
            // Loop until cancelled; flip the flag on exit.
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 5_000_000)
            }
            cont.finish()
            await pumpExited.set()
        }

        let controller = VoiceController(
            wakeWordStream: wwStream,
            vadFactory: { SileroVAD(engine: MockVADEngine()) },
            sttFactory: { stt },
            tts: tts,
            orchestrator: orchestrator,
            bannerCoordinator: banner,
            bus: bus,
            voiceHudCont: hudCont,
            chunkPump: chunkPump
        )

        await controller.startForTests()
        await controller.pttDown()
        try await Task.sleep(for: .milliseconds(20))
        await controller.pttUp()
        try await Task.sleep(for: .milliseconds(80))

        let exited = await pumpExited.get()
        XCTAssertTrue(exited,
            "E3: chunkPump task must exit after pttUp closes the session (no leaked Task)")

        await controller.shutdown()
    }
}

// MARK: - CapturingSTTProvider

/// STT mock that counts incoming AudioChunks, drains the chunk stream until
/// it ends, then returns `finalResult` from `finalize()`. Used to prove the
/// chunk-pump → STT path actually delivers audio.
///
/// Uses an internal counter actor to satisfy Swift 6 strict concurrency —
/// `NSLock.lock()` is unavailable in async contexts.
final class CapturingSTTProvider: STTProvider, @unchecked Sendable {
    let finalResult: String
    private let counter = Counter()

    init(finalResult: String) {
        self.finalResult = finalResult
    }

    var receivedChunkCount: Int {
        get async { await counter.value }
    }

    func transcribe(stream: AsyncStream<AudioChunk>) -> AsyncStream<PartialTranscript> {
        let (partials, partialCont) = AsyncStream<PartialTranscript>.makeStream()
        let counter = self.counter
        Task {
            for await _ in stream {
                await counter.increment()
            }
            partialCont.finish()
        }
        return partials
    }

    func finalize() async throws -> String {
        finalResult
    }

    actor Counter {
        var value: Int = 0
        func increment() { value += 1 }
    }
}

// MARK: - AtomicFlag

actor AtomicFlag {
    private var flagValue = false
    func set() { flagValue = true }
    func get() -> Bool { flagValue }
}
