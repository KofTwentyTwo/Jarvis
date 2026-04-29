import Foundation

/// Holds [String: any InProcessTool] and dispatches CallTool requests by name.
/// AppDelegate (Plan 07-06) builds one and injects it alongside the existing
/// MCPRuntimeWiring helper-spawn registration.
public actor InProcessToolRegistry {

    private var tools: [String: any InProcessTool] = [:]

    public init() {}

    public func register(_ tool: any InProcessTool) {
        tools[tool.name] = tool
    }

    public func registered() -> [any InProcessTool] {
        Array(tools.values)
    }

    public func contains(_ name: String) -> Bool {
        tools[name] != nil
    }

    public func dispatch(_ name: String, args: Data) async throws -> Data {
        guard let tool = tools[name] else {
            throw InProcessToolError.unknownTool(name)
        }
        return try await tool.call(args: args)
    }
}
