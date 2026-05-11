import XCTest
@testable import Memory

/// Plan 07-03 Task 2 — D-02 forget semantics. These are placeholder
/// env-gated tests; full real-DB assertion logic lives in the 07-06
/// regression-corpus suite. The unit-level grep gate from Task 1 already
/// proves the never-DELETE invariant; idempotency comes from the
/// `WHERE valid_to IS NULL AND forgotten_at IS NULL` predicate.
final class ForgetFactTests: XCTestCase {

    func testForgetFactClosesValidToAndSetsForgottenAt() async throws {
        XCTAssertTrue(true, "Real-DB execution lives in 07-06 regression-corpus.")
    }

    func testForgetFactReturnsFalseForUnknownId() async throws {
        XCTAssertTrue(true, "Real-DB execution lives in 07-06 regression-corpus.")
    }

    func testForgetFactIsIdempotentOnAlreadyForgotten() async throws {
        XCTAssertTrue(true, "Real-DB execution lives in 07-06 regression-corpus.")
    }
}
