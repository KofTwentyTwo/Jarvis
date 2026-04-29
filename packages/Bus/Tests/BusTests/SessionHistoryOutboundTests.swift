import XCTest
@testable import Bus

/// Plan 07-03 Task 3 — verifies the additive BusOutbound.sessionHistory case
/// round-trips through Codable and produces the expected wire shape.
final class SessionHistoryOutboundTests: XCTestCase {

    func testSessionHistoryOutboundRoundtrip() throws {
        let row = TurnRow(
            id: 1, sessionId: "A", role: "user",
            content: "hi", source: "userText", createdAt: 1000
        )
        let outbound: BusOutbound = .sessionHistory(turns: [row])
        let encoded = try JSONEncoder().encode(outbound)
        let decoded = try JSONDecoder().decode(BusOutbound.self, from: encoded)
        XCTAssertEqual(decoded, outbound)
    }

    func testSessionHistoryOutboundShape() throws {
        let row = TurnRow(
            id: 1, sessionId: "A", role: "user",
            content: "hi", source: "userText", createdAt: 1000
        )
        let encoded = try JSONEncoder().encode(BusOutbound.sessionHistory(turns: [row]))
        let json = try JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        XCTAssertEqual(json?["type"] as? String, "sessionHistory")
        XCTAssertNotNil(json?["turns"] as? [[String: Any]])
    }

    func testBusProtocolVersionPresent() throws {
        XCTAssertFalse(BUS_PROTOCOL_VERSION.isEmpty,
                       "Plan 07-03 task 3 must bump BUS_PROTOCOL_VERSION minor due to additive sessionHistory case.")
    }
}
