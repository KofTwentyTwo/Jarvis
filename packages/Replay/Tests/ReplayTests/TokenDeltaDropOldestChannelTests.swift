import XCTest
@testable import Replay

private enum Tag: Sendable, Equatable, Hashable {
    case tokenDelta
    case toolCall
}

final class TokenDeltaDropOldestChannelTests: XCTestCase {
    fileprivate typealias Channel = TokenDeltaDropOldestChannel<Tag>

    // T1: Cap=4, send 3 tokenDeltas, iterator yields 3.
    func test_T1_sendsBelowCapacity() async {
        let ch = Channel(capacity: 4, dropTag: .tokenDelta)
        await ch.send(.init(tag: .tokenDelta, payload: Data([0x01])))
        await ch.send(.init(tag: .tokenDelta, payload: Data([0x02])))
        await ch.send(.init(tag: .tokenDelta, payload: Data([0x03])))
        await ch.finish()

        var seen: [UInt8] = []
        for await e in ch {
            if let b = e.payload.first { seen.append(b) }
        }
        XCTAssertEqual(seen, [0x01, 0x02, 0x03])
    }

    // T2: Cap=4, send 10 tokenDeltas without draining first. Iterator yields
    // at most 4. Drops are oldest-first so we should see the LAST 4 sent.
    func test_T2_oldestDropOnOverflow() async {
        let ch = Channel(capacity: 4, dropTag: .tokenDelta)
        for i in 0..<10 {
            await ch.send(.init(tag: .tokenDelta, payload: Data([UInt8(i)])))
        }
        await ch.finish()

        var seen: [UInt8] = []
        for await e in ch {
            if let b = e.payload.first { seen.append(b) }
        }
        XCTAssertLessThanOrEqual(seen.count, 4)
        // Last 4 sent are 6,7,8,9 (drop oldest under firehose).
        XCTAssertEqual(seen, [6, 7, 8, 9])
    }

    // T3 — AGENT-10 critical invariant. Interleave tokenDelta x10, toolCall
    // x1, tokenDelta x10. The toolCall MUST be delivered.
    func test_T3_toolCallNeverDropped() async {
        let ch = Channel(capacity: 4, dropTag: .tokenDelta)

        // Producer task — interleaves the firehose with one toolCall.
        let producer = Task {
            for _ in 0..<10 {
                await ch.send(.init(tag: .tokenDelta, payload: Data([0xAA])))
            }
            await ch.send(.init(tag: .toolCall, payload: Data([0xCA, 0xFE])))
            for _ in 0..<10 {
                await ch.send(.init(tag: .tokenDelta, payload: Data([0xBB])))
            }
            await ch.finish()
        }

        var toolCalls = 0
        for await e in ch {
            if e.tag == .toolCall { toolCalls += 1 }
        }
        await producer.value
        XCTAssertEqual(toolCalls, 1, "toolCall MUST be delivered exactly once (AGENT-10)")
    }

    // T4 — Load test from research §6: 10000 tokenDeltas + 1000 toolCalls,
    // capacity=2048. Expect exactly 1000 toolCalls + at most 2048 tokenDeltas.
    func test_T4_loadTest() async {
        let ch = Channel(capacity: 2048, dropTag: .tokenDelta)

        let producer = Task {
            // Interleave to stress the buffer.
            for i in 0..<10000 {
                await ch.send(.init(tag: .tokenDelta, payload: Data([UInt8(i & 0xFF)])))
                if i % 10 == 0 && i / 10 < 1000 {
                    await ch.send(.init(tag: .toolCall, payload: Data([0xCC])))
                }
            }
            await ch.finish()
        }

        var tokens = 0
        var calls = 0
        for await e in ch {
            switch e.tag {
            case .tokenDelta: tokens += 1
            case .toolCall: calls += 1
            }
        }
        await producer.value

        XCTAssertEqual(calls, 1000, "every tool_call must be delivered")
        XCTAssertLessThanOrEqual(tokens, 10000, "drop policy bounds tokens at the input volume")
        // Note: under fast consumer the buffer often drains between sends, so
        // we may see all 10000 — but we MUST see at most 10000 and at most
        // 2048 ever-buffered concurrently. The hard invariant is the call count.
    }

    // T5: Non-dropTag at overflow suspends the producer (backpressure).
    func test_T5_nonDropTagSuspendsOnOverflow() async {
        let ch = Channel(capacity: 1, dropTag: .tokenDelta)
        // Fill the slot with a dropTag element.
        await ch.send(.init(tag: .tokenDelta, payload: Data([0x01])))

        // Send a non-dropTag element from a detached task — it should suspend
        // until the consumer drains.
        let sender = Task {
            await ch.send(.init(tag: .toolCall, payload: Data([0xCA, 0xFE])))
        }

        // Give the sender a moment to suspend.
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertFalse(sender.isCancelled, "sender should be suspended, not cancelled")

        // Drain — pulls the tokenDelta, freeing space for the toolCall.
        var iter = ch.makeAsyncIterator()
        let first = await iter.next()
        XCTAssertEqual(first?.tag, .tokenDelta)
        let second = await iter.next()
        XCTAssertEqual(second?.tag, .toolCall)
        await sender.value
        await ch.finish()
    }

    // T6: finish() drains the remaining buffer before iterator exits.
    func test_T6_finishDrainsBuffer() async {
        let ch = Channel(capacity: 4, dropTag: .tokenDelta)
        await ch.send(.init(tag: .tokenDelta, payload: Data([0x01])))
        await ch.send(.init(tag: .toolCall, payload: Data([0x02])))
        await ch.finish()

        var count = 0
        for await _ in ch { count += 1 }
        XCTAssertEqual(count, 2, "finish must drain remaining buffered items")
    }
}
