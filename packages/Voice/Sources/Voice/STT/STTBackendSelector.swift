import Foundation

// MARK: - STTWarningLogger (test seam)

/// Protocol for capturing warning messages from `STTBackendSelector` in tests.
///
/// The test target's `TestWarningLogger` conforms to this protocol.
/// In production, warnings go to `print` / os_log (wired by Plan 06-05).
public protocol STTWarningLogger: Sendable {
    func warn(_ message: String)
}

// MARK: - STTBackendSelector

/// Selects the STT provider based on the backend string from `PerTurnSnapshot.stt.backend`.
///
/// The selector is the SINGLE call site that interprets the backend string value.
/// Plan 06-05's `VoiceController` uses this selector, never reads `stt.backend` directly.
///
/// SEC-05 contract: the backend string is pinned at `submit()` time via `PerTurnSnapshot`.
/// The selector MUST NOT be called more than once per turn — mid-session backend swaps
/// are NOT supported (PLAN 06-03 anti-pattern callout).
///
/// Usage (app layer):
/// ```swift
/// let sttProvider = STTBackendSelector.make(backend: snapshot.stt.backend)
/// ```
public enum STTBackendSelector {

    // MARK: - Valid backend strings
    //
    // Canonical backend identifiers. Snake_case is the wire shape stored in
    // `PerTurnSnapshot.stt.backend`. Call sites (`AppDelegate.sttBackend`)
    // SHOULD reference these constants rather than the bare string literals;
    // `STTBackendSwitchTests.testB5_canonicalConstantsRoundTripThroughMake`
    // locks the round-trip contract by asserting both that the constants
    // map to the right `STTProvider` AND that camelCase string literals
    // (the pre-2026-05-12 anti-pattern from Issue #29 / #37) fall through
    // to the default branch with a warning. Do not rename without updating
    // `PerTurnSnapshot` and the regression test in lockstep.

    public static let backendSpeechAnalyzer = "speech_analyzer"
    public static let backendWhisperKit = "whisperkit"

    // MARK: - Factory

    /// Create an `STTProvider` for the given backend string.
    ///
    /// - Parameters:
    ///   - backend: Backend identifier string from `PerTurnSnapshot.stt.backend`.
    ///     Valid values: `"speech_analyzer"` (default) or `"whisperkit"`.
    ///     Unknown values fall back to `"speech_analyzer"` and log a warning.
    ///   - warningLogger: Optional logger for unknown-backend warnings (test seam).
    ///     In production, warnings go to `print` on the agent channel.
    /// - Returns: An `STTProvider` instance ready for `transcribe(stream:)`.
    public static func make(
        backend: String,
        warningLogger: (any STTWarningLogger)? = nil
    ) -> any STTProvider {
        switch backend {
        case backendSpeechAnalyzer, "":
            return SpeechAnalyzerSTT()

        case backendWhisperKit:
            return WhisperKitSTT()

        default:
            let msg = "STTBackendSelector: unknown backend '\(backend)'; falling back to speech_analyzer"
            if let logger = warningLogger {
                logger.warn(msg)
            } else {
                // Production path: log to stderr (Plan 06-05 VoiceController wires os_log)
                print("[Voice] WARNING: \(msg)")
            }
            return SpeechAnalyzerSTT()
        }
    }
}
