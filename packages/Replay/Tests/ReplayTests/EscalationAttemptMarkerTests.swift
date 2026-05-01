import XCTest
import AgentCore
@testable import Replay

/// Plan 09-02 / D-02 — proves `.escalationAttempt` is a structurally distinct
/// `ReplayEvent` case from `.streamTruncatedRetry`. The two retry paths share
/// "I had to retry" semantics but differ on `turnId` reuse:
///   - `.escalationAttempt` → SAME turnId across attempts; user sees one final answer.
///   - `.streamTruncatedRetry` is recorded on the turn row's `stop_reason`
///     column, not as a `ReplayEvent` case (see ReplayLog.endTurn). Adding
///     `.escalationAttempt` as a first-class event case keeps the two paths
///     visibly distinct in the events table.
final class EscalationAttemptMarkerTests: XCTestCase {

    func testEscalationAttemptIsDistinctCaseFromMemoryMutation() {
        let turnId = TurnID(rawValue: "t-abc")
        let escalation: ReplayEvent = .escalationAttempt(turnId: turnId, kind: .t1ToT2)
        let memoryMutation: ReplayEvent = .memoryMutation(Data("x".utf8))

        var sawEscalation = false
        var sawMemoryMutation = false
        for ev in [escalation, memoryMutation] {
            switch ev {
            case .escalationAttempt: sawEscalation = true
            case .memoryMutation: sawMemoryMutation = true
            default: break
            }
        }
        XCTAssertTrue(sawEscalation, "escalationAttempt arm did not match")
        XCTAssertTrue(sawMemoryMutation, "memoryMutation arm did not match")
    }

    func testEscalationAttemptEncodesToDistinctKind() {
        let turnId = TurnID(rawValue: "t-xyz")
        let escalation: ReplayEvent = .escalationAttempt(turnId: turnId, kind: .t1ToT2)
        let (kind, payload) = escalation.encoded()
        XCTAssertEqual(kind, ReplayEventKind.escalationAttempt.rawValue)
        XCTAssertEqual(kind, "escalation_attempt")
        XCTAssertFalse(payload.isEmpty, "escalation payload should carry the turnId+kind envelope")

        // The JSON envelope must round-trip — a forensic reader must be able
        // to recover the kind without re-reading the turns table.
        let dict = try? JSONSerialization.jsonObject(with: payload) as? [String: String]
        XCTAssertEqual(dict?["turn_id"], "t-xyz")
        XCTAssertEqual(dict?["kind"], "t1_to_t2")
    }

    func testEscalationAttemptKindIsExtensible() {
        // Pattern-match each case to verify EscalationKind isn't accidentally
        // collapsed to a single bool. If we add `.t2ToT3` later, this test
        // breaks at compile-time and forces an explicit decision.
        let kind: EscalationKind = .t1ToT2
        switch kind {
        case .t1ToT2: break
        }
    }
}
