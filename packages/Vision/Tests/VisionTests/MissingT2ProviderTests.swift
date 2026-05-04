import XCTest
@testable import JarvisVision
import AgentCore

/// Track-C 4 — `MissingT2Provider` replaces the silent `t2Provider: t1`
/// fallback that vision-audit §3 flagged as "decorative tier ladder".
/// These tests assert:
///   1. The provider's stream finishes with `VisionError.t2ProviderUnavailable`
///      (text + multimodal entry points).
///   2. `VisionRouter.evaluatePostResponse(..., t2Available: false)` still
///      returns `.useT1Result` — production code paths never actually hit
///      the provider's stream when wired correctly.
///   3. AppDelegate.swift no longer carries the silent-fallback comment.
final class MissingT2ProviderTests: XCTestCase {

    func testStreamFinishesWithExplicitError() async throws {
        let provider = MissingT2Provider()
        let stream = provider.stream(
            messages: [LLMMessage(role: .user, content: [.text("hello")])],
            tools: [],
            toolChoice: .auto,
            model: ModelID(rawValue: "irrelevant"),
            maxOutputTokens: 100,
            cacheHints: nil
        )
        do {
            for try await _ in stream {
                XCTFail("MissingT2Provider should not yield any events")
            }
            XCTFail("MissingT2Provider must throw t2ProviderUnavailable")
        } catch VisionError.t2ProviderUnavailable {
            // Pass — explicit, surfaced.
        } catch {
            XCTFail("Wrong error: \(error)")
        }
    }

    func testMultimodalStreamFinishesWithExplicitError() async throws {
        let provider = MissingT2Provider()
        let image = ImageBlock(mediaType: "image/jpeg", data: Data([0xFF, 0xD8, 0xFF]))
        let stream = provider.stream(
            messages: [LLMMessage(role: .user, content: [.text("what is this")])],
            images: [image],
            tools: [],
            toolChoice: .auto,
            model: ModelID(rawValue: "irrelevant"),
            maxOutputTokens: 100,
            cacheHints: nil
        )
        do {
            for try await _ in stream {
                XCTFail("MissingT2Provider should not yield any events")
            }
            XCTFail("MissingT2Provider must throw t2ProviderUnavailable")
        } catch VisionError.t2ProviderUnavailable {
            // Pass.
        } catch {
            XCTFail("Wrong error: \(error)")
        }
    }

    /// Production callers gate T2 on `t2Available: false`, which still
    /// returns `.useT1Result` — so MissingT2Provider's stream is never
    /// actually invoked in the live flow. This test re-asserts the
    /// router's existing invariant from VisionRouterEscalationTests.
    func testRouterStillStaysOnT1WhenT2Unavailable() async throws {
        let router = VisionRouter(
            t1Provider: MissingT2Provider(),  // doesn't matter for this branch
            t2Provider: MissingT2Provider(),
            t3Provider: MissingT2Provider()
        )
        let outcome = await router.evaluatePostResponse(
            "I'm not sure",
            config: VisionRouterConfig.default,
            t2Available: false
        )
        XCTAssertEqual(outcome, .useT1Result)
    }

    /// AppDelegate must not silently carry `t2Provider: t1` anymore.
    func testAppDelegateNoLongerCarriesSilentT1Fallback() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()    // Tests/VisionTests
            .deletingLastPathComponent()    // Tests
            .deletingLastPathComponent()    // packages/Vision
            .deletingLastPathComponent()    // packages
            .deletingLastPathComponent()    // repo root
            .appendingPathComponent("App/AppDelegate.swift")
        let src = try String(contentsOf: url, encoding: .utf8)
        XCTAssertFalse(
            src.contains("t2Provider: t1,"),
            "AppDelegate must not silently fall back to T1 for T2 — Track-C 4 replaced this with MissingT2Provider()"
        )
        XCTAssertTrue(
            src.contains("MissingT2Provider()"),
            "AppDelegate must wire MissingT2Provider() into the VisionRouter T2 slot"
        )
    }
}
