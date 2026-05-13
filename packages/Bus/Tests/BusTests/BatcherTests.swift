import XCTest
@testable import Bus

/// Exercises `OutboundBatcher` behaviour against a recording fake sink. All
/// timing assertions are designed to survive CI jitter — the batcher's nominal
/// window is 33ms; tests wait 250ms (≈7.5x) before asserting. The earlier
/// 80ms wait was tight enough that macOS-15 GitHub Actions runners (cold
/// build + cold WKWebView mount sharing the box) intermittently dropped
/// `test_tokenDeltaConcat` with sendCount=0 — the 33ms `Task.sleep` had not
/// yet hopped back through the batcher actor + main actor by the time the
/// test resumed. 250ms gives the scheduled drain ample time without making
/// the suite noticeably slower (the four affected tests cost ~1s total).
///
/// The fake is `@MainActor`-isolated because `BusOutbound` does not cross
/// actor boundaries by default under Swift 6 strict concurrency, and the
/// `OutboundBatcher.Sink` requirement pins `sendRaw` to `@MainActor`.
final class BatcherTests: XCTestCase {
    // MARK: - Fake sink

    @MainActor
    final class FakeBusSink: OutboundBatcher.Sink {
        var sends: [BusOutbound] = []
        var sendCount: Int { sends.count }

        func sendRaw(_ msg: BusOutbound) async throws {
            sends.append(msg)
        }
    }

    // A small drain-wait helper. The batcher window is 33ms; wait 250ms to
    // let the scheduled drain fire and propagate the main-actor hop. The
    // earlier 80ms wait was flaky on macos-15 CI runners (cold builds racing
    // a cold WKWebView mount on the same box) — see commit message + doc
    // comment above. `@MainActor` because each test is main-actor-isolated
    // and Swift 6 strict concurrency disallows sending `self` across a
    // nonisolated boundary.
    @MainActor
    private func waitForDrain() async {
        try? await Task.sleep(for: .milliseconds(250))
    }

    // MARK: - Tests

    @MainActor
    func test_audioLevelLatestWins() async {
        let sink = FakeBusSink()
        let batcher = OutboundBatcher(sink: sink)

        await batcher.postAudio(0.3)
        await batcher.postAudio(0.5)
        await batcher.postAudio(0.9)

        await waitForDrain()

        XCTAssertEqual(sink.sendCount, 1, "three posts within one window coalesce to one send")
        if case .audioLevel(let rms) = sink.sends.first {
            XCTAssertEqual(rms, 0.9, accuracy: 0.0001, "latest value wins")
        } else {
            XCTFail("expected .audioLevel, got \(String(describing: sink.sends.first))")
        }
    }

    @MainActor
    func test_tokenDeltaConcat() async {
        let sink = FakeBusSink()
        let batcher = OutboundBatcher(sink: sink)

        await batcher.postToken("foo")
        await batcher.postToken("bar")
        await batcher.postToken("baz")

        await waitForDrain()

        XCTAssertEqual(sink.sendCount, 1, "three posts within one window coalesce to one send")
        XCTAssertEqual(sink.sends.first, .tokenDelta(text: "foobarbaz"))
    }

    @MainActor
    func test_flushAndSendPreservesOrder() async throws {
        let sink = FakeBusSink()
        let batcher = OutboundBatcher(sink: sink)

        await batcher.postToken("foo")
        try await batcher.flushAndSend(.hudState(.speaking))

        // No extra wait needed — flushAndSend drains synchronously.
        XCTAssertEqual(sink.sendCount, 2)
        XCTAssertEqual(sink.sends[0], .tokenDelta(text: "foo"))
        XCTAssertEqual(sink.sends[1], .hudState(.speaking))

        // And a trailing sleep past the original deadline proves the cancelled
        // task did not wake up and emit a stale .tokenDelta.
        await waitForDrain()
        XCTAssertEqual(sink.sendCount, 2, "cancelled drain must not fabricate a stale send")
    }

    @MainActor
    func test_multipleWindows() async {
        let sink = FakeBusSink()
        let batcher = OutboundBatcher(sink: sink)

        for i in 0..<10 {
            await batcher.postAudio(Float(i) * 0.01)
            await batcher.postToken("a")
        }

        await waitForDrain()

        // Drive another window.
        for i in 0..<10 {
            await batcher.postAudio(0.5 + Float(i) * 0.01)
            await batcher.postToken("b")
        }

        await waitForDrain()

        XCTAssertEqual(sink.sendCount, 4, "two windows × (one audio + one token) = 4 sends")

        // Spot check: first audio in first window is the 10th posted value.
        if case .audioLevel(let rms) = sink.sends[0] {
            XCTAssertEqual(rms, 0.09, accuracy: 0.0001)
        } else {
            XCTFail("expected first send to be .audioLevel")
        }
        XCTAssertEqual(sink.sends[1], .tokenDelta(text: "aaaaaaaaaa"))

        if case .audioLevel(let rms) = sink.sends[2] {
            XCTAssertEqual(rms, 0.59, accuracy: 0.0001)
        } else {
            XCTFail("expected third send to be .audioLevel")
        }
        XCTAssertEqual(sink.sends[3], .tokenDelta(text: "bbbbbbbbbb"))
    }

    @MainActor
    func test_flushAndSendBypassesEmptyBuffer() async throws {
        let sink = FakeBusSink()
        let batcher = OutboundBatcher(sink: sink)

        let id = UUID(uuidString: "6ba7b810-9dad-11d1-80b4-00c04fd430c8")!
        try await batcher.flushAndSend(.turnStarted(id: id))

        XCTAssertEqual(sink.sendCount, 1, "empty-buffer flush produces only the caller's send")
        XCTAssertEqual(sink.sends.first, .turnStarted(id: id))
    }
}
