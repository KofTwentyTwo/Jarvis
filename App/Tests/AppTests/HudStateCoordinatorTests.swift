import XCTest
@testable import Jarvis

@MainActor
final class HudStateCoordinatorTests: XCTestCase {
    // MARK: - Helpers

    /// Yield the MainActor several times so the three `for await` subscriber
    /// loops can drain their continuations. Swift concurrency runs these
    /// loops cooperatively on the MainActor; a handful of yields is enough.
    private func drain() async {
        for _ in 0..<8 { await Task.yield() }
    }

    private struct Fixture {
        let coord: HudStateCoordinator
        let agent: AsyncStream<AgentHudIntent>.Continuation
        let voice: AsyncStream<VoiceHudIntent>.Continuation
        let confirm: AsyncStream<ConfirmHudIntent>.Continuation
        let emitted: () -> [HudState]
    }

    @MainActor
    private final class EmitBox {
        var values: [HudState] = []
    }

    private func makeFixture() -> Fixture {
        let (agentStream, agentCont) = AsyncStream<AgentHudIntent>.makeStream()
        let (voiceStream, voiceCont) = AsyncStream<VoiceHudIntent>.makeStream()
        let (confirmStream, confirmCont) = AsyncStream<ConfirmHudIntent>.makeStream()
        let box = EmitBox()
        let coord = HudStateCoordinator(emit: { state in
            box.values.append(state)
        })
        coord.start(agent: agentStream, voice: voiceStream, confirmation: confirmStream)
        return Fixture(
            coord: coord,
            agent: agentCont,
            voice: voiceCont,
            confirm: confirmCont,
            emitted: { box.values }
        )
    }

    // MARK: - Booting gate

    func test_bootingUntilMarkReady() async {
        let f = makeFixture()
        // Initial emit on start is `.booting`.
        await drain()
        XCTAssertEqual(f.coord.currentStateForTests, .booting)
        XCTAssertEqual(f.emitted().first, .booting)

        // Intents before markReady — agent.idle, voice.silent resolve to
        // booting (not idle) because !ready.
        f.agent.yield(.idle)
        f.voice.yield(.silent)
        await drain()
        XCTAssertEqual(f.coord.currentStateForTests, .booting)

        // After markReady with lastAgent=.thinking, we promote to thinking.
        f.agent.yield(.thinking)
        await drain()
        // .thinking beats .booting at all times, so we may have already
        // transitioned before markReady.
        f.coord.markReady()
        await drain()
        XCTAssertEqual(f.coord.currentStateForTests, .thinking)
        f.coord.cancelAll()
    }

    func test_bootingEmittedOnStartBeforeReady() async {
        let f = makeFixture()
        await drain()
        XCTAssertEqual(f.emitted().first, .booting)
        f.coord.cancelAll()
    }

    // MARK: - awaitingConfirmation dominance

    func test_awaitingConfirmationBeatsSpeaking() async {
        let f = makeFixture()
        f.coord.markReady()
        f.agent.yield(.speaking)
        await drain()
        XCTAssertEqual(f.coord.currentStateForTests, .speaking)
        f.confirm.yield(.required)
        await drain()
        XCTAssertEqual(f.coord.currentStateForTests, .awaitingConfirmation)
        f.coord.cancelAll()
    }

    func test_awaitingConfirmationBeatsListening() async {
        let f = makeFixture()
        f.coord.markReady()
        f.voice.yield(.listening)
        await drain()
        XCTAssertEqual(f.coord.currentStateForTests, .listening)
        f.confirm.yield(.required)
        await drain()
        XCTAssertEqual(f.coord.currentStateForTests, .awaitingConfirmation)
        f.coord.cancelAll()
    }

    func test_awaitingConfirmationBeatsThinking() async {
        let f = makeFixture()
        f.coord.markReady()
        f.agent.yield(.thinking)
        await drain()
        XCTAssertEqual(f.coord.currentStateForTests, .thinking)
        f.confirm.yield(.required)
        await drain()
        XCTAssertEqual(f.coord.currentStateForTests, .awaitingConfirmation)
        f.coord.cancelAll()
    }

    func test_awaitingConfirmationBeatsReconfiguring() async {
        let f = makeFixture()
        f.coord.markReady()
        f.voice.yield(.reconfiguring)
        await drain()
        XCTAssertEqual(f.coord.currentStateForTests, .reconfiguring)
        f.confirm.yield(.required)
        await drain()
        XCTAssertEqual(f.coord.currentStateForTests, .awaitingConfirmation)
        f.coord.cancelAll()
    }

    // MARK: - speaking dominance

    func test_speakingBeatsListening() async {
        let f = makeFixture()
        f.coord.markReady()
        f.voice.yield(.listening)
        await drain()
        f.agent.yield(.speaking)
        await drain()
        XCTAssertEqual(f.coord.currentStateForTests, .speaking)
        f.coord.cancelAll()
    }

    func test_speakingBeatsThinking() async {
        let f = makeFixture()
        f.coord.markReady()
        f.agent.yield(.thinking)
        await drain()
        f.agent.yield(.speaking)
        await drain()
        XCTAssertEqual(f.coord.currentStateForTests, .speaking)
        f.coord.cancelAll()
    }

    func test_speakingBeatsReconfiguring() async {
        let f = makeFixture()
        f.coord.markReady()
        f.voice.yield(.reconfiguring)
        await drain()
        f.agent.yield(.speaking)
        await drain()
        XCTAssertEqual(f.coord.currentStateForTests, .speaking)
        f.coord.cancelAll()
    }

    // MARK: - listening dominance

    func test_listeningBeatsThinking() async {
        let f = makeFixture()
        f.coord.markReady()
        f.agent.yield(.thinking)
        await drain()
        f.voice.yield(.listening)
        await drain()
        XCTAssertEqual(f.coord.currentStateForTests, .listening)
        f.coord.cancelAll()
    }

    func test_listeningBeatsReconfiguring() async {
        let f = makeFixture()
        f.coord.markReady()
        f.voice.yield(.reconfiguring)
        await drain()
        f.voice.yield(.listening)
        await drain()
        XCTAssertEqual(f.coord.currentStateForTests, .listening)
        f.coord.cancelAll()
    }

    // MARK: - thinking dominance

    func test_thinkingBeatsReconfiguring() async {
        let f = makeFixture()
        f.coord.markReady()
        f.voice.yield(.reconfiguring)
        await drain()
        f.agent.yield(.thinking)
        await drain()
        XCTAssertEqual(f.coord.currentStateForTests, .thinking)
        f.coord.cancelAll()
    }

    // MARK: - reconfiguring / idle floor

    func test_reconfiguringOnlyWhenNothingHigher() async {
        let f = makeFixture()
        f.coord.markReady()
        f.voice.yield(.reconfiguring)
        await drain()
        XCTAssertEqual(f.coord.currentStateForTests, .reconfiguring)
        f.coord.cancelAll()
    }

    func test_idleWhenAllQuietAndReady() async {
        let f = makeFixture()
        f.coord.markReady()
        await drain()
        XCTAssertEqual(f.coord.currentStateForTests, .idle)
        f.coord.cancelAll()
    }

    // MARK: - Idempotent emit

    func test_idempotentEmitNoRepeat() async {
        let f = makeFixture()
        f.coord.markReady()
        await drain()
        let afterReadyCount = f.emitted().count
        // Fire several intents that resolve to the same `.idle` state.
        f.agent.yield(.idle)
        f.voice.yield(.silent)
        f.agent.yield(.idle)
        await drain()
        XCTAssertEqual(f.emitted().count, afterReadyCount,
                       "No new emits expected for same resolved state")
        f.coord.cancelAll()
    }

    func test_clearedConfirmationRestoresLowerState() async {
        let f = makeFixture()
        f.coord.markReady()
        f.agent.yield(.thinking)
        await drain()
        XCTAssertEqual(f.coord.currentStateForTests, .thinking)
        f.confirm.yield(.required)
        await drain()
        XCTAssertEqual(f.coord.currentStateForTests, .awaitingConfirmation)
        f.confirm.yield(.cleared)
        await drain()
        XCTAssertEqual(f.coord.currentStateForTests, .thinking)
        f.coord.cancelAll()
    }

    // MARK: - Stream plumbing

    func test_threeSubscriberLoopsConsumeIndependently() async {
        let f = makeFixture()
        f.coord.markReady()
        // Interleave: listening → thinking → speaking → cleared confirm.
        f.voice.yield(.listening)
        f.agent.yield(.thinking)
        f.agent.yield(.speaking)
        f.confirm.yield(.cleared)
        await drain()
        XCTAssertEqual(f.coord.currentStateForTests, .speaking)
        f.coord.cancelAll()
    }

    func test_weakSelfCaptureDoesNotLeakOnCancel() async {
        weak var witness: HudStateCoordinator?
        do {
            let (agentStream, agentCont) = AsyncStream<AgentHudIntent>.makeStream()
            let (voiceStream, voiceCont) = AsyncStream<VoiceHudIntent>.makeStream()
            let (confirmStream, confirmCont) = AsyncStream<ConfirmHudIntent>.makeStream()
            var coord: HudStateCoordinator? = HudStateCoordinator(emit: { _ in })
            coord?.start(agent: agentStream, voice: voiceStream, confirmation: confirmStream)
            witness = coord
            coord?.cancelAll()
            agentCont.finish()
            voiceCont.finish()
            confirmCont.finish()
            coord = nil
            await drain()
        }
        await drain()
        XCTAssertNil(witness, "Coordinator leaked — for-await loops should release on cancel")
    }

    func test_concurrentPubSubRespectsPrecedenceOnMainActor() async {
        let f = makeFixture()
        f.coord.markReady()
        for _ in 0..<10 {
            f.agent.yield(.thinking)
            f.voice.yield(.listening)
        }
        // Final input = listening beats thinking.
        await drain()
        XCTAssertEqual(f.coord.currentStateForTests, .listening)
        f.coord.cancelAll()
    }
}
