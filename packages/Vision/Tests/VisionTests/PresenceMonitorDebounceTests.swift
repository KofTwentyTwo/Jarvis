import XCTest
@testable import JarvisVision

/// D-11 + RESEARCH section 9: 2s debounce + 5-min absent secondary threshold.
final class PresenceMonitorDebounceTests: XCTestCase {

    func testDebouncesShortBlips() async throws {
        let (stream, cont) = AsyncStream<PresenceFrameSample>.makeStream()
        let monitor = PresenceMonitor(frameStream: stream)
        await monitor.start()

        let t0 = Date(timeIntervalSince1970: 1_745_308_800)

        // Rapid present/absent flapping under 2s — should NOT publish anything.
        for i in 0..<5 {
            let ts = t0.addingTimeInterval(Double(i) * 0.3)
            await monitor.feedObservation(faceDetected: i % 2 == 0, at: ts)
        }

        // Now feed a sustained .present for >2s — should publish ONE event.
        await monitor.feedObservation(faceDetected: true, at: t0.addingTimeInterval(10))
        await monitor.feedObservation(faceDetected: true, at: t0.addingTimeInterval(13))

        cont.finish()

        let received = await Self.collectEvents(
            from: monitor.bus.stream,
            maxCount: 2,
            timeoutSeconds: 0.5
        )
        await monitor.cancel()

        XCTAssertEqual(received.count, 1, "Sub-2s blips must NOT publish; only the sustained transition fires.")
        if case .transition(to: .present, _, _) = received.first {} else {
            XCTFail("Expected .present transition; got \(String(describing: received.first))")
        }
    }

    func testEmitsAbsentLongTermAfter5Minutes() async throws {
        let (stream, _) = AsyncStream<PresenceFrameSample>.makeStream()
        let monitor = PresenceMonitor(frameStream: stream)
        await monitor.start()

        let t0 = Date(timeIntervalSince1970: 1_745_308_800)

        // Drive monitor into a confirmed .absent state. The transition will
        // be published with .absent(since: t0+3) — second observation's ts.
        await monitor.feedObservation(faceDetected: false, at: t0)
        await monitor.feedObservation(faceDetected: false, at: t0.addingTimeInterval(3))

        // Manually fire the long-term evaluator past 5 minutes from the
        // confirmed-absent timestamp (test seam). Must be >= since + 300s.
        await monitor.evaluateLongTerm(now: t0.addingTimeInterval(3 + 5 * 60 + 1))

        let received = await Self.collectEvents(
            from: monitor.bus.stream,
            maxCount: 4,
            timeoutSeconds: 0.5
        )
        await monitor.cancel()

        XCTAssertGreaterThanOrEqual(received.count, 2, "Expected at least .absent and .absentLongTerm")
        let states = received.map { ev -> String in
            if case .transition(let to, _, _) = ev {
                switch to {
                case .present: return "present"
                case .absent: return "absent"
                case .absentLongTerm: return "absentLongTerm"
                case .unknown: return "unknown"
                }
            }
            return "?"
        }
        XCTAssertTrue(states.contains("absent"))
        XCTAssertTrue(states.contains("absentLongTerm"))
    }

    func testPauseStopsEmissions() async throws {
        let (stream, _) = AsyncStream<PresenceFrameSample>.makeStream()
        let monitor = PresenceMonitor(frameStream: stream)
        await monitor.start()
        await monitor.pause()

        let t0 = Date()
        await monitor.feedObservation(faceDetected: true, at: t0)
        await monitor.feedObservation(faceDetected: true, at: t0.addingTimeInterval(3))

        let received = await Self.collectEvents(
            from: monitor.bus.stream,
            maxCount: 1,
            timeoutSeconds: 0.3
        )
        await monitor.cancel()

        XCTAssertTrue(received.isEmpty, "Paused monitor must publish nothing.")
    }

    /// Collect up to `maxCount` events from the bus, racing against a
    /// timeout. Returns whatever was collected before either the count or
    /// the timeout was reached. Avoids hung tests when the bus does not
    /// produce.
    private static func collectEvents(
        from stream: AsyncStream<PresenceEvent>,
        maxCount: Int,
        timeoutSeconds: Double
    ) async -> [PresenceEvent] {
        let collector = Task { () -> [PresenceEvent] in
            var out: [PresenceEvent] = []
            for await ev in stream {
                out.append(ev)
                if out.count >= maxCount { break }
            }
            return out
        }
        let timer = Task { () -> [PresenceEvent] in
            try? await Task.sleep(nanoseconds: UInt64(timeoutSeconds * 1_000_000_000))
            collector.cancel()
            return []
        }
        let result = await collector.value
        timer.cancel()
        return result
    }
}
