import XCTest
@testable import JarvisVision

/// Plan 07-05 / Task 5 — D-17 automatic T1→T2 escalation heuristic + D-18
/// no-auto-cloud invariant.
final class VisionRouterEscalationTests: XCTestCase {

    private let cfg = VisionRouterConfig.default

    // MARK: - Substring trigger

    func testLowConfidenceSubstringTriggersEscalation() {
        let lows = [
            "I'm not sure what that is.",
            "I am not sure honestly.",
            "Unclear from this angle.",
            "Cannot determine the contents.",
            "I can't determine the contents.",
            "I don't know what that says.",
            "Hard to tell.",
        ]
        for text in lows {
            XCTAssertTrue(
                VisionEscalationHeuristic.evaluateLowConfidence(text, config: cfg),
                "should be low-confidence: \(text)"
            )
        }
    }

    // MARK: - Length trigger

    func testShortResponseTriggersEscalation() {
        // Default lowConfidenceMinChars is 24.
        XCTAssertTrue(VisionEscalationHeuristic.evaluateLowConfidence("short", config: cfg))
        XCTAssertTrue(VisionEscalationHeuristic.evaluateLowConfidence("This is brief.", config: cfg))
        // Boundary case: 24 chars should NOT trigger (lt threshold)
        let exactly24 = String(repeating: "a", count: 24)
        XCTAssertFalse(VisionEscalationHeuristic.evaluateLowConfidence(exactly24, config: cfg))
    }

    // MARK: - Negative case

    func testHighConfidenceResponseDoesNotTrigger() {
        let confident = "This is a photo of a desktop showing a code editor with Swift source files open."
        XCTAssertFalse(VisionEscalationHeuristic.evaluateLowConfidence(confident, config: cfg))
    }

    // MARK: - Config-driven (D-17 review/tunability)

    func testHeuristicReadsFromConfigNotMagicConstants() {
        // Override the substring set to a single empty trigger; the response
        // text contains it, so the test PASSES iff the heuristic actually
        // reads from the passed-in config (rather than ignoring it for a
        // hard-coded default).
        var cfg2 = cfg
        cfg2.lowConfidenceSubstrings = ["xyzpqr"]
        cfg2.lowConfidenceMinChars = 1  // disable length trigger
        XCTAssertTrue(
            VisionEscalationHeuristic.evaluateLowConfidence("contains xyzpqr in text", config: cfg2),
            "heuristic must read substring set from config"
        )
        XCTAssertFalse(
            VisionEscalationHeuristic.evaluateLowConfidence("a long-enough response without the trigger word here", config: cfg2),
            "heuristic must not fall back to default substrings"
        )
    }

    // MARK: - VisionRouter.evaluatePostResponse legs

    func testEvaluatePostResponseUseT1ResultWhenConfident() async {
        let router = VisionRouter(
            t1Provider: NoopVisionProvider(),
            t2Provider: NoopVisionProvider(),
            t3Provider: NoopVisionProvider()
        )
        let outcome = await router.evaluatePostResponse(
            "A long, confident answer that is well above the length threshold and contains no low-confidence substrings.",
            config: cfg,
            t2Available: true
        )
        XCTAssertEqual(outcome, .useT1Result)
    }

    func testEvaluatePostResponseEscalateToT2WhenAvailable() async {
        let router = VisionRouter(
            t1Provider: NoopVisionProvider(),
            t2Provider: NoopVisionProvider(),
            t3Provider: NoopVisionProvider()
        )
        let outcome = await router.evaluatePostResponse(
            "I'm not sure honestly.",
            config: cfg,
            t2Available: true
        )
        XCTAssertEqual(outcome, .escalateToT2)
    }

    func testEvaluatePostResponseStaysOnT1WhenT2Unavailable() async {
        // CRITICAL: D-18 no-auto-cloud invariant. Low-confidence + T2 unavailable
        // must NEVER escalate to T3. Stays on T1.
        let router = VisionRouter(
            t1Provider: NoopVisionProvider(),
            t2Provider: NoopVisionProvider(),
            t3Provider: NoopVisionProvider()
        )
        let outcome = await router.evaluatePostResponse(
            "I'm not sure honestly.",
            config: cfg,
            t2Available: false
        )
        XCTAssertEqual(outcome, .useT1Result, "must NEVER auto-escalate to T3 — even when T2 unavailable")
    }
}

// MARK: - Test fakes

import AgentCore

private actor NoopVisionProvider: LLMProvider {
    nonisolated func stream(
        messages: [LLMMessage], tools: [ToolSchema], toolChoice: ToolChoice,
        model: ModelID, maxOutputTokens: Int, cacheHints: CacheHints?
    ) -> AsyncThrowingStream<LLMEvent, Error> {
        AsyncThrowingStream { $0.finish() }
    }
    nonisolated func stream(
        messages: [LLMMessage], images: [ImageBlock], tools: [ToolSchema],
        toolChoice: ToolChoice, model: ModelID, maxOutputTokens: Int, cacheHints: CacheHints?
    ) -> AsyncThrowingStream<LLMEvent, Error> {
        AsyncThrowingStream { $0.finish() }
    }
}
