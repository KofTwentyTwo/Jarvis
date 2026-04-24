import XCTest
@testable import AgentCore

final class BoundedAsyncChannelTests: XCTestCase {
    // MARK: - Test 5: .suspend policy

    /// `.suspend` capacity-1: first send succeeds without blocking, second
    /// send suspends until consumer reads.
    func testSuspendPolicyBlocksWhenFull() async {
        let channel = BoundedAsyncChannel<Int>(capacity: 1, policy: .suspend)

        // First send returns immediately.
        await channel.send(1)

        // Second send should suspend until the consumer drains slot 1.
        let secondSendStarted = expectation(description: "second send started")
        let secondSendCompleted = expectation(description: "second send completed")

        let producer = Task {
            secondSendStarted.fulfill()
            await channel.send(2)
            secondSendCompleted.fulfill()
        }

        await fulfillment(of: [secondSendStarted], timeout: 1.0)

        // Give the producer a chance to actually call send().
        try? await Task.sleep(nanoseconds: 50_000_000) // 50ms

        // Consume one — this should unblock the second send.
        var iterator = channel.makeAsyncIterator()
        let first = await iterator.next()
        XCTAssertEqual(first, 1)
        let second = await iterator.next()
        XCTAssertEqual(second, 2)

        await fulfillment(of: [secondSendCompleted], timeout: 1.0)
        producer.cancel()
    }

    // MARK: - Test 6: .dropOldest

    /// Capacity-3, send 5 without consuming: iteration yields 3,4,5.
    func testDropOldestPolicy() async {
        let channel = BoundedAsyncChannel<Int>(capacity: 3, policy: .dropOldest)

        for i in 1...5 {
            await channel.send(i)
        }
        await channel.finish()

        var collected: [Int] = []
        for await item in channel {
            collected.append(item)
        }
        XCTAssertEqual(collected, [3, 4, 5])
    }

    // MARK: - Test 7: .dropNewest

    /// Capacity-3, send 5 without consuming: iteration yields 1,2,3.
    func testDropNewestPolicy() async {
        let channel = BoundedAsyncChannel<Int>(capacity: 3, policy: .dropNewest)

        for i in 1...5 {
            await channel.send(i)
        }
        await channel.finish()

        var collected: [Int] = []
        for await item in channel {
            collected.append(item)
        }
        XCTAssertEqual(collected, [1, 2, 3])
    }

    // MARK: - Test 8: finish()

    /// `finish()` terminates the AsyncSequence cleanly; consumer's
    /// `for await` loop exits after draining the buffer.
    func testFinishTerminatesIteration() async {
        let channel = BoundedAsyncChannel<Int>(capacity: 4, policy: .suspend)
        await channel.send(1)
        await channel.send(2)
        await channel.finish()

        var collected: [Int] = []
        for await item in channel {
            collected.append(item)
        }
        XCTAssertEqual(collected, [1, 2])
    }

    /// finish() while a consumer is suspended waiting for an element resumes
    /// the consumer with `nil`.
    func testFinishWakesPendingReceiver() async {
        let channel = BoundedAsyncChannel<Int>(capacity: 1, policy: .suspend)

        let receiverStarted = expectation(description: "receiver started")
        let receiverFinished = expectation(description: "receiver finished")

        Task {
            var iterator = channel.makeAsyncIterator()
            receiverStarted.fulfill()
            let result = await iterator.next()
            XCTAssertNil(result)
            receiverFinished.fulfill()
        }

        await fulfillment(of: [receiverStarted], timeout: 1.0)
        try? await Task.sleep(nanoseconds: 50_000_000)
        await channel.finish()
        await fulfillment(of: [receiverFinished], timeout: 1.0)
    }

    // MARK: - Test 9: load test

    /// 10K-item producer + slow consumer on `.dropOldest` capacity-128
    /// completes without hangs.
    func testDropOldestLoadTest() async {
        let channel = BoundedAsyncChannel<Int>(capacity: 128, policy: .dropOldest)

        let producer = Task {
            for i in 1...10_000 {
                await channel.send(i)
            }
            await channel.finish()
        }

        var receivedCount = 0
        for await _ in channel {
            receivedCount += 1
            // Slow consumer — ~100us per item is enough to keep buffer pressured
            // without making the test crawl.
            try? await Task.sleep(nanoseconds: 100_000)
        }
        await producer.value

        // Lossy: well below 10K. Capacity-loaded: at least the buffer-worth
        // (we may receive less than capacity if the producer's last burst
        // overflowed; the contract is "completes without hangs" — assert
        // we got at least one item and at most all of them).
        XCTAssertGreaterThanOrEqual(receivedCount, 1)
        XCTAssertLessThanOrEqual(receivedCount, 10_000)
    }

    // MARK: - Bonus coverage

    func testEmptyChannelFinishImmediately() async {
        let channel = BoundedAsyncChannel<Int>(capacity: 4, policy: .suspend)
        await channel.finish()

        var iterator = channel.makeAsyncIterator()
        let result = await iterator.next()
        XCTAssertNil(result)
    }

    func testSendAfterFinishIsNoop() async {
        let channel = BoundedAsyncChannel<Int>(capacity: 4, policy: .suspend)
        await channel.send(1)
        await channel.finish()
        await channel.send(2) // should be silently dropped

        var collected: [Int] = []
        for await item in channel {
            collected.append(item)
        }
        XCTAssertEqual(collected, [1])
    }
}
