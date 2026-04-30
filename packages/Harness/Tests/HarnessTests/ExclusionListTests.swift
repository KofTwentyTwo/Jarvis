import Testing
import Foundation
@testable import Harness

@Suite("ExclusionListTests")
struct ExclusionListTests {
    @Test("OBS-02 default contains the eight inherited fields")
    func obs02DefaultHasEightFields() {
        let list = ExclusionList.obs02Default
        let expected: Set<String> = [
            "row_id", "session_id", "turn_id", "tool_use_id",
            "message_id", "ts", "monotonic_ns", "turn_nonce",
        ]
        #expect(list.alwaysExcluded == expected)
        #expect(list.alwaysExcluded.count == 8)
        #expect(list.nondeterministicUnderSampling.isEmpty)
    }

    @Test("Decodes from JSON sidecar")
    func decodesFromJSON() throws {
        let json = """
        {"alwaysExcluded":["row_id","ts"],"nondeterministicUnderSampling":["textDelta"]}
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(ExclusionList.self, from: json)
        #expect(decoded.alwaysExcluded == ["row_id", "ts"])
        #expect(decoded.nondeterministicUnderSampling == ["textDelta"])
    }

    @Test("Round-trips through JSON encoder")
    func roundTrips() throws {
        let original = ExclusionList.obs02Default
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ExclusionList.self, from: data)
        #expect(decoded == original)
    }
}
