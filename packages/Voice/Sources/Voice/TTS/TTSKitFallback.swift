import AVFoundation
import Foundation
import TTSKit

// MARK: - TTSKitFallback
//
// Tier-2 fallback wrapping argmax-oss-swift `TTSKit` (VOICE-06).
//
// TTSKit uses Qwen3-TTS voices — voice character differs from Orpheus.
// Prefer Orpheus (OrpheusTTS) for voice character; use this fallback only if:
//   - Orpheus TTFA > 250 ms on the target hardware, OR
//   - OrpheusTTS produces generation errors.
//
// Feature flag: `features.tts.tier2` in Plan 06-05's JSON config.
// Default: "orpheus". Set to "ttskit" to activate this fallback.
//
// The actor's serial executor ensures single-stream TTSKit usage
// (TTSKit is NOT designed for concurrent playback).

public actor TTSKitFallback {

    // MARK: - Private state

    private let kit: TTSKit

    /// Track the in-flight synthesis task for cancellation.
    private var currentTask: Task<Void, Error>?

    // MARK: - Init

    /// Production init: loads the TTSKit model by variant.
    ///
    /// - Parameter modelName: Model variant (e.g. `.qwen3TTS_0_6b`).
    ///   TTSKit uses `TTSModelVariant` enum, not a raw string.
    public init(modelName: String) async throws {
        // Map string to TTSModelVariant (default to 0.6b for low VRAM)
        let variant: TTSModelVariant = modelName.contains("1.7b") ? .qwen3TTS_1_7b : .qwen3TTS_0_6b
        self.kit = try await TTSKit(model: variant)
    }

    /// Test seam: inject a pre-configured TTSKit instance.
    init(kit: TTSKit) {
        self.kit = kit
    }

    // MARK: - Public API

    /// Synthesize `text` using `kit.play(text: strategy: .auto)`.
    ///
    /// TTSKit handles chunked streaming playback internally via `PlaybackStrategy.auto`.
    /// The `sink` parameter is reserved for future AudioSink integration (Plan 06-05).
    public func synthesize(_ text: String, into sink: AudioSink) async throws {
        currentTask?.cancel()
        _ = try? await currentTask?.value
        currentTask = nil

        let task: Task<Void, Error> = Task { [kit] in
            _ = try await kit.play(text: text, playbackStrategy: .auto)
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

    /// Cancel in-flight TTSKit synthesis.
    public func cancel() async {
        currentTask?.cancel()
        _ = try? await currentTask?.value
        currentTask = nil
    }
}
