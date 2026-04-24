import Foundation
import AgentCore

/// Tool invocation interface consumed by `AgentOrchestrator`.
///
/// In P4, only test doubles conform. P5 introduces the real MCP-backed
/// implementation that proxies to nested helper bundles. The orchestrator
/// never knows the difference — it only cares that `dispatch` returns raw
/// bytes (which `ToolResultPacker` then caps at 8 KB for the model and
/// streams in full to the replay log).
public protocol ToolDispatcher: Sendable {
    /// Invoke a tool. Throws to signal failure — orchestrator translates
    /// thrown errors into `.toolCardUpdate(phase: .failed)` plus a `.tool`
    /// LLMMessage carrying the error text so the model can react.
    func dispatch(toolUse: ToolUseRequest) async throws -> Data

    /// Return true if the named tool requires an explicit human confirmation
    /// before dispatch. Always false in P4 (no real tools wired yet); P5
    /// returns true for `mcp-applescript`, `mcp-shell`, etc.
    func requiresConfirmation(toolName: String) -> Bool
}
