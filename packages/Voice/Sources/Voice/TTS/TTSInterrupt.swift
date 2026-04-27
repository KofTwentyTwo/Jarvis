import AVFoundation
import Foundation

// MARK: - InterruptibleAudioSink (protocol for test injection in I1)
//
// Production `AudioSink` conforms to this protocol.
// Test helpers (`RecordingAudioSink`, `StallingSink`) also conform to it
// so `InterruptSequence.run(engine:sink:eventBus:)` can be called with stubs.

public protocol InterruptibleAudioSink: Sendable {
    /// Enqueue a cosine-shaped fade buffer (VOICE-11 step 2).
    func cosineFadeOut(duration: Duration) async
    /// Stop the player node (VOICE-11 step 3).
    func stop()
    /// Wait for all enqueued buffers to drain or timeout (VOICE-11 step 4).
    func awaitCompletion(timeout: Duration) async
}

// AudioSink conforms automatically (all methods already implemented).
extension AudioSink: InterruptibleAudioSink {}

// MARK: - InterruptStepRecorder (protocol for test step ordering in I1)
//
// Production code passes nil (no recording).
// Tests inject a `StepLog` that conforms to this protocol.

public protocol InterruptStepRecorder: Sendable {
    func record(_ step: String)
}

// MARK: - InterruptSequence
//
// Atomic 5-step TTS interrupt sequence (VOICE-11).
//
// Step sequence:
//   1. Cancel producer (TTSEngineActor)         — cooperative cancellation
//   2. 10 ms cosine fade-out on the audio sink  — prevents click/pop tail
//   3. `playerNode.stop()`                      — halts scheduling
//   4. Await completion ≤ 20 ms                 — bounded drain
//   5. Emit `.ttsStopped`                       — THIS is the ducking-release gate
//
// VOICE-11 / Pitfall #6:
//   `.ttsStopped` at step 5 is the ONLY site that triggers ducking release.
//   DO NOT release ducking on `.finished` — producer done ≠ sink empty.
//   The 100–200 ms tail of scheduled buffers would clip if ducking released early.
//
// Idempotency:
//   If `engine.hasSynthInFlight == false`, the sequence is a no-op.
//   Plan 06-05's barge-in path may call this defensively even when `.idle`.

public enum InterruptSequence {

    /// Run the 5-step atomic interrupt sequence.
    ///
    /// - Parameters:
    ///   - engine: The `TTSEngineActor` whose in-flight synthesis to cancel.
    ///   - sink: The `InterruptibleAudioSink` (production: `AudioSink`).
    ///   - eventBus: The `AsyncStream<TTSEvent>.Continuation` to emit `.ttsStopped`.
    ///   - stepLog: Optional step recorder for tests (nil in production).
    public static func run(
        engine: TTSEngineActor,
        sink: some InterruptibleAudioSink,
        eventBus: AsyncStream<TTSEvent>.Continuation,
        stepLog: (any InterruptStepRecorder)? = nil
    ) async {
        // Idempotency guard: if no synth is in flight, this is a no-op.
        // Plan 06-05's barge-in path may call this defensively when already idle.
        guard await engine.hasSynthInFlight else { return }

        // STEP 1: Cancel the in-flight Orpheus/AVSpeech producer.
        stepLog?.record("1-cancel")
        await engine.cancel()

        // STEP 2: 10 ms cosine fade-out (prevents click/pop — VOICE-11).
        // The fade buffer is enqueued LAST before playerNode.stop().
        stepLog?.record("2-fade")
        await sink.cosineFadeOut(duration: .milliseconds(10))

        // STEP 3: Stop the player node (halts buffer scheduling).
        stepLog?.record("3-stop")
        sink.stop()

        // STEP 4: Await buffer drain, bounded ≤ 20 ms (VOICE-11 spec).
        // The timeout is enforced HERE (not just passed to the sink) so that even
        // a sink stub that ignores its timeout parameter cannot stall step 5.
        stepLog?.record("4-await")
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await sink.awaitCompletion(timeout: .milliseconds(20)) }
            group.addTask { try? await Task.sleep(for: .milliseconds(20)) }
            // First task to complete wins (cancels the other via TaskGroup cancel-on-first)
            await group.next()
            group.cancelAll()
        }

        // STEP 5: Emit .ttsStopped — THE ducking-release gate (VOICE-11 / Pitfall #6).
        // This is the ONLY site that emits .ttsStopped (single source of truth).
        // grep gate: grep -nE '\.ttsStopped' TTSInterrupt.swift | grep -v '//' | wc -l == 1
        stepLog?.record("5-ttsStopped")
        eventBus.yield(.ttsStopped)  // single .ttsStopped emission site
    }
}
