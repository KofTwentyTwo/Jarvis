// LogBroadcasterTests.swift
//
// Exercises the buffer/replay/fan-out semantics of LogBroadcaster +
// BroadcastLogHandler. Coverage:
//   - LB1: publish appends to the buffer.
//   - LB2: buffer caps at `bufferCapacity` (drop-oldest).
//   - LB3: subscribers receive the buffer replay in order on join.
//   - LB4: subscribers receive live lines after the replay.
//   - LB5: BroadcastLogHandler.log eventually publishes via the actor.

import XCTest
import Logging
@testable import JarvisLogging

final class LogBroadcasterTests: XCTestCase {
    // LB1: publish appends to the buffer.
    func test_LB1_publishAppendsToBuffer() async {
        let bc = LogBroadcaster(bufferCapacity: 10)
        await bc.publish(
            timestamp: Date(),
            channel: "test",
            level: .info,
            message: "hello",
            metadata: [:]
        )
        let count = await bc.bufferedCount
        XCTAssertEqual(count, 1)
    }

    // LB2: buffer drops oldest when capacity is exceeded.
    func test_LB2_bufferDropsOldestAtCapacity() async {
        let bc = LogBroadcaster(bufferCapacity: 3)
        for i in 0..<5 {
            await bc.publish(
                timestamp: Date(),
                channel: "test",
                level: .info,
                message: "msg-\(i)",
                metadata: [:]
            )
        }
        let count = await bc.bufferedCount
        XCTAssertEqual(count, 3)

        // The newest 3 lines should survive. Verify by subscribing — the
        // replay yields the surviving slice in order.
        let stream = await bc.subscribe()
        let collector = Task { () -> [String] in
            var out: [String] = []
            for await line in stream {
                out.append(line.message)
                if out.count == 3 { break }
            }
            return out
        }
        let observed = await collector.value
        XCTAssertEqual(observed, ["msg-2", "msg-3", "msg-4"])
    }

    // LB3: subscribers see buffer replay on join.
    func test_LB3_subscriberReceivesReplay() async {
        let bc = LogBroadcaster(bufferCapacity: 10)
        for i in 0..<3 {
            await bc.publish(
                timestamp: Date(),
                channel: "ch",
                level: .info,
                message: "pre-\(i)",
                metadata: [:]
            )
        }
        let stream = await bc.subscribe()
        let collector = Task { () -> [String] in
            var out: [String] = []
            for await line in stream {
                out.append(line.message)
                if out.count == 3 { break }
            }
            return out
        }
        let observed = await collector.value
        XCTAssertEqual(observed, ["pre-0", "pre-1", "pre-2"])
    }

    // LB4: live lines arrive after replay.
    func test_LB4_subscriberReceivesLiveAfterReplay() async {
        let bc = LogBroadcaster(bufferCapacity: 10)
        await bc.publish(
            timestamp: Date(), channel: "ch", level: .info,
            message: "replay-1", metadata: [:]
        )
        let stream = await bc.subscribe()
        let collector = Task { () -> [String] in
            var out: [String] = []
            for await line in stream {
                out.append(line.message)
                if out.count == 3 { break }
            }
            return out
        }
        // Give the subscriber a moment to consume the replay before
        // publishing the live lines — otherwise the test is racy on
        // fast machines (publishes can land before the consumer's
        // for-await starts).
        try? await Task.sleep(nanoseconds: 10_000_000)
        await bc.publish(
            timestamp: Date(), channel: "ch", level: .info,
            message: "live-1", metadata: [:]
        )
        await bc.publish(
            timestamp: Date(), channel: "ch", level: .info,
            message: "live-2", metadata: [:]
        )
        let observed = await collector.value
        XCTAssertEqual(observed, ["replay-1", "live-1", "live-2"])
    }

    // LB5: BroadcastLogHandler.log eventually publishes via the actor.
    // Synchronous-handler → unstructured-Task path; we poll the buffer
    // count rather than racing the await.
    func test_LB5_handlerPublishesAsynchronously() async {
        // Use a private broadcaster so this test doesn't see lines from
        // any other code logging into `LogBroadcaster.shared`.
        // BroadcastLogHandler currently writes only to .shared, so we
        // assert against that instance and tolerate concurrent noise by
        // checking presence rather than exact count.
        let handler = BroadcastLogHandler(label: "lb5-test")
        let needle = "lb5-needle-\(UUID().uuidString)"
        handler.log(
            level: .notice,
            message: "\(needle)",
            metadata: nil,
            source: "test",
            file: #file,
            function: #function,
            line: #line
        )

        // Subscribe + scan for the needle within a bounded window.
        let stream = await LogBroadcaster.shared.subscribe()
        let collector = Task { () -> Bool in
            let deadline = Date().addingTimeInterval(1.0)
            for await line in stream {
                if line.message.contains(needle) { return true }
                if Date() > deadline { break }
            }
            return false
        }
        let found = await collector.value
        XCTAssertTrue(found, "BroadcastLogHandler.log did not deliver to LogBroadcaster.shared")
    }
}
