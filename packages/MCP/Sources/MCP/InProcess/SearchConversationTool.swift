import Foundation

public protocol SessionHistoryDispatching: Sendable {
    func recentTurns(sessionId: String, limit: Int) async throws -> [SearchConversationTurn]
}

public struct SearchConversationTurn: Sendable, Codable, Equatable {
    public let id: Int64
    public let sessionId: String
    public let role: String
    public let content: String
    public let source: String
    public let createdAt: Int64
    public init(id: Int64, sessionId: String, role: String, content: String, source: String, createdAt: Int64) {
        self.id = id
        self.sessionId = sessionId
        self.role = role
        self.content = content
        self.source = source
        self.createdAt = createdAt
    }
}

/// TEXT-03: search_conversation MCP tool. Session-scoped (per CONTEXT
/// "search_conversation uses session_id"). Never confirmation-gated.
public struct SearchConversationTool: InProcessTool {

    public let name: String = "search_conversation"
    public let requiresConfirmation: Bool = false

    public var schemaJSON: Data {
        let schema: [String: Any] = [
            "type": "object",
            "properties": [
                "sessionId": ["type": "string", "description": "Session id to scope the query."],
                "limit": ["type": "integer", "description": "Max turns to return (default 20, capped at 500).", "default": 20],
            ],
            "required": ["sessionId"],
        ]
        return (try? JSONSerialization.data(withJSONObject: schema, options: [.sortedKeys])) ?? Data()
    }

    private let dispatcher: any SessionHistoryDispatching

    public init(dispatcher: any SessionHistoryDispatching) {
        self.dispatcher = dispatcher
    }

    public func call(args: Data) async throws -> Data {
        struct Args: Decodable { let sessionId: String; let limit: Int? }
        let parsed: Args
        do {
            parsed = try JSONDecoder().decode(Args.self, from: args)
        } catch {
            throw InProcessToolError.invalidArguments("search_conversation: \(error)")
        }
        let limit = parsed.limit ?? 20
        let turns = try await dispatcher.recentTurns(sessionId: parsed.sessionId, limit: limit)
        return try JSONEncoder().encode(["turns": turns])
    }
}
