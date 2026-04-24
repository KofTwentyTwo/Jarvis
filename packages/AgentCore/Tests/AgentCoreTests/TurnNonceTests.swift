import XCTest
@testable import AgentCore

final class TurnNonceTests: XCTestCase {
    /// TN1: `TurnNonce.fresh()` returns a non-empty string and is collision-free
    /// across 10,000 iterations (probabilistic — 16 random bytes ≈ 128 bits of entropy).
    func test_TN1_freshIsNonEmptyAndUniqueAcrossManyCalls() {
        var seen = Set<String>()
        for _ in 0..<10_000 {
            let n = TurnNonce.fresh()
            XCTAssertFalse(n.rawValue.isEmpty, "rawValue must not be empty")
            XCTAssertFalse(seen.contains(n.rawValue), "Collision after \(seen.count) iterations")
            seen.insert(n.rawValue)
        }
        XCTAssertEqual(seen.count, 10_000)
    }

    /// TN2: Format — base64url alphabet only ([A-Za-z0-9_-]+); length 20-24
    /// (16 bytes → 22 base64url chars typical, no padding).
    func test_TN2_formatIsBase64URLAlphabetAndExpectedLength() {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_-")
        for _ in 0..<200 {
            let n = TurnNonce.fresh()
            let chars = CharacterSet(charactersIn: n.rawValue)
            XCTAssertTrue(chars.isSubset(of: allowed), "Disallowed char in \(n.rawValue)")
            XCTAssertGreaterThanOrEqual(n.rawValue.count, 20, "len=\(n.rawValue.count) for \(n.rawValue)")
            XCTAssertLessThanOrEqual(n.rawValue.count, 24, "len=\(n.rawValue.count) for \(n.rawValue)")
        }
    }

    /// TN3: rawValue contains no `+`, `/`, or `=` (true base64url, not classic base64).
    func test_TN3_noClassicBase64Characters() {
        for _ in 0..<200 {
            let n = TurnNonce.fresh()
            XCTAssertFalse(n.rawValue.contains("+"), "found + in \(n.rawValue)")
            XCTAssertFalse(n.rawValue.contains("/"), "found / in \(n.rawValue)")
            XCTAssertFalse(n.rawValue.contains("="), "found = in \(n.rawValue)")
        }
    }
}
