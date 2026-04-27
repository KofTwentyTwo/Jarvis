/// The four events that cause `AudioGraphOwner` to run the canonical
/// six-step teardown + rebuild sequence (VOICE-10).
///
/// All four triggers route through a single `func teardown()` body —
/// the teardown logic is DRY regardless of why the rebuild was requested.
public enum RebuildTrigger: Sendable, Equatable {
    /// `AVAudioEngine.configurationChangeNotification` fired (device added,
    /// removed, or default input changed).
    case deviceChange
    /// `setVoiceProcessingEnabled(true)` threw; owner is rebuilding with
    /// `aec: false`.  This trigger causes `DegradationReason.aecUnavailable`
    /// to be emitted on `degradationStream`.
    case aecFallback
    /// `AVCaptureDevice.authorizationStatus(for: .audio)` transitioned from
    /// `.denied` to `.authorized` (mic-re-grant after user grants in
    /// System Settings).
    case micRegrant
    /// `RingBuffer.overflowDetected == true` — consumer is lagging more than
    /// `sustainedOverflowMs` (default 500 ms).  Pitfall #4: do NOT silently
    /// drop ring-overflow samples; fire this trigger instead.
    case ringOverflow
}
