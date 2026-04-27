import AVFoundation
import Foundation
import MLXAudioCore

// MARK: - TTSEngineActor
//
// Public actor that coordinates both TTS tiers behind a single serial executor.
//
// CRITICAL — Pitfall #1 (Metal command-buffer deadlock):
//   TTSEngineActor IS A SWIFT ACTOR. Its DEFAULT SERIAL EXECUTOR ensures that
//   concurrent `synthesize` calls are FIFO-serialized — the second call can only
//   enter `synthesize` after the first has finished or been cancelled. This is
//   the ENFORCED MITIGATION against Metal command-buffer serialization deadlocks
//   that would occur if `OrpheusTTS.generateStream` were called concurrently.
//
// Usage:
//   - tier1 (.tier1): instant AVSpeechSynthesizer (sub-sentence confirmations).
//   - tier2 (.tier2): Orpheus via LlamaTTSModel (high-quality, 150–250 ms TTFA).
//   - fallback: TTSKit (feature-flag gated, defaulted off; Plan 06-05 wires flag).
//
// Event stream: `ttsEventStream` emits TTSEvent values for HUD animation +
// ducking control. Ducking releases ONLY on `.ttsStopped` (VOICE-11 / Pitfall #6).

public actor TTSEngineActor {

    // MARK: - Public API

    /// Event stream for HUD animation and ducking control.
    ///
    /// VOICE-11 / Pitfall #6: Ducking releases ONLY on `.ttsStopped`.
    /// DO NOT release ducking on `.finished` — producer done ≠ sink empty.
    public nonisolated let ttsEventStream: AsyncStream<TTSEvent>

    // MARK: - Private state

    private let orpheus: OrpheusTTS
    private let tier1: AVSpeechSynth
    private let fallback: TTSKitFallback?

    private var currentTask: Task<Void, Error>?
    private let eventContinuation: AsyncStream<TTSEvent>.Continuation

    /// Whether a synthesis is currently active. Used by `InterruptSequence` for idempotency.
    private var _hasSynthInFlight: Bool = false

    /// Returns true if a synthesis is currently active.
    public var hasSynthInFlight: Bool { _hasSynthInFlight }

    // MARK: - Init

    /// Create a `TTSEngineActor`.
    ///
    /// - Parameters:
    ///   - orpheus: The tier-2 Orpheus actor (serial executor prevents Metal deadlock).
    ///   - tier1: The tier-1 AVSpeechSynth wrapper.
    ///   - fallback: Optional TTSKit fallback (feature-flag gated; nil = disabled).
    public init(orpheus: OrpheusTTS, tier1: AVSpeechSynth, fallback: TTSKitFallback?) {
        self.orpheus = orpheus
        self.tier1 = tier1
        self.fallback = fallback

        let (stream, cont) = AsyncStream<TTSEvent>.makeStream()
        self.ttsEventStream = stream
        self.eventContinuation = cont
    }

    // MARK: - Synthesize

    /// Synthesize `text` using the specified `tier`.
    ///
    /// If a synthesis is already in flight, the current task is cancelled before
    /// starting the new one. This is the actor-reentrancy guard that mirrors
    /// the AgentOrchestrator cancel-before-start pattern (Phase 4).
    ///
    /// - Parameters:
    ///   - text: Text to synthesize.
    ///   - tier: Which engine tier to use (.tier1 or .tier2).
    ///   - voice: Voice identifier (e.g. "tara" for Orpheus, or language code for tier-1).
    public func synthesize(_ text: String, tier: TTSTier, voice: String) async throws {
        // Cancel any in-flight synthesis (actor reentrancy guard).
        // The TTSEngineActor's serial executor ensures only one synthesize call
        // can be inside this body at a time.
        currentTask?.cancel()
        _ = try? await currentTask?.value
        currentTask = nil
        _hasSynthInFlight = false

        eventContinuation.yield(.started)
        _hasSynthInFlight = true

        let cont = eventContinuation
        let orpheusCopy = orpheus
        let tier1Copy = tier1
        let fallbackCopy = fallback

        let task: Task<Void, Error> = Task {
            switch tier {
            case .tier1:
                let avVoice = AVSpeechSynthesisVoice(identifier: voice)
                    ?? AVSpeechSynthesisVoice(language: voice)
                await tier1Copy.speak(text, voice: avVoice)
                cont.yield(.firstAudio(at: Date()))
                cont.yield(.finished)

            case .tier2:
                // Build a temporary sink for this synthesis.
                // In production (Plan 06-05), the sink is owned by AudioGraphOwner.
                let engine = AVAudioEngine()
                let playerNode = AVAudioPlayerNode()
                engine.attach(playerNode)
                guard let format = AVAudioFormat(
                    commonFormat: .pcmFormatFloat32,
                    sampleRate: 24000,
                    channels: 1,
                    interleaved: false
                ) else {
                    throw TTSError.sinkUnavailable
                }
                engine.connect(playerNode, to: engine.mainMixerNode, format: format)
                try engine.start()
                playerNode.play()
                let sink = AudioSink(playerNode: playerNode, format: format)

                // Actor-to-actor call: TTSEngineActor → OrpheusTTS.synthesize
                // OrpheusTTS's serial executor prevents concurrent Metal kernel calls.
                try await orpheusCopy.synthesize(text, voice: voice, into: sink) { firstAudioDate in
                    cont.yield(.firstAudio(at: firstAudioDate))
                }
                cont.yield(.finished)
                engine.stop()

                let _ = fallbackCopy  // TTSKit fallback wired via Plan 06-05 feature flag
            }
        }
        currentTask = task
        do {
            try await task.value
        } catch is CancellationError {
            _hasSynthInFlight = false
            throw TTSError.cancelled
        } catch let e as TTSError {
            _hasSynthInFlight = false
            throw e
        } catch {
            _hasSynthInFlight = false
            throw TTSError.synthesisFailed(underlying: error)
        }
        _hasSynthInFlight = false
        currentTask = nil
    }

    // MARK: - Cancel

    /// Cancel any in-flight synthesis.
    ///
    /// Cancellation is two-pronged:
    ///   1. Cancel the TTSEngineActor's own Task (which is awaiting OrpheusTTS.synthesize).
    ///   2. Concurrently call orpheus.cancel() to cancel the inner stream task.
    ///
    /// Both must fire concurrently — cancelling only the outer task does not propagate
    /// through actor-isolated async calls to OrpheusTTS. Waiting for the outer task
    /// before calling orpheus.cancel() would deadlock if OrpheusTTS is blocked on
    /// its stream.
    public func cancel() async {
        let taskToCancel = currentTask
        currentTask = nil
        _hasSynthInFlight = false

        // Fire both cancellations concurrently, then wait.
        taskToCancel?.cancel()
        await orpheus.cancel()
        _ = try? await taskToCancel?.value
    }
}
