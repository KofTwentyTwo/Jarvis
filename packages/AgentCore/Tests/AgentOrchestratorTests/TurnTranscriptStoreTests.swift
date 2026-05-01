import XCTest
import AgentCore
@testable import AgentOrchestrator

/// Phase 9 / Plan 1 — TurnTranscriptStore (BLOCKER-1 source of truth).
///
/// Each test asserts a single contract:
/// 1. Empty store → flush returns nil.
/// 2. User-only → flush returns nil (assistant side missing).
/// 3. Assistant-only → flush returns nil (user side missing).
/// 4. Both halves → flush returns the pair.
/// 5. Multiple assistant deltas concatenate.
/// 6. Successful flush removes the entry.
/// 7. Multiple turn IDs are isolated.
final class TurnTranscriptStoreTests: XCTestCase {

    func testInitialFlushReturnsNil() async {
        let store = TurnTranscriptStore()
        let pair = await store.flushPair(TurnID.fresh())
        XCTAssertNil(pair, "fresh store must return nil")
    }

    func testFlushReturnsNilIfOnlyUserAppended() async {
        let store = TurnTranscriptStore()
        let turnId = TurnID.fresh()
        await store.append(turnId: turnId, role: .user, deltaText: "hi")
        let pair = await store.flushPair(turnId)
        XCTAssertNil(pair, "missing assistant side must yield nil")
    }

    func testFlushReturnsNilIfOnlyAssistantAppended() async {
        let store = TurnTranscriptStore()
        let turnId = TurnID.fresh()
        await store.append(turnId: turnId, role: .assistant, deltaText: "hello")
        let pair = await store.flushPair(turnId)
        XCTAssertNil(pair, "missing user side must yield nil")
    }

    func testFlushReturnsBothAfterBothRolesAppended() async {
        let store = TurnTranscriptStore()
        let turnId = TurnID.fresh()
        await store.append(turnId: turnId, role: .user, deltaText: "hi")
        await store.append(turnId: turnId, role: .assistant, deltaText: "hello there")
        let pair = await store.flushPair(turnId)
        XCTAssertEqual(pair?.userText, "hi")
        XCTAssertEqual(pair?.assistantText, "hello there")
    }

    func testAssistantSideAccumulatesMultipleDeltas() async {
        let store = TurnTranscriptStore()
        let turnId = TurnID.fresh()
        await store.append(turnId: turnId, role: .user, deltaText: "hi")
        await store.append(turnId: turnId, role: .assistant, deltaText: "he")
        await store.append(turnId: turnId, role: .assistant, deltaText: "llo")
        await store.append(turnId: turnId, role: .assistant, deltaText: " there")
        let pair = await store.flushPair(turnId)
        XCTAssertEqual(pair?.userText, "hi")
        XCTAssertEqual(pair?.assistantText, "hello there")
    }

    func testFlushRemovesEntry() async {
        let store = TurnTranscriptStore()
        let turnId = TurnID.fresh()
        await store.append(turnId: turnId, role: .user, deltaText: "hi")
        await store.append(turnId: turnId, role: .assistant, deltaText: "hello there")
        let first = await store.flushPair(turnId)
        XCTAssertNotNil(first, "first flush must succeed")
        let second = await store.flushPair(turnId)
        XCTAssertNil(second, "second flush must return nil — entry removed")
    }

    func testIsolationBetweenTurnIds() async {
        let store = TurnTranscriptStore()
        let a = TurnID(rawValue: "turn-A")
        let b = TurnID(rawValue: "turn-B")

        await store.append(turnId: a, role: .user, deltaText: "uA")
        await store.append(turnId: a, role: .assistant, deltaText: "aA")
        await store.append(turnId: b, role: .user, deltaText: "uB")
        await store.append(turnId: b, role: .assistant, deltaText: "aB")

        let pairA = await store.flushPair(a)
        XCTAssertEqual(pairA?.userText, "uA")
        XCTAssertEqual(pairA?.assistantText, "aA")

        // Flushing A must not disturb B.
        let pairB = await store.flushPair(b)
        XCTAssertEqual(pairB?.userText, "uB")
        XCTAssertEqual(pairB?.assistantText, "aB")
    }
}
