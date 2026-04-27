import Foundation

// MARK: - TTSError
//
// Errors thrown by TTS subsystem (Plan 06-04).

public enum TTSError: Error, Sendable {
    /// Model weights failed to load from Hugging Face / local cache.
    case modelLoadFailed(underlying: Error)

    /// Synthesis produced an error (generation loop, SNAC decode, etc.).
    case synthesisFailed(underlying: Error)

    /// Synthesis was cancelled via `cancel()` or `Task.cancel()`.
    case cancelled

    /// AudioSink is unavailable (e.g. playerNode detached from engine).
    case sinkUnavailable
}
