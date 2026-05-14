import XCTest
@testable import AgentCore

final class OllamaFailureKindTests: XCTestCase {
    func test_failure_kind_round_trips_codable() throws {
        let kinds: [OllamaFailureKind] = [
            .streamTruncated, .malformedToolCall, .unknownTool,
            .refusal, .connectionFailure, .emptyResponse
        ]
        for kind in kinds {
            let data = try JSONEncoder().encode(kind)
            let decoded = try JSONDecoder().decode(OllamaFailureKind.self, from: data)
            XCTAssertEqual(decoded, kind)
        }
    }

    func test_escalation_decision_is_sendable_codable() throws {
        let decision = EscalationDecision(
            from: .ollama,
            to: .anthropic,
            reason: .malformedToolCall,
            firedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let data = try JSONEncoder().encode(decision)
        let decoded = try JSONDecoder().decode(EscalationDecision.self, from: data)
        XCTAssertEqual(decoded.from, .ollama)
        XCTAssertEqual(decoded.to, .anthropic)
        XCTAssertEqual(decoded.reason, .malformedToolCall)
    }
}
