import Foundation

public protocol ForgetFactDispatching: Sendable {
    /// D-02 dispatch surface: returns true if a row was forgotten, false
    /// if no active row matched. NEVER DELETEs.
    func forgetFact(id: Int64, triggerTurnId: Int64) async throws -> Bool
}

/// D-02: forget_fact MCP tool. ALWAYS confirmation-gated — destructive
/// (closes valid_to and sets forgotten_at). Never DELETEs.
public struct ForgetFactTool: InProcessTool {

    public let name: String = "forget_fact"
    public let requiresConfirmation: Bool = true

    public var schemaJSON: Data {
        let schema: [String: Any] = [
            "type": "object",
            "properties": [
                "factId": ["type": "integer", "description": "Numeric fact id to forget. NEVER DELETEs — closes valid_to and sets forgotten_at."],
                "triggerTurnId": ["type": "integer", "description": "Optional turnId for DevOverlay correlation."],
            ],
            "required": ["factId"],
        ]
        return (try? JSONSerialization.data(withJSONObject: schema, options: [.sortedKeys])) ?? Data()
    }

    private let dispatcher: any ForgetFactDispatching

    public init(dispatcher: any ForgetFactDispatching) {
        self.dispatcher = dispatcher
    }

    public func call(args: Data) async throws -> Data {
        struct Args: Decodable { let factId: Int64; let triggerTurnId: Int64? }
        let parsed: Args
        do {
            parsed = try JSONDecoder().decode(Args.self, from: args)
        } catch {
            throw InProcessToolError.invalidArguments("forget_fact: \(error)")
        }
        let triggerTurnId = parsed.triggerTurnId ?? 0
        let forgotten = try await dispatcher.forgetFact(id: parsed.factId, triggerTurnId: triggerTurnId)
        let response: [String: Any] = ["forgotten": forgotten, "factId": parsed.factId]
        return (try? JSONSerialization.data(withJSONObject: response, options: [.sortedKeys])) ?? Data()
    }
}
