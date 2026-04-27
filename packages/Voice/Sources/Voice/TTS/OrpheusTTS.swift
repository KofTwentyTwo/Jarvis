import AVFoundation
import Foundation
import MLXAudioTTS
import MLXAudioCore

// MARK: - TTSTier

/// Selects which TTS engine tier to use for a synthesis call.
///
/// - tier1: `AVSpeechSynthesizer` — instant, low quality. Used for short confirmations
///           and think-aloud text while tier 2 is warming (VOICE-05).
/// - tier2: Orpheus via `LlamaTTSModel` (or TTSKit fallback) — high quality, 150–250 ms TTFA.
///           Requires Apple Silicon (MLX) or a TTSKit model download (VOICE-06).
public enum TTSTier: Sendable, Equatable {
    case tier1
    case tier2
}

// MARK: - OrpheusTTS
//
// Actor wrapping `LlamaTTSModel` for Orpheus tier-2 TTS (VOICE-06).
//
// CRITICAL — Pitfall #1 (Metal command-buffer deadlock):
//   `OrpheusTTS` is a Swift actor. Its DEFAULT SERIAL EXECUTOR is the
//   synchronization primitive that prevents concurrent `generateStream` calls
//   from racing on Metal command buffers. DO NOT call `generateStream` from
//   outside this actor's isolation domain.
//
// The upstream `TTSEngineActor` is also a Swift actor (serial executor), so
// the two actors naturally compose without extra locking.
//
// Model string anchor: "mlx-community/orpheus-3b-0.1-ft-bf16" (CLAUDE.md voice stack).
// grep gate: grep -n 'orpheus-3b-0.1-ft-bf16' OrpheusTTS.swift — must match exactly 1 line.

public actor OrpheusTTS {

    // MARK: - Private state

    /// The loaded Orpheus model (LlamaTTSModel conforms to SpeechGenerationModel).
    /// Stored privately — callers synthesize via `synthesize(_:voice:into:)`.
    let model: any SpeechGenerationModelProtocol

    /// Track the in-flight synthesis task so `cancel()` can cancel it.
    private var currentTask: Task<Void, Error>?

    // MARK: - Init

    /// Production init: loads `mlx-community/orpheus-3b-0.1-ft-bf16` from HuggingFace.
    ///
    /// Orpheus model string anchor: "mlx-community/orpheus-3b-0.1-ft-bf16"
    public init() async throws {
        do {
            let m = try await LlamaTTSModel.fromPretrained("mlx-community/orpheus-3b-0.1-ft-bf16")
            self.model = LlamaTTSModelWrapper(m)
        } catch {
            throw TTSError.modelLoadFailed(underlying: error)
        }
    }

    /// Test seam init: inject a scripted model to avoid real weight loading.
    init(model: any SpeechGenerationModelProtocol) {
        self.model = model
    }

    /// Convenience init for real `LlamaTTSModel` (used by T1 perf probe).
    public init(model: LlamaTTSModel) {
        self.model = LlamaTTSModelWrapper(model)
    }

    // MARK: - Public API

    /// Synthesize `text` with `voice` and enqueue audio chunks into `sink`.
    ///
    /// Fires `onFirstAudio` when the first `.audio` event arrives (for TTFA tracking).
    ///
    /// Cancellation: cooperative — `Task.checkCancellation()` is called after
    /// each audio chunk. If `cancel()` is called externally, the loop exits.
    ///
    /// Note: `LlamaTTSModel.generateStream` emits many `.token(Int)` events
    /// followed by `.info(AudioGenerationInfo)` followed by ONE `.audio(MLXArray)`
    /// at the end. This is NOT chunk-by-chunk audio streaming — audio arrives
    /// at the end of the token generation loop.
    public func synthesize(
        _ text: String,
        voice: String,
        into sink: AudioSink,
        onFirstAudio: (@Sendable (Date) -> Void)? = nil
    ) async throws {
        // Cancel any previously-running synthesis (actor reentrancy guard).
        currentTask?.cancel()
        _ = try? await currentTask?.value
        currentTask = nil

        var firstAudio = true
        let stream = model.makeStream(text: text, voice: voice)

        let task: Task<Void, Error> = Task {
            for try await event in stream {
                try Task.checkCancellation()
                switch event {
                case .audio(let mlxArray):
                    if firstAudio {
                        onFirstAudio?(Date())
                        firstAudio = false
                    }
                    let samples = mlxArray.asArray(Float.self)
                    await sink.enqueue(samples)
                case .token, .info:
                    break
                }
            }
        }
        currentTask = task
        do {
            try await task.value
        } catch is CancellationError {
            throw TTSError.cancelled
        } catch {
            throw TTSError.synthesisFailed(underlying: error)
        }
        currentTask = nil
    }

    /// Cancel the in-flight synthesis task.
    public func cancel() async {
        currentTask?.cancel()
        _ = try? await currentTask?.value
        currentTask = nil
    }
}

// MARK: - SpeechGenerationModelProtocol (test seam)

/// Protocol that bridges real `LlamaTTSModel` and scripted test models.
/// Using a protocol allows `OrpheusTTS` to be tested without real weights.
public protocol SpeechGenerationModelProtocol: Sendable {
    var sampleRate: Int { get }
    func makeStream(text: String, voice: String) -> AsyncThrowingStream<AudioGeneration, Error>
}

/// Wraps `LlamaTTSModel` (which is `SpeechGenerationModel`) to conform to our protocol.
struct LlamaTTSModelWrapper: SpeechGenerationModelProtocol {
    private let model: LlamaTTSModel

    init(_ model: LlamaTTSModel) { self.model = model }

    var sampleRate: Int { model.sampleRate }

    func makeStream(text: String, voice: String) -> AsyncThrowingStream<AudioGeneration, Error> {
        model.generateStream(
            text: text,
            voice: voice,
            refAudio: nil,
            refText: nil,
            language: nil,
            generationParameters: model.defaultGenerationParameters
        )
    }
}
