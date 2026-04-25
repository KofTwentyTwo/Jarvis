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
    // Added in Plan 05-05 for the JarvisMCP layer's confirmation broker / dispatcher
    // WARNING log lines (AGENT-11 timeout-as-deny). Mirrors the existing
    // `MCPLogChannel.logger(label:)` factory by giving a stable channel rawValue
    // ("mcp") so call sites can `Logger(label: JarvisLogChannel.mcp.rawValue)`.
    case mcp
}
