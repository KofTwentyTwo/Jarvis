import Foundation

/// Top-level agent/UI state consumed by the menu-bar icon animation factory and
/// the R3F HUD ring. VoiceOver labels are normative per UI-SPEC Surface 3
/// lines 413-417.
///
/// HUD-08 precedence (encoded by `HudStateCoordinator.resolveAndEmit()`):
/// `awaitingConfirmation > speaking > listening > thinking > idle > booting > reconfiguring`.
/// Declaration order below preserves Phase 1's original 5 cases and appends the
/// two new ones so existing call-sites don't shift.
public enum HudState: String, Sendable, CaseIterable, Equatable {
    case idle
    case listening
    case thinking
    case speaking
    case awaitingConfirmation
    case reconfiguring
    case booting

    public var voiceOverLabel: String {
        switch self {
        case .idle: return "Jarvis, idle"
        case .listening: return "Jarvis, listening"
        case .thinking: return "Jarvis, thinking"
        case .speaking: return "Jarvis, speaking"
        case .awaitingConfirmation: return "Jarvis, waiting for your confirmation"
        case .reconfiguring: return "Jarvis, reconfiguring audio"
        case .booting: return "Jarvis, starting up"
        }
    }
}
