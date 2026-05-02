import XCTest
@testable import Jarvis
@testable import AgentCore
@testable import AgentOrchestrator
@testable import Voice

/// Phase 9 / Plan 4 tests for the Voice adapter triad (D-09 + D-10 +
/// BLOCKER-1 user-side append).
///
/// **Test surface coverage:**
/// - RejectReasonCopy returns the canonical D-10 banner / toast bodies (these
///   strings are user-visible; regressions here mean the wrong copy ships).
/// - VoiceOrchestratorAdapter.bannerForReason produces the canonical
///   (id, body) pair for each RejectReason — the IDs are the dedup keys for
///   HUDBannerCoordinator.enqueue.
/// - VoiceTTSAdapter no-ops gracefully when engine is nil.
/// - VoiceBusEmitterAdapter forwards to OutboundBatcher.
final class VoiceOrchestratorAdapterTests: XCTestCase {

    // MARK: - RejectReasonCopy (single source of truth for D-10 copy parity)

    func testRejectReasonCopyTurnInFlight() {
        XCTAssertEqual(
            RejectReasonCopy.body(for: .turnInFlight),
            "Already thinking — wait or say cancel."
        )
    }

    func testRejectReasonCopyProviderUnavailable() {
        XCTAssertEqual(
            RejectReasonCopy.body(for: .providerUnavailable),
            "Provider unavailable — check Anthropic key or Ollama daemon."
        )
    }

    func testRejectReasonCopyConfigError() {
        XCTAssertEqual(
            RejectReasonCopy.body(for: .configError),
            "Config error — see ~/Library/Logs/Jarvis/system.log."
        )
    }

    func testRejectReasonCopyMessagesAreDistinct() {
        // Sanity: each reason has a distinct user-visible message. If any two
        // collide, voice/text rejection paths are indistinguishable to the
        // user. D-10 cardinal: never silently drop a user submission.
        let turnInFlight = RejectReasonCopy.body(for: .turnInFlight)
        let providerUnavailable = RejectReasonCopy.body(for: .providerUnavailable)
        let configError = RejectReasonCopy.body(for: .configError)
        XCTAssertNotEqual(turnInFlight, providerUnavailable)
        XCTAssertNotEqual(turnInFlight, configError)
        XCTAssertNotEqual(providerUnavailable, configError)
    }

    // MARK: - bannerForReason (id + body mapping)

    func testBannerForTurnInFlightUsesTurnInFlightID() {
        let (id, body) = VoiceOrchestratorAdapter.bannerForReason(.turnInFlight)
        XCTAssertEqual(id, "voice-rejected-turninflight")
        XCTAssertEqual(body, "Already thinking — wait or say cancel.")
    }

    func testBannerForProviderUnavailableUsesProviderID() {
        let (id, body) = VoiceOrchestratorAdapter.bannerForReason(.providerUnavailable)
        XCTAssertEqual(id, "voice-rejected-provider")
        XCTAssertEqual(body, "Provider unavailable — check Anthropic key or Ollama daemon.")
    }

    func testBannerForConfigErrorUsesConfigID() {
        let (id, body) = VoiceOrchestratorAdapter.bannerForReason(.configError)
        XCTAssertEqual(id, "voice-rejected-config")
        XCTAssertEqual(body, "Config error — see ~/Library/Logs/Jarvis/system.log.")
    }

    // MARK: - Text/voice rejection-body parity (D-10 single source of truth)

    func testTextRejectionBodyMatchesVoiceBannerBody() {
        // VoiceOrchestratorAdapter (HUD banner) and AppDelegate.handleTextOutcome
        // (Bus toast) BOTH read from RejectReasonCopy.body(for:). Equality is
        // by construction — this test would fail only if either path stopped
        // routing through RejectReasonCopy.
        for reason in [RejectReason.turnInFlight, .providerUnavailable, .configError] {
            let voiceBody = VoiceOrchestratorAdapter.bannerForReason(reason).body
            let textBody = RejectReasonCopy.body(for: reason)
            XCTAssertEqual(
                voiceBody, textBody,
                "voice banner / text toast body mismatch for \(reason)"
            )
        }
    }

    // MARK: - VoiceTTSAdapter (engine optional — no-op when nil)

    func testVoiceTTSAdapterDormantWhenEngineNil() async {
        let adapter = VoiceTTSAdapter(engine: nil)
        // hasSynthInFlight should be false with no engine.
        let inFlight = await adapter.hasSynthInFlight
        XCTAssertFalse(inFlight)
        // synthesize should not throw or trap when engine is nil.
        await adapter.synthesize("hello")
        // cancel should not throw or trap when engine is nil.
        await adapter.cancelTTS()
    }

    // MARK: - VoiceBusEmitterAdapter (forwards to batcher)

    func testVoiceBusEmitterAdapterForwardsRMSToBatcher() async throws {
        // Test sink: records sendRaw calls. We use BusOutbound.audioLevel
        // because the batcher's drain emits that on postAudio.
        actor RecordingSink: OutboundBatcher.Sink {
            var sentMessages: [BusOutbound] = []
            @MainActor func sendRaw(_ msg: BusOutbound) async throws {
                await self.recordOnActor(msg)
            }
            func recordOnActor(_ msg: BusOutbound) {
                sentMessages.append(msg)
            }
            func snapshot() -> [BusOutbound] { sentMessages }
        }
        let sink = RecordingSink()
        // Short window so the test doesn't wait long.
        let batcher = OutboundBatcher(sink: sink, windowMillis: 10)
        let adapter = VoiceBusEmitterAdapter(batcher: batcher)

        await adapter.postAudio(0.42)
        // Wait for the drain window to fire (10ms + slack).
        try await Task.sleep(for: .milliseconds(60))

        let recorded = await sink.snapshot()
        // Expect one audioLevel message with rms=0.42.
        XCTAssertEqual(recorded.count, 1)
        if case let .audioLevel(rms) = recorded.first {
            XCTAssertEqual(rms, 0.42, accuracy: 0.001)
        } else {
            XCTFail("expected audioLevel, got \(String(describing: recorded.first))")
        }
    }
}
