/// Reason surfaced via `AudioGraphOwner.degradationStream` when the graph
/// falls back to a degraded-mode configuration.
///
/// Plan 06-05 maps each reason to a HUD banner string:
/// - `.aecUnavailable` → `"AEC unavailable; degraded-mode active"` (VOICE-09)
///
/// Additional reasons may be added in future plans; the stream consumer
/// (Plan 06-05 `VoiceController`) must handle new cases gracefully.
public enum DegradationReason: Sendable, Equatable {
    /// `AVAudioInputNode.setVoiceProcessingEnabled(true)` threw.
    /// The graph was rebuilt without AEC/NS/AGC (VOICE-09).
    case aecUnavailable
}
