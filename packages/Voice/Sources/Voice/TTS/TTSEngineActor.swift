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
// ducking control. Ducking releases on `.ttsStopped` — emitted both on
// natural completion (after `.finished`, inside `synthesize`) and on
// barge-in (via `InterruptSequence.run`). Prior to audit-2026-05-12 P0-3
// (Issue #30) only the barge-in site emitted `.ttsStopped`, so natural
// completion left any future ducking consumer with ducks engaged forever.

public actor TTSEngineActor {

    // MARK: - Public API

    /// Event stream for HUD animation and ducking control.
    ///
    /// VOICE-11 / Pitfall #6: Ducking releases on `.ttsStopped`,
    /// NOT on `.finished` — producer done ≠ sink empty.
    /// `.ttsStopped` is emitted from two sites:
    ///   - Natural completion: `synthesize(...)` yields it after
    ///     `.finished` once the tier path has fully drained.
    ///   - Barge-in: `InterruptSequence.run(...)` yields it at step 5
    ///     after the 5-step interrupt sequence has run.
    /// (audit-2026-05-12 P0-3 / Issue #30 added the natural-completion
    /// emit; before then only barge-in fired `.ttsStopped`, so any
    /// ducking consumer would have left ducks engaged forever on a
    /// normal spoken reply.)
    public nonisolated let ttsEventStream: AsyncStream<TTSEvent>

    // MARK: - Private state

    private let orpheus: OrpheusTTS?
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
    /// Track B-3 (2026-05-03 voice audit fix): `orpheus` is now optional.
    /// The previous non-optional contract forced production callers to
    /// download Orpheus 3B weights from HuggingFace at first launch
    /// (~6GB) before any TTS could happen. Result: no production code
    /// path ever constructed a `TTSEngineActor`, and
    /// `VoiceTTSAdapter(engine: nil)` no-op'd every synthesis call —
    /// users never heard Jarvis speak. With orpheus as optional, tier-1
    /// (`AVSpeechSynthesizer`, instant, free) wires alone; tier-2
    /// requests gracefully fall back to tier-1 when Orpheus is absent.
    /// Coverage: `TTSEngineActorTier1Tests`.
    ///
    /// - Parameters:
    ///   - orpheus: The tier-2 Orpheus actor (serial executor prevents Metal deadlock).
    ///     Pass `nil` to wire tier-1 only — tier-2 calls degrade to tier-1.
    ///   - tier1: The tier-1 AVSpeechSynth wrapper.
    ///   - fallback: Optional TTSKit fallback (feature-flag gated; nil = disabled).
    public init(orpheus: OrpheusTTS?, tier1: AVSpeechSynth, fallback: TTSKitFallback?) {
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

        // Graceful degrade: if tier-2 is requested but Orpheus is not
        // wired (Track B-3 audit fix — production wiring previously
        // never constructed Orpheus due to ~6GB weight download), fall
        // back to tier-1 silently. The user hears Jarvis through
        // AVSpeechSynthesizer instead of Orpheus; voice character
        // degrades but the app speaks.
        let resolvedTier: TTSTier = (tier == .tier2 && orpheus == nil)
            ? .tier1
            : tier

        let task: Task<Void, Error> = Task {
            switch resolvedTier {
            case .tier1:
                let avVoice = AVSpeechSynthesisVoice(identifier: voice)
                    ?? AVSpeechSynthesisVoice(language: voice)
                await tier1Copy.speak(text, voice: avVoice)
                cont.yield(.firstAudio(at: Date()))
                cont.yield(.finished)

            case .tier2:
                guard let orpheusActor = orpheusCopy else {
                    // Defensive: resolvedTier above should have rerouted
                    // tier-2-without-orpheus to tier-1. If we reach here
                    // somehow, throw rather than force-unwrap.
                    throw TTSError.sinkUnavailable
                }
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
                try await orpheusActor.synthesize(text, voice: voice, into: sink) { firstAudioDate in
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
            // Cancellation flows through `InterruptSequence.run`, which
            // emits `.ttsStopped` at step 5. Don't double-emit here.
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

        // Natural-completion `.ttsStopped` emit (audit-2026-05-12 P0-3 /
        // Issue #30). The barge-in path emits `.ttsStopped` from
        // `InterruptSequence.run` step 5 instead. Together these are
        // the two sites that release ducking — see `ttsEventStream`
        // doc-comment.
        eventContinuation.yield(.ttsStopped)
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
        if let orpheus { await orpheus.cancel() }
        _ = try? await taskToCancel?.value
    }
}
