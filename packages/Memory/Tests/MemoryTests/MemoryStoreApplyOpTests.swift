import XCTest
import Foundation
import AgentCore
import Replay
@testable import Memory

/// Plan 07-02 Task 1: applyOp + MemoryOp parsing + ReplayEvent.memoryMutation
/// round-trip. The DB-roundtrip tests are env-gated (JARVIS_VEC0_STUB_PATH);
/// the parse + encoded() tests run unconditionally.
final class MemoryStoreApplyOpTests: XCTestCase {

    // MARK: - Mock sink

    final class MockReplayLog: MemoryReplaySink, @unchecked Sendable {
        let lock = NSLock()
        struct Recorded {
            let event: ReplayEvent
            let triggerTurnId: Int64
        }
        private var _recorded: [Recorded] = []

        var recorded: [Recorded] {
            lock.lock(); defer { lock.unlock() }
            return _recorded
        }

        func record(_ event: ReplayEvent, forTriggerTurnId triggerTurnId: Int64) {
            lock.lock(); defer { lock.unlock() }
            _recorded.append(Recorded(event: event, triggerTurnId: triggerTurnId))
        }
    }

    // MARK: - Test 1: ADD inserts a fact

    func testApplyOpADDInsertsFact() async throws {
        let tmp = try Self.tempDB()
        let store = try MemoryStore(databaseURL: tmp)
        let mock = MockReplayLog()
        await store.setReplayLog(mock)
        // D-5/D-6 closure (2026-05-11): vec0 is now statically linked, schema
        // migration applies cleanly, and `PRAGMA foreign_keys=ON` is honored.
        // facts.source_turn_id REFERENCES turns(id) — must seed a turn row
        // before applyOp passes sourceTurnId: 1.
        try await Self.seedTurnRow(store, id: 1)

        let fact = try await store.applyOp(
            .add(subject: "Sarah", predicate: "works_at", object: "Acme", embedding: nil),
            sourceTurnId: 1
        )
        XCTAssertNotNil(fact)
        guard let fact else { return }
        XCTAssertGreaterThan(fact.id, 0)
        XCTAssertEqual(fact.subject, "Sarah")
        XCTAssertNil(fact.validTo)
        XCTAssertNil(fact.supersededBy)

        let activeCount = try await store.queryRowCount(
            "SELECT id FROM facts WHERE valid_to IS NULL AND subject='Sarah'"
        )
        XCTAssertEqual(activeCount, 1)
    }

    // MARK: - Test 2: UPDATE closes prior + inserts new

    func testApplyOpUPDATEClosesPriorAndInsertsNew() async throws {
        let tmp = try Self.tempDB()
        let store = try MemoryStore(databaseURL: tmp)
        // D-5/D-6 FK enforcement: two turn rows for sourceTurnId 1 and 2.
        try await Self.seedTurnRow(store, id: 1)
        try await Self.seedTurnRow(store, id: 2)

        let prior = try await store.applyOp(
            .add(subject: "Sarah", predicate: "works_at", object: "Acme", embedding: nil),
            sourceTurnId: 1
        )
        XCTAssertNotNil(prior)
        guard let prior else { return }

        let new = try await store.applyOp(
            .update(supersedes: prior.id, subject: "Sarah", predicate: "works_at", object: "Globex", embedding: nil),
            sourceTurnId: 2
        )
        XCTAssertNotNil(new)
        guard let new else { return }
        XCTAssertGreaterThan(new.id, prior.id)

        // Prior row's valid_to is set, superseded_by points to new.
        let activeNow = try await store.queryRowCount(
            "SELECT id FROM facts WHERE valid_to IS NULL AND subject='Sarah'"
        )
        XCTAssertEqual(activeNow, 1, "Exactly one active 'Sarah' fact after supersede.")

        let priorClosed = try await store.queryRowCount(
            "SELECT id FROM facts WHERE id=\(prior.id) AND valid_to IS NOT NULL AND superseded_by=\(new.id)"
        )
        XCTAssertEqual(priorClosed, 1, "Prior row must be closed and linked to the new row.")
    }

    // MARK: - Test 4: bad UPDATE rolls back

    func testApplyOpRollsBackOnFailure() async throws {
        let tmp = try Self.tempDB()
        let store = try MemoryStore(databaseURL: tmp)

        let beforeCount = try await store.queryRowCount("SELECT id FROM facts")

        // supersedes id 9999 does not exist; UPDATE affects 0 rows; the
        // applyOp transaction must roll back leaving facts unchanged.
        do {
            _ = try await store.applyOp(
                .update(supersedes: 9999, subject: "Sarah", predicate: "works_at", object: "Globex", embedding: nil),
                sourceTurnId: 7
            )
            XCTFail("Expected applyOpFailed when supersedes points at nonexistent id.")
        } catch let MemoryError.applyOpFailed {
            // expected
        } catch {
            XCTFail("Expected applyOpFailed, got \(error)")
        }

        let afterCount = try await store.queryRowCount("SELECT id FROM facts")
        XCTAssertEqual(afterCount, beforeCount, "Rollback must leave row count unchanged.")
    }

    // MARK: - Test 5: NOOP records nothing

    func testApplyOpEmitsNothingForNOOP() async throws {
        // Construct a MemoryStore-less path: applyOp(.noop) returns nil
        // before any SQL — but to keep the sink injection chain end-to-end
        // we still need a store. Skip if vec0 unavailable.
        let tmp = try Self.tempDB()
        let store = try MemoryStore(databaseURL: tmp)
        let mock = MockReplayLog()
        await store.setReplayLog(mock)

        let result = try await store.applyOp(.noop, sourceTurnId: 7)
        XCTAssertNil(result)
        XCTAssertTrue(mock.recorded.isEmpty,
                      "NOOPs are debug-only per RESEARCH §13; no replay event must be emitted.")
    }

    // MARK: - Test 6: ReplayEvent.memoryMutation kind round-trip

    func testReplayEventMemoryMutationKindRoundtrip() {
        let bytes = Data("{\"op\":\"ADD\",\"subject\":\"x\"}".utf8)
        let event = ReplayEvent.memoryMutation(bytes)
        let (kind, payload) = event.encoded()
        XCTAssertEqual(kind, "memory_mutation")
        XCTAssertEqual(payload, bytes)
    }

    // MARK: - Tests 7-8: parseApplyMemoryOps

    func testParseApplyMemoryOpsHappyPath() throws {
        let json: [String: Any] = ["ops": [
            ["op": "ADD", "subject": "Sarah", "predicate": "works_at", "object": "Acme"],
            ["op": "UPDATE", "supersedes_fact_id": 17, "subject": "Sarah", "predicate": "works_at", "object": "Globex"],
            ["op": "NOOP"],
        ]]
        let data = try JSONSerialization.data(withJSONObject: json)
        let ops = try MemoryOp.parseApplyMemoryOps(data)
        XCTAssertEqual(ops.count, 3)

        guard case let .add(s, p, o, _) = ops[0] else {
            return XCTFail("expected ADD at [0], got \(ops[0])")
        }
        XCTAssertEqual(s, "Sarah")
        XCTAssertEqual(p, "works_at")
        XCTAssertEqual(o, "Acme")

        guard case let .update(supersedes, s2, _, o2, _) = ops[1] else {
            return XCTFail("expected UPDATE at [1], got \(ops[1])")
        }
        XCTAssertEqual(supersedes, 17)
        XCTAssertEqual(s2, "Sarah")
        XCTAssertEqual(o2, "Globex")

        guard case .noop = ops[2] else {
            return XCTFail("expected NOOP at [2], got \(ops[2])")
        }
    }

    func testParseApplyMemoryOpsDropsInvalid() throws {
        let json: [String: Any] = ["ops": [
            // empty subject — dropped
            ["op": "ADD", "subject": "", "predicate": "p", "object": "o"],
            // missing supersedes_fact_id — dropped
            ["op": "UPDATE", "subject": "x", "predicate": "y", "object": "z"],
            // unknown op — dropped
            ["op": "FROBNICATE"],
        ]]
        let data = try JSONSerialization.data(withJSONObject: json)
        let ops = try MemoryOp.parseApplyMemoryOps(data)
        XCTAssertTrue(ops.isEmpty, "Invalid entries must be silently dropped.")
    }

    func testParseApplyMemoryOpsThrowsOnMissingTopLevel() {
        // missing top-level "ops" — throws extractorInvalidArgs
        let bad = Data("{\"foo\":1}".utf8)
        XCTAssertThrowsError(try MemoryOp.parseApplyMemoryOps(bad)) { err in
            guard case MemoryError.extractorInvalidArgs = err else {
                return XCTFail("Expected extractorInvalidArgs, got \(err)")
            }
        }
    }

    // MARK: - helpers

    private static func tempDB() throws -> URL {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("memorytests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        return tmp.appendingPathComponent("jarvis.db")
    }

    /// D-5/D-6 helper: insert a placeholder turn row so applyOp's
    /// `facts.source_turn_id REFERENCES turns(id)` foreign key resolves.
    /// Returns when the row's auto-incremented id matches the requested
    /// `id` — relies on inserts happening in order on a fresh DB.
    fileprivate static func seedTurnRow(_ store: MemoryStore, id: Int64) async throws {
        try await store.appendTurn(
            sessionId: "applyop-test-seed",
            role: "user",
            content: "seed-\(id)",
            source: "test",
            createdAt: id
        )
    }
}
