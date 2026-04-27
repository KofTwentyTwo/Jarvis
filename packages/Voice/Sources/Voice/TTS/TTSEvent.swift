import Foundation

// MARK: - TTSEvent
//
// Events emitted by TTSEngineActor during synthesis.
//
// CRITICAL (VOICE-11 / Pitfall #6): Ducking releases ONLY on `.ttsStopped`,
// NEVER on `.finished` alone. Producer done ≠ sink empty — the 100–200 ms tail
// of scheduled buffers would clip if ducking released on `.finished`.
//
// Event ordering contract:
//   .started → .firstAudio(at:) → ... → .finished → .ttsStopped

public enum TTSEvent: Sendable, Equatable {
    /// Synthesis has started (producer goroutine active).
    case started

    /// First audio chunk reached the sink — used for TTFA measurement.
    /// The `at` timestamp is captured the moment the first `.audio` event
    /// is received from `LlamaTTSModel.generateStream`.
    case firstAudio(at: Date)

    /// Producer is done — all audio has been handed to the sink.
    /// WARNING: The sink may still be draining. DO NOT release ducking here.
    case finished

    /// Sink has fully drained — playback is complete and silent.
    /// THIS is the ducking-release gate (VOICE-11 / Plan 06-04 / Pitfall #6).
    case ttsStopped
}
