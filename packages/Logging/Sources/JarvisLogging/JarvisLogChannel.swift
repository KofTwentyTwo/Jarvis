import Foundation

public enum JarvisLogChannel: String, Sendable, CaseIterable {
    case agent
    case tools
    case ui
    case system
    case bus
    // Added in Plan 04-03 for the on-disk replay log + DevOverlay (Plan 04-05).
    case replay
    case devoverlay
}
