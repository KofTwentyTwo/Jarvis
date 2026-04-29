import XCTest
import Foundation
@testable import JarvisVision
import AgentCore

/// Plan 07-05 / Task 5 — VisionRouter deterministic tier ladder.
///
/// Three legs:
///   1. explicitCloudOptIn=true → T3 (claude-opus-4-7 via AnthropicProvider).
///   2. otherwise → T1 (gemma4:31b via Ollama) by default.
///   3. T2 escalation only via `evaluatePostResponse(...)`, never from `route(...)`.
final class VisionRouterTierLadderTests: XCTestCase {

    func testRouteToT1ByDefault() async throws {
        let router = VisionRouter(
            t1Provider: NoopProvider(),
            t2Provider: NoopProvider(),
            t3Provider: NoopProvider()
        )
        let img = ImageBlock(mediaType: "image/jpeg", data: Data([0xFF, 0xD8]))
        let decision = await router.route(for: img, prompt: "what is this", explicitCloudOptIn: false)
        XCTAssertEqual(decision.tier, .t1Local)
        XCTAssertEqual(decision.modelID, VisionTier.t1Local.defaultModelID)
    }

    func testRouteToT3OnExplicitOptIn() async throws {
        let router = VisionRouter(
            t1Provider: NoopProvider(),
            t2Provider: NoopProvider(),
            t3Provider: NoopProvider()
        )
        let img = ImageBlock(mediaType: "image/jpeg", data: Data([0xFF, 0xD8]))
        let decision = await router.route(for: img, prompt: "send to opus", explicitCloudOptIn: true)
        XCTAssertEqual(decision.tier, .t3Cloud)
        XCTAssertEqual(decision.modelID, VisionTier.t3Cloud.defaultModelID)
        XCTAssertEqual(decision.modelID.rawValue, "claude-opus-4-7")
    }

    func testRouteNeverReturnsT2Directly() async throws {
        // T2 is only reachable via evaluatePostResponse, not the initial route.
        let router = VisionRouter(
            t1Provider: NoopProvider(),
            t2Provider: NoopProvider(),
            t3Provider: NoopProvider()
        )
        let img = ImageBlock(mediaType: "image/jpeg", data: Data([0xFF, 0xD8]))
        for prompt in ["regular", "describe this", "send to opus", "use cloud"] {
            let d1 = await router.route(for: img, prompt: prompt, explicitCloudOptIn: false)
            XCTAssertNotEqual(d1.tier, .t2LocalQuality, "route() must never return T2 directly")
        }
    }

    func testTierDefaultModelIDs() {
        XCTAssertEqual(VisionTier.t1Local.defaultModelID.rawValue, "gemma4:31b")
        XCTAssertEqual(VisionTier.t2LocalQuality.defaultModelID.rawValue, "Qwen/Qwen3.5-35B-A3B-VL")
        XCTAssertEqual(VisionTier.t3Cloud.defaultModelID.rawValue, "claude-opus-4-7")
    }
}

// MARK: - Test fakes

private actor NoopProvider: LLMProvider {
    nonisolated func stream(
        messages: [LLMMessage],
        tools: [ToolSchema],
        toolChoice: ToolChoice,
        model: ModelID,
        maxOutputTokens: Int,
        cacheHints: CacheHints?
    ) -> AsyncThrowingStream<LLMEvent, Error> {
        AsyncThrowingStream { $0.finish() }
    }

    nonisolated func stream(
        messages: [LLMMessage],
        images: [ImageBlock],
        tools: [ToolSchema],
        toolChoice: ToolChoice,
        model: ModelID,
        maxOutputTokens: Int,
        cacheHints: CacheHints?
    ) -> AsyncThrowingStream<LLMEvent, Error> {
        AsyncThrowingStream { $0.finish() }
    }
}
