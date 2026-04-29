import Foundation

/// HybridSearch surface used by SearchMemoryTool. Memory.HybridSearch
/// (Plan 07-03 Task 2) conforms via a trivial extension in
/// AppDelegate.installMemory (Plan 07-06).
public protocol HybridSearchDispatching: Sendable {
    func searchFacts(query: String, k: Int, triggerTurnId: Int64) async throws -> [SearchMemoryHit]
}

/// FactRef-shaped projection for the tool boundary. Independent of
/// Memory.FactRef so MCP doesn't need to depend on Memory directly.
public struct SearchMemoryHit: Sendable, Codable, Equatable {
    public let factId: Int64
    public let summary: String
    public let score: Double?
    public let triggerTurnId: Int64
    public init(factId: Int64, summary: String, score: Double? = nil, triggerTurnId: Int64 = 0) {
        self.factId = factId
        self.summary = summary
        self.score = score
        self.triggerTurnId = triggerTurnId
    }
}

/// MEM-07 / D-07: search_memory MCP tool. All-sessions hybrid search (FTS5 +
/// vec0 RRF). Never confirmation-gated — read-only.
public struct SearchMemoryTool: InProcessTool {

    public let name: String = "search_memory"
    public let requiresConfirmation: Bool = false

    public var schemaJSON: Data {
        let schema: [String: Any] = [
            "type": "object",
            "properties": [
                "query": ["type": "string", "description": "Free-text query — matches FTS5 and vec0 cohorts."],
                "k": ["type": "integer", "description": "Max hits to return (default 10).", "default": 10],
                "triggerTurnId": ["type": "integer", "description": "Optional turnId for DevOverlay correlation."],
            ],
            "required": ["query"],
        ]
        return (try? JSONSerialization.data(withJSONObject: schema, options: [.sortedKeys])) ?? Data()
    }

    private let dispatcher: any HybridSearchDispatching

    public init(dispatcher: any HybridSearchDispatching) {
        self.dispatcher = dispatcher
    }

    public func call(args: Data) async throws -> Data {
        struct Args: Decodable { let query: String; let k: Int?; let triggerTurnId: Int64? }
        let parsed: Args
        do {
            parsed = try JSONDecoder().decode(Args.self, from: args)
        } catch {
            throw InProcessToolError.invalidArguments("search_memory: \(error)")
        }
        let k = parsed.k ?? 10
        let triggerTurnId = parsed.triggerTurnId ?? 0
        let hits = try await dispatcher.searchFacts(
            query: parsed.query, k: k, triggerTurnId: triggerTurnId
        )
        return try JSONEncoder().encode(["hits": hits])
    }
}
