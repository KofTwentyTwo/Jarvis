import Foundation

/// Top-level agent/UI state consumed by the menu-bar icon animation factory and
/// (in later plans) the R3F HUD ring. VoiceOver labels are normative per
/// UI-SPEC Surface 3 lines 413-417.
public enum HudState: String, Sendable, CaseIterable, Equatable {
    case idle
    case listening
    case thinking
    case speaking
    case awaitingConfirmation

    public var voiceOverLabel: String {
        switch self {
        case .idle: return "Jarvis, idle"
        case .listening: return "Jarvis, listening"
        case .thinking: return "Jarvis, thinking"
        case .speaking: return "Jarvis, speaking"
        case .awaitingConfirmation: return "Jarvis, waiting for your confirmation"
        }
    }
}
