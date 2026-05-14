import XCTest
@testable import AgentCore

final class OllamaFailureKindTests: XCTestCase {
    func test_failure_kind_round_trips_codable() throws {
        for kind in OllamaFailureKind.allCases {
            let data = try JSONEncoder().encode(kind)
            let decoded = try JSONDecoder().decode(OllamaFailureKind.self, from: data)
            XCTAssertEqual(decoded, kind)
        }
    }

    func test_escalation_decision_round_trips_codable() throws {
        let firedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let decision = EscalationDecision(
            from: .ollama,
            to: .anthropic,
            reason: .malformedToolCall,
            firedAt: firedAt
        )
        let data = try JSONEncoder().encode(decision)
        let decoded = try JSONDecoder().decode(EscalationDecision.self, from: data)
        XCTAssertEqual(decoded, decision)
        XCTAssertEqual(decoded.firedAt, firedAt)
    }
}
