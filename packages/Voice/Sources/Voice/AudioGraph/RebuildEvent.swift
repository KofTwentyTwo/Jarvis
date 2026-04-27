/// Events emitted on `AudioGraphOwner.rebuildStream` whenever the graph
/// is being torn down and rebuilt.
///
/// Consumers (Plan 06-05 `VoiceController`) observe this stream to update
/// the HUD state (e.g., show a "reconfiguring…" spinner).
///
/// Step 6 of the canonical six-step teardown sequence emits this event.
/// VOICE-10 / T-06-01-07: every rebuild fires `.reconfiguring(reason:)` AND
/// a structured log line via `JarvisLogChannel.system`.
public enum RebuildEvent: Sendable, Equatable {
    /// The audio graph is being torn down and rebuilt.
    /// `reason` identifies which of the four `RebuildTrigger` cases caused it.
    case reconfiguring(reason: RebuildTrigger)
}
