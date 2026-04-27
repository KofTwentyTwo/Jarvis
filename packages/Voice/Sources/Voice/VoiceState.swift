/// State machine for the voice pipeline.
///
/// Transitions:
/// ```
/// .idle
///   → .listening(source: .wakeWord)  when WakeWordDAG fires
///   → .listening(source: .ptt)       when PTT keydown
/// .listening
///   → .thinking                      when VAD .speechEnd + STT finalize → orchestrator.submit
///   → .idle                          when PTT keyup with no speech
/// .thinking
///   → .speaking                      when orchestrator emits turnEnd with text
///   → .idle                          on error / empty turn
/// .speaking
///   → .idle                          when TTS finishes (.ttsStopped)
///   → .listening(source: .wakeWord)  on barge-in (wake-word fires during .speaking)
///   → .listening(source: .ptt)       on PTT barge-in
/// .reconfiguring(reason:)
///   → .idle                          when rebuild succeeds
/// ```
public enum VoiceState: Sendable, Equatable {
    case idle
    case listening(source: ListeningSource)
    case thinking
    case speaking
    case reconfiguring(reason: RebuildTrigger)
}

/// How listening was activated.
public enum ListeningSource: Sendable, Equatable {
    /// Wake word ("Hey Jarvis") triggered the STT session.
    case wakeWord
    /// Push-to-talk hotkey is held down.
    case ptt
}
