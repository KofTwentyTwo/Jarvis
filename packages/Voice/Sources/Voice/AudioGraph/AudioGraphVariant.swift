import AVFoundation

/// Describes the two distinct AVAudioEngine graph configurations the
/// `AudioGraphOwner` can hold (VOICE-09).
///
/// AEC-off is NOT a runtime toggle — it is a distinct graph build.
/// Pitfall #7: `isVoiceProcessingEnabled` MUST be set before any
/// `connect` or `installTap` call.  Flipping it afterwards is a silent
/// no-op on Tahoe and a crash on Sonoma.
///
/// Equality checks both the tag AND the format, so `.aecOn(fmtA) !=
/// .aecOn(fmtB)` when `fmtA != fmtB`, and `.aecOn(fmt) != .aecOff(fmt)`
/// even when the format is identical.
public enum AudioGraphVariant: Sendable, Equatable {
    /// Voice Processing I/O is active; AEC/NS/AGC are engaged.
    case aecOn(AVAudioFormat)
    /// `setVoiceProcessingEnabled(true)` failed; graph rebuilt without VPIO.
    case aecOff(AVAudioFormat)

    /// The probed `AVAudioFormat` that downstream consumers should expect
    /// from the ring buffer.  Always 16 kHz Float32 mono after tap
    /// rate-convert.
    public var format: AVAudioFormat {
        switch self {
        case .aecOn(let fmt): return fmt
        case .aecOff(let fmt): return fmt
        }
    }
}
