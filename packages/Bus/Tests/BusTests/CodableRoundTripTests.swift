import XCTest
@testable import Bus

/// Round-trip parity: decode fixture → re-encode → normalize → compare.
///
/// Plan 02 (TS mirror) reads the same fixture files and Plan 04's parity
/// script asserts the two fixture directories stay in sync. Together with
/// the exhaustive switches in `BusOutbound` / `BusInbound`, these tests are
/// the build-time line of defense against schema drift.
final class CodableRoundTripTests: XCTestCase {
    // MARK: - Helpers

    private func loadFixture(_ name: String) throws -> Data {
        guard let url = Bundle.module.url(forResource: name, withExtension: "json") else {
            XCTFail("missing fixture: \(name).json")
            throw CocoaError(.fileNoSuchFile)
        }
        return try Data(contentsOf: url)
    }

    /// Normalize JSON so key-order differences don't fail comparisons.
    /// `NSDictionary.isEqual` is order-independent, so we decode both sides
    /// to a generic JSON object graph first.
    private func normalize(_ data: Data) throws -> NSObject {
        let value = try JSONSerialization.jsonObject(with: data, options: [])
        return value as! NSObject
    }

    private func assertOutboundRoundTrips(
        fixture: String,
        expect: BusOutbound,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let data = try loadFixture(fixture)
        let decoded = try BusCoder.makeDecoder().decode(BusOutbound.self, from: data)
        XCTAssertEqual(decoded, expect, "decoded value mismatch for \(fixture)", file: file, line: line)

        let reencoded = try BusCoder.makeEncoder().encode(decoded)
        let originalNorm = try normalize(data)
        let reencodedNorm = try normalize(reencoded)
        XCTAssertEqual(
            originalNorm, reencodedNorm,
            "round-trip mismatch for \(fixture).\nexpected: \(String(data: data, encoding: .utf8) ?? "<?>")\ngot:      \(String(data: reencoded, encoding: .utf8) ?? "<?>")",
            file: file, line: line
        )
    }

    private func assertInboundRoundTrips(
        fixture: String,
        expect: BusInbound,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let data = try loadFixture(fixture)
        let decoded = try BusCoder.makeDecoder().decode(BusInbound.self, from: data)
        XCTAssertEqual(decoded, expect, "decoded value mismatch for \(fixture)", file: file, line: line)

        let reencoded = try BusCoder.makeEncoder().encode(decoded)
        let originalNorm = try normalize(data)
        let reencodedNorm = try normalize(reencoded)
        XCTAssertEqual(
            originalNorm, reencodedNorm,
            "round-trip mismatch for \(fixture)",
            file: file, line: line
        )
    }

    // MARK: - Outbound round-trips (8 variants; HudState expanded × 7)

    func test_roundTrip_hello() throws {
        try assertOutboundRoundTrips(
            fixture: "hello",
            expect: .hello(version: "2.0.0")
        )
    }

    func test_roundTrip_hudState_idle() throws {
        try assertOutboundRoundTrips(fixture: "hudState.idle", expect: .hudState(.idle))
    }

    func test_roundTrip_hudState_listening() throws {
        try assertOutboundRoundTrips(fixture: "hudState.listening", expect: .hudState(.listening))
    }

    func test_roundTrip_hudState_thinking() throws {
        try assertOutboundRoundTrips(fixture: "hudState.thinking", expect: .hudState(.thinking))
    }

    func test_roundTrip_hudState_speaking() throws {
        try assertOutboundRoundTrips(fixture: "hudState.speaking", expect: .hudState(.speaking))
    }

    func test_roundTrip_hudState_awaitingConfirmation() throws {
        try assertOutboundRoundTrips(
            fixture: "hudState.awaitingConfirmation",
            expect: .hudState(.awaitingConfirmation)
        )
    }

    func test_roundTrip_hudState_reconfiguring() throws {
        try assertOutboundRoundTrips(
            fixture: "hudState.reconfiguring",
            expect: .hudState(.reconfiguring)
        )
    }

    func test_roundTrip_hudState_booting() throws {
        try assertOutboundRoundTrips(fixture: "hudState.booting", expect: .hudState(.booting))
    }

    func test_roundTrip_tokenDelta() throws {
        try assertOutboundRoundTrips(
            fixture: "tokenDelta",
            expect: .tokenDelta(text: "Hello, world!")
        )
    }

    func test_roundTrip_audioLevel() throws {
        try assertOutboundRoundTrips(
            fixture: "audioLevel",
            expect: .audioLevel(rms: 0.42)
        )
    }

    func test_roundTrip_toolCallStart() throws {
        let id = UUID(uuidString: "550e8400-e29b-41d4-a716-446655440000")!
        try assertOutboundRoundTrips(
            fixture: "toolCallStart",
            expect: .toolCallStart(id: id, name: "get_time", argsPreview: "{}")
        )
    }

    func test_roundTrip_toolCallEnd() throws {
        let id = UUID(uuidString: "550e8400-e29b-41d4-a716-446655440000")!
        try assertOutboundRoundTrips(
            fixture: "toolCallEnd",
            expect: .toolCallEnd(id: id, ok: true, previewOrError: "\"2026-04-23T16:00:00Z\"")
        )
    }

    func test_roundTrip_turnStarted() throws {
        let id = UUID(uuidString: "6ba7b810-9dad-11d1-80b4-00c04fd430c8")!
        try assertOutboundRoundTrips(fixture: "turnStarted", expect: .turnStarted(id: id))
    }

    func test_roundTrip_turnEnded() throws {
        let id = UUID(uuidString: "6ba7b810-9dad-11d1-80b4-00c04fd430c8")!
        try assertOutboundRoundTrips(
            fixture: "turnEnded",
            expect: .turnEnded(id: id, terminator: .completed)
        )
    }

    // MARK: - Inbound round-trips

    func test_roundTrip_helloAck() throws {
        try assertInboundRoundTrips(
            fixture: "helloAck",
            expect: .helloAck(version: "2.0.0")
        )
    }

    // MARK: - Shape invariants (these prove hand-written Codable is load-bearing)

    /// If SE-0295 synthesis leaked, we'd see `{"hudState":{"state":"idle"}}`.
    /// The required wire shape is `{"type":"hudState","state":"idle"}`.
    func test_hudStateEncodesWithTypeDiscriminatorNotSynthesizedShape() throws {
        let encoded = try BusCoder.makeEncoder().encode(BusOutbound.hudState(.idle))
        let obj = try JSONSerialization.jsonObject(with: encoded, options: []) as! [String: Any]

        XCTAssertEqual(obj["type"] as? String, "hudState")
        XCTAssertEqual(obj["state"] as? String, "idle")
        XCTAssertNil(obj["hudState"], "synthesized SE-0295 Codable leaked: nested payload under case name")
    }

    /// Same invariant for `tokenDelta` — required wire shape is
    /// `{"type":"tokenDelta","text":"hi"}`.
    func test_tokenDeltaEncodesWithTypeDiscriminator() throws {
        let encoded = try BusCoder.makeEncoder().encode(BusOutbound.tokenDelta(text: "hi"))
        let obj = try JSONSerialization.jsonObject(with: encoded, options: []) as! [String: Any]

        XCTAssertEqual(obj["type"] as? String, "tokenDelta")
        XCTAssertEqual(obj["text"] as? String, "hi")
        XCTAssertNil(obj["tokenDelta"])
    }

    /// The `helloAck` shape is `{"type":"helloAck","version":"2.0.0"}`.
    func test_helloAckEncodesWithTypeDiscriminator() throws {
        let encoded = try BusCoder.makeEncoder().encode(BusInbound.helloAck(version: "2.0.0"))
        let obj = try JSONSerialization.jsonObject(with: encoded, options: []) as! [String: Any]

        XCTAssertEqual(obj["type"] as? String, "helloAck")
        XCTAssertEqual(obj["version"] as? String, "2.0.0")
    }

    // MARK: - UUID formatting (Pitfall 6: JSONEncoder defaults to uppercase)

    func test_uuidIsEncodedAsLowercaseString() throws {
        let id = UUID(uuidString: "550E8400-E29B-41D4-A716-446655440000")!
        let encoded = try BusCoder.makeEncoder().encode(BusOutbound.turnStarted(id: id))
        let obj = try JSONSerialization.jsonObject(with: encoded, options: []) as! [String: Any]

        let raw = obj["id"] as? String
        XCTAssertEqual(raw, "550e8400-e29b-41d4-a716-446655440000")
        XCTAssertFalse(raw?.contains(where: { $0.isUppercase }) ?? true, "UUID must encode lowercase")
    }

    // MARK: - Negative tests (drift detection)

    func test_decodeUnknownDiscriminatorFails() {
        let payload = #"{"type":"unknown","state":"idle"}"#.data(using: .utf8)!
        XCTAssertThrowsError(
            try BusCoder.makeDecoder().decode(BusOutbound.self, from: payload)
        ) { error in
            XCTAssertTrue(error is DecodingError, "expected DecodingError for unknown discriminator")
        }
    }

    func test_decodeMissingDiscriminatorFails() {
        let payload = #"{"version":"2.0.0"}"#.data(using: .utf8)!
        XCTAssertThrowsError(
            try BusCoder.makeDecoder().decode(BusOutbound.self, from: payload)
        ) { error in
            XCTAssertTrue(error is DecodingError, "expected DecodingError for missing type key")
        }
    }

    func test_decodeInvalidUUIDFails() {
        let payload = #"{"type":"turnStarted","id":"not-a-uuid"}"#.data(using: .utf8)!
        XCTAssertThrowsError(
            try BusCoder.makeDecoder().decode(BusOutbound.self, from: payload)
        ) { error in
            XCTAssertTrue(error is DecodingError, "expected DecodingError for malformed UUID")
        }
    }

    func test_inboundDecodeUnknownDiscriminatorFails() {
        let payload = #"{"type":"unknown"}"#.data(using: .utf8)!
        XCTAssertThrowsError(
            try BusCoder.makeDecoder().decode(BusInbound.self, from: payload)
        ) { error in
            XCTAssertTrue(error is DecodingError, "expected DecodingError for unknown inbound discriminator")
        }
    }

    // MARK: - HudState case coverage guard

    func test_allHudStateCasesHaveFixtures() throws {
        // Every HudState case must have a dedicated fixture. If this test
        // fails after an enum case is added, add the fixture and update the
        // switch below.
        for state in HudState.allCases {
            let fixtureName = "hudState.\(state.rawValue)"
            try assertOutboundRoundTrips(fixture: fixtureName, expect: .hudState(state))
        }
    }
}
