import Foundation

/// In-process MCP tool — bypasses stdio framing for tools that need direct
/// access to in-process state (Memory subsystem in P7).
///
/// Per PATTERNS section 2.18 Option A: search_memory, search_conversation,
/// and forget_fact dispatch directly to MemoryStore / HybridSearch /
/// SessionHistory. The Phase 5 helper-spawn registry continues to host
/// stdio-framed tools (`get_time`, `get_clipboard`, `run_applescript`).
public protocol InProcessTool: Sendable {
    /// Tool name as exposed to the LLM.
    var name: String { get }
    /// JSON Schema bytes used by the tool catalog when ListTools is called.
    var schemaJSON: Data { get }
    /// D-02: forget_fact is destructive and must always confirmation-gate
    /// through the existing P5 ConfirmationBroker; non-destructive read tools
    /// return false.
    var requiresConfirmation: Bool { get }
    /// Run the tool. `args` are the JSON-decoded `arguments` field of the
    /// CallTool request; the implementation parses and routes to the
    /// underlying actor. Returns a JSON-encoded result the caller wraps into
    /// the MCP CallTool response.
    func call(args: Data) async throws -> Data
}

public enum InProcessToolError: Error, Sendable, Equatable {
    case unknownTool(String)
    case invalidArguments(String)
    case dispatchFailed(String)
}
