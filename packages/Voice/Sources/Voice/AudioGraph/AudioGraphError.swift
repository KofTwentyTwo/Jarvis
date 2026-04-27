import Foundation

/// Errors thrown by the `AudioGraph` subsystem.
///
/// - `vpioNotEnabled`: A tap or connection was attempted before
///   `setVoiceProcessingEnabled(true)` was called. The six-step
///   teardown sequence (VOICE-10) is not triggered — this is a
///   programmer error surface.
/// - `formatProbeFailed`: `inputNode.outputFormat(forBus: 0)` returned a
///   format that could not be converted to 16 kHz Float32 mono.
/// - `aecUnavailable`: `setVoiceProcessingEnabled(true)` threw; the owner
///   will rebuild with `aec: false` and emit `.aecUnavailable` on
///   `degradationStream`.
/// - `engineStartFailed`: `AVAudioEngine.start()` threw.
/// - `bothVariantsFailed`: both `aec: true` and `aec: false` graph builds
///   failed — unrecoverable.
public enum AudioGraphError: Error, Sendable, Equatable {
    case vpioNotEnabled
    case formatProbeFailed
    case aecUnavailable
    case engineStartFailed
    case bothVariantsFailed
}
