import AVFoundation
import OSLog

/// Single source of truth for the post-VPIO input format probe (VOICE-08).
///
/// `probe(inputNode:)` wraps `inputNode.outputFormat(forBus: 0)`.
/// The probe MUST be called AFTER `setVoiceProcessingEnabled(true)` and
/// BEFORE the first `installTap` — the VPIO hardware resampler sets the
/// post-AEC format at enable-time, so calling this earlier returns the
/// raw hardware format (which may be 48 kHz on some devices), not the
/// AEC-processed format that the tap will deliver.
///
/// On macOS 26 Tahoe the post-AEC format is typically 24 kHz stereo.
/// On macOS Sonoma it is typically 16 kHz mono.
/// DO NOT hardcode either — always probe (Assumption A7 / R4-D4).
public enum InputFormatProbe {

    /// Test seam: when set, `probe(inputNode:)` calls this closure instead
    /// of `inputNode.outputFormat(forBus: 0)`.  Named with a leading
    /// underscore to signal "not for production use".  Access is `internal`
    /// so it is not visible to external consumers.
    ///
    /// Always set this back to `nil` in the test's `defer` block.
    ///
    /// `nonisolated(unsafe)` silences the Swift 6 global-mutable-state
    /// warning — this seam is ONLY written from single-threaded test set-up
    /// and tear-down code, never from concurrent contexts.
    nonisolated(unsafe)
    internal static var _probeOverride: ((AVAudioInputNode) -> AVAudioFormat)?

    private static let logger = Logger(subsystem: "com.koftwentytwo.jarvis",
                                       category: "AudioGraph.Probe")

    /// Returns the post-VPIO input format by calling
    /// `inputNode.outputFormat(forBus: 0)`.
    ///
    /// The probe is a pure observation: it does not configure, connect, or
    /// modify any node.  If `_probeOverride` is set (test environment only),
    /// that closure is called instead so the caller can inject a known format
    /// without a live `AVAudioEngine`.
    public static func probe(inputNode: AVAudioInputNode) -> AVAudioFormat {
        if let override = _probeOverride {
            return override(inputNode)
        }
        let fmt = inputNode.outputFormat(forBus: 0)
        logger.info("InputFormatProbe: sampleRate=\(fmt.sampleRate, format: .fixed(precision: 0)) channels=\(fmt.channelCount)")
        return fmt
    }
}
