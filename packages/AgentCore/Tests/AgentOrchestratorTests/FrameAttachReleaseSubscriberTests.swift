import XCTest
import AgentCore
import Config
import Replay
import JarvisVision
@testable import AgentOrchestrator

/// Plan 09-02 / D-16 — proves the broadcaster's `.frameAttach` subscriber
/// fires `onAssistantTurnComplete()` (modeled here as a bumping counter)
/// for image-bearing turns, and does NOT for text-only turns. The actual
/// AppDelegate wiring uses `FrameAttachController.onAssistantTurnComplete`;
/// here we surrogate it with an actor counter so the test can run inside the
/// AgentCore package without dragging the whole App target.
@MainActor
final class FrameAttachReleaseSubscriberTests: XCTestCase {

    var tempHome: TempReplayHome!

    override func setUp() async throws {
        try await super.setUp()
        tempHome = TempReplayHome.make()
    }

    override func tearDown() async throws {
        tempHome?.cleanup()
        try await super.tearDown()
    }

    private static let fakeImage = ImageBlock(
        mediaType: "image/jpeg",
        data: Data([0xFF, 0xD8, 0xFF])
    )

    /// Run a real AgentOrchestrator + real OrchestratorEventBroadcaster +
    /// a surrogate "frameAttachController" (the `ReleaseCounter` actor).
    /// Submit a turn; assert the counter increments iff the turn carried
    /// an image AND `turnHadImage(turnId)` returns true.
    private func runReleaseTrial(images: [ImageBlock]) async throws -> Int {
        let mock = MockLLMProvider(script: .init(events: [
            .messageStart(LLMMessageStart(messageId: "m", model: "x", usagePrefix: nil)),
            // Confidence text — long enough to skip post-response escalation.
            .textDelta("This is a long enough response to clear the heuristic."),
            .stopReason(.endTurn),
            .messageStop,
        ]))
        let replay = try ReplayLog(databaseURL: tempHome.dbURL)
        let session = try await replay.beginSession(appVersion: "test", buildSHA: "deadbeef")
        let router = VisionRouter(t1Provider: mock, t2Provider: mock, t3Provider: mock)
        let orch = AgentOrchestrator(
            configStore: makeConfigStore(),
            providerFactory: { _ in mock },
            toolDispatcher: StubToolDispatcher(),
            replayLog: replay,
            sessionId: session,
            systemPrompt: "you are jarvis",
            availableTools: [],
            visionRouter: router
        )

        let broadcaster = OrchestratorEventBroadcaster(upstream: orch.events)
        await broadcaster.start()
        defer { Task { await broadcaster.stop() } }

        let frameSub = await broadcaster.subscribe(priority: .frameAttach, capacity: 32)
        let counter = ReleaseCounter()

        // Drain the broadcaster's frame-attach subscription mirroring
        // AppDelegate's installAgent step 5d. Bump the counter when an
        // image-bearing turn ends.
        let drain = Task {
            for await event in frameSub.stream {
                if case let .turnEnd(turnId, _) = event {
                    let hadImage = await orch.turnHadImage(turnId)
                    if hadImage {
                        await counter.bump()
                    }
                }
            }
        }
        defer { drain.cancel() }

        // Build the input — image-bearing iff `images` is non-empty.
        let input: TurnInput = images.isEmpty
            ? .text("hello")
            : TurnInput.withImages(.text, text: "describe", images: images)

        // Subscribe a SECOND broadcaster channel (devOverlay priority) so
        // the test can wait for .turnEnd without competing with the
        // broadcaster's drain (single-consumer invariant on orch.events
        // means we MUST go through the broadcaster, not iterate orch.events
        // directly).
        let waitSub = await broadcaster.subscribe(priority: .devOverlay, capacity: 32)

        guard case .ran = await orch.submit(input) else {
            XCTFail("expected .ran outcome")
            return -1
        }

        // Wait for the trailing `.turnEnd` to land on the devOverlay
        // subscriber. The broadcaster's fan-out is synchronous per event,
        // so by the time waitSub sees .turnEnd, the frame-attach subscriber
        // has already processed the same .turnEnd in the previous fan-out
        // iteration.
        for await event in waitSub.stream {
            if case .turnEnd = event { break }
        }

        // Give the frameSub drain Task one tick to actor-hop and bump the
        // counter (the AsyncStream yield is synchronous but counter.bump()
        // is an actor call).
        try? await Task.sleep(nanoseconds: 100_000_000)

        return await counter.value
    }

    func testReleaseSubscriberFiresForImageBearingTurn() async throws {
        let count = try await runReleaseTrial(images: [Self.fakeImage])
        XCTAssertEqual(count, 1, "frame-attach release should fire exactly once for image-bearing turn")
    }

    func testReleaseSubscriberDoesNotFireForTextOnlyTurn() async throws {
        let count = try await runReleaseTrial(images: [])
        XCTAssertEqual(count, 0, "frame-attach release must NOT fire for text-only turn")
    }
}

/// Surrogate for `FrameAttachController.onAssistantTurnComplete()`.
/// Counts how many times release was triggered.
private actor ReleaseCounter {
    private(set) var value: Int = 0
    func bump() { value += 1 }
}
