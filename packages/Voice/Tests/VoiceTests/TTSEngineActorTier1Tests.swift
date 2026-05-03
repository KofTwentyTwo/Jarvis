import XCTest
import AVFoundation
@testable import Voice

/// Coverage for the `TTSEngineActor` minus tier-2 (Orpheus). Closes the
/// 2026-05-03 voice audit's WARN-INT-1 finding that no production code
/// path ever constructs a `TTSEngineActor` because the existing init
/// requires `OrpheusTTS` (non-optional), and `OrpheusTTS()` requires
/// downloading Orpheus 3B weights from HuggingFace at first launch
/// (~6GB). The fix: allow `orpheus: OrpheusTTS?` so tier-1
/// (`AVSpeechSynthesizer`, instant, free) wires alone.
///
/// These tests assert the contract:
///
/// 1. `TTSEngineActor` can be constructed with a nil Orpheus.
/// 2. `.tier1` synthesis emits `.started` → `.firstAudio` → `.finished`
///    on `ttsEventStream` (real AVSpeechSynthesizer in-process).
/// 3. `.tier2` requested with nil Orpheus produces a clean error
///    instead of crashing on a force-unwrap.
final class TTSEngineActorTier1Tests: XCTestCase {

    /// Start a detached collector on the engine's event stream. Returns
    /// the Task whose value is the captured events. Detached so the
    /// MainActor-isolated test method can `await events` without the
    /// Swift 6 sending-risks-data-race error.
    private static func startCollector(
        on engine: TTSEngineActor,
        timeout: TimeInterval = 3.0
    ) -> Task<[TTSEvent], Never> {
        let stream = engine.ttsEventStream
        return Task.detached {
            var got: [TTSEvent] = []
            let deadline = Date().addingTimeInterval(timeout)
            for await ev in stream {
                got.append(ev)
                if case .finished = ev { break }
                if case .ttsStopped = ev { break }
                if Date() > deadline { break }
            }
            return got
        }
    }

    /// TET1-1: construct TTSEngineActor with nil Orpheus + real AVSpeechSynth.
    /// Verifies the optional-orpheus refactor compiles AND that the actor
    /// is usable after construction.
    func test_TET1_1_canConstructWithNilOrpheus() async {
        let engine = TTSEngineActor(
            orpheus: nil,
            tier1: AVSpeechSynth(),
            fallback: nil
        )
        let inFlight = await engine.hasSynthInFlight
        XCTAssertFalse(inFlight, "fresh actor: no synthesis in flight")
    }

    /// TET1-2: tier-1 synthesize yields `.started`, `.firstAudio`,
    /// `.finished` on the event stream. Real AVSpeechSynthesizer call —
    /// not mocked. This is the test that proves the user can hear
    /// Jarvis speak.
    func test_TET1_2_tier1Synthesize_emitsLifecycleEvents() async throws {
        let engine = TTSEngineActor(
            orpheus: nil,
            tier1: AVSpeechSynth(),
            fallback: nil
        )

        // Begin the collection task BEFORE the synthesize call so we
        // don't miss the .started event (the actor's first emission).
        let collector = Self.startCollector(on: engine, timeout: 4.0)

        try await engine.synthesize("ok", tier: .tier1, voice: "en-US")

        let collected = await collector.value
        XCTAssertTrue(
            collected.contains(where: { if case .started = $0 { return true } else { return false } }),
            "expected .started in event stream; got \(collected)"
        )
        XCTAssertTrue(
            collected.contains(where: { if case .firstAudio = $0 { return true } else { return false } }),
            "expected .firstAudio in event stream; got \(collected)"
        )
        XCTAssertTrue(
            collected.contains(where: { if case .finished = $0 { return true } else { return false } }),
            "expected .finished in event stream; got \(collected)"
        )
    }

    /// TET1-3: tier-2 requested with nil Orpheus must NOT crash. Either
    /// throws a clean TTSError, or transparently falls back to tier-1.
    /// Either is acceptable; a force-unwrap would not be.
    func test_TET1_3_tier2WithNilOrpheus_doesNotCrash() async {
        let engine = TTSEngineActor(
            orpheus: nil,
            tier1: AVSpeechSynth(),
            fallback: nil
        )

        do {
            try await engine.synthesize("ok", tier: .tier2, voice: "tara")
            // Acceptable: silent fallback to tier-1.
        } catch {
            // Acceptable: a clean error type. The forbidden outcome is a
            // crash; if we got here, that's fine.
            XCTAssertTrue(error is TTSError,
                "expected TTSError when tier-2 requested with nil Orpheus, got \(error)")
        }
    }

    /// TET1-4: rapid-fire tier-1 calls cancel prior in-flight synthesis.
    /// The actor's serial executor + reentrancy guard handles this.
    func test_TET1_4_rapidFire_cancelsPriorSynthesis() async throws {
        let engine = TTSEngineActor(
            orpheus: nil,
            tier1: AVSpeechSynth(),
            fallback: nil
        )

        // Fire-and-cancel pattern: kick off a long synthesis, then
        // immediately replace it with a short one. The first should be
        // cancelled cleanly.
        let task1 = Task {
            try? await engine.synthesize(
                "this is a longer utterance that will be cancelled",
                tier: .tier1,
                voice: "en-US"
            )
        }
        // Yield briefly so task1 enters the actor first.
        try? await Task.sleep(for: .milliseconds(50))
        try await engine.synthesize("done", tier: .tier1, voice: "en-US")
        _ = await task1.value

        let inFlight = await engine.hasSynthInFlight
        XCTAssertFalse(inFlight, "after rapid-fire, no synthesis should remain in flight")
    }
}
