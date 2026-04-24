import XCTest
import AgentCore
import AgentOrchestrator
@testable import DevOverlay

final class DevSnapshotTests: XCTestCase {
    // DS1: `.initial` is the zero snapshot.
    func test_DS1_initialIsZero() {
        let s = DevSnapshot.initial
        XCTAssertEqual(s.state, .idle)
        XCTAssertNil(s.turnId)
        XCTAssertEqual(s.inputTokens, 0)
        XCTAssertEqual(s.outputTokens, 0)
        XCTAssertEqual(s.cacheCreationInputTokens, 0)
        XCTAssertEqual(s.cacheReadInputTokens, 0)
        XCTAssertEqual(s.ttfbMs, 0)
        XCTAssertEqual(s.totalMs, 0)
        XCTAssertTrue(s.toolCalls.isEmpty)
        XCTAssertEqual(s.provider, "")
        XCTAssertEqual(s.modelId, "")
    }

    // DS2a: cacheHitPercentage returns 0 when both counters are 0.
    func test_DS2a_cacheHitPercentageZeroWhenBothZero() {
        let s = DevSnapshot.initial
        XCTAssertEqual(s.cacheHitPercentage, 0.0)
    }

    // DS2b: cacheHitPercentage = read / (read + creation) * 100.
    func test_DS2b_cacheHitPercentageComputed() {
        let s = DevSnapshot.initial.with(
            cacheCreationInputTokens: 40,
            cacheReadInputTokens: 60
        )
        XCTAssertEqual(s.cacheHitPercentage, 60.0, accuracy: 0.001)
    }

    // DS2c: 100% hit when creation is zero.
    func test_DS2c_cacheHitPercentageAllRead() {
        let s = DevSnapshot.initial.with(
            cacheCreationInputTokens: 0,
            cacheReadInputTokens: 100
        )
        XCTAssertEqual(s.cacheHitPercentage, 100.0, accuracy: 0.001)
    }

    // DS3: ToolCallRow carries the expected fields (construction check).
    func test_DS3_toolCallRowFields() {
        let row = ToolCallRow(
            id: "t1",
            name: "get_time",
            status: .completed,
            durationMs: 42,
            preview: "22:57 UTC",
            error: nil
        )
        XCTAssertEqual(row.id, "t1")
        XCTAssertEqual(row.name, "get_time")
        XCTAssertEqual(row.status, .completed)
        XCTAssertEqual(row.durationMs, 42)
        XCTAssertEqual(row.preview, "22:57 UTC")
        XCTAssertNil(row.error)
    }

    // DS4: Equatable — identical fields compare equal.
    func test_DS4_snapshotEquatable() {
        let turnId = TurnID(rawValue: "abc")
        let row = ToolCallRow(id: "t1", name: "x", status: .pending, durationMs: 0, preview: nil)
        let a = DevSnapshot(
            state: .thinking,
            turnId: turnId,
            provider: "anthropic",
            modelId: "claude-opus-4-7",
            inputTokens: 100,
            outputTokens: 42,
            cacheCreationInputTokens: 10,
            cacheReadInputTokens: 5,
            ttfbMs: 250,
            totalMs: 1000,
            toolCalls: [row]
        )
        let b = DevSnapshot(
            state: .thinking,
            turnId: turnId,
            provider: "anthropic",
            modelId: "claude-opus-4-7",
            inputTokens: 100,
            outputTokens: 42,
            cacheCreationInputTokens: 10,
            cacheReadInputTokens: 5,
            ttfbMs: 250,
            totalMs: 1000,
            toolCalls: [row]
        )
        XCTAssertEqual(a, b)
    }

    // DS5: `.with` preserves unchanged fields.
    func test_DS5_withPreservesFields() {
        let s = DevSnapshot.initial
            .with(state: .thinking)
            .with(outputTokens: 99)
        XCTAssertEqual(s.state, .thinking)
        XCTAssertEqual(s.outputTokens, 99)
        XCTAssertEqual(s.inputTokens, 0)
        XCTAssertNil(s.turnId)
    }
}
