import Foundation

/// Intents produced by the agent orchestrator. The coordinator maps these
/// onto the `lastAgent` shadow field before resolving the precedence ladder.
public enum AgentHudIntent: Sendable, Equatable {
    case idle
    case thinking
    case speaking
}

/// Intents produced by the voice subsystem (wake word, STT, audio-route
/// reconfiguration). Mapped onto `lastVoice`.
public enum VoiceHudIntent: Sendable, Equatable {
    case silent
    case listening
    case reconfiguring
}

/// Intents produced by confirmation prompts (run_applescript gate, etc.).
/// Mapped onto the `awaitingConfirm` boolean.
public enum ConfirmHudIntent: Sendable, Equatable {
    case required
    case cleared
}
