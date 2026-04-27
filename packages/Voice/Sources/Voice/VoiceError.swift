import Foundation

/// Top-level error type for the Voice package.
///
/// Individual subsystems (AudioGraph, WakeWord, VAD, STT, TTS) have their own
/// error enums; `VoiceError` is the top-level envelope the `VoiceController`
/// actor surfaces to callers.
public enum VoiceError: Error, Sendable, Equatable {
    /// The audio graph could not be built (wraps `AudioGraphError`).
    case audioGraphFailed(AudioGraphError)
    /// Microphone permission was denied and could not be recovered.
    case micPermissionDenied
    /// The voice controller has already been started.
    case alreadyRunning
}
