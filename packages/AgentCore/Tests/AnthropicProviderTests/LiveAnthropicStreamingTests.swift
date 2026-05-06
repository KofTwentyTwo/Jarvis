import XCTest
import Foundation
@testable import AnthropicProvider
@testable import AgentCore

/// Live integration test against the real Anthropic API.
///
/// Reproduces the production `streamTruncatedFinal` failure mode that surfaced
/// when running the actual app on 2026-05-05: a small system+user prompt
/// returns HTTP 200 + zero SSE frames + zero `tokenDelta` events.
///
/// Gated on `JARVIS_REAL_ANTHROPIC=1` AND `ANTHROPIC_API_KEY=sk-ant-...`
/// being set in the env. Skips otherwise so CI never tries to hit the API.
///
/// Run with:
///
///     JARVIS_REAL_ANTHROPIC=1 ANTHROPIC_API_KEY=sk-ant-... \
///       swift test --package-path packages/AgentCore \
///         --filter AnthropicProviderTests.LiveAnthropicStreamingTests
final class LiveAnthropicStreamingTests: XCTestCase {

    private func skipIfNotConfigured() throws -> String {
        let env = ProcessInfo.processInfo.environment
        guard env["JARVIS_REAL_ANTHROPIC"] == "1" else {
            throw XCTSkip("set JARVIS_REAL_ANTHROPIC=1 to enable live Anthropic integration tests")
        }
        guard let key = env["ANTHROPIC_API_KEY"], key.hasPrefix("sk-ant-") else {
            throw XCTSkip("set ANTHROPIC_API_KEY=sk-ant-... to enable live Anthropic integration tests")
        }
        return key
    }

    /// L1 — the failing test. Mirrors what AppDelegate's first turn looks like:
    /// small system prompt + small user prompt + Opus 4.7 + streaming. The bug
    /// shows up here: stream completes with zero `tokenDelta` events.
    func testL1_smallPrompt_smallSystem_streamsAtLeastOneTokenDelta() async throws {
        let apiKey = try skipIfNotConfigured()

        let provider = AnthropicProvider(apiKeyProvider: { apiKey })

        // Emulate a sub-1024-token prompt — the regime where CacheHints
        // returns nil and `cache_control` blocks are absent from the body.
        let smallSystemPrompt = "You are a helpful assistant."

        let messages: [LLMMessage] = [
            LLMMessage(role: .system, content: [.text(smallSystemPrompt)]),
            LLMMessage(role: .user, content: [.text("Reply with exactly the word: pong")])
        ]

        // Don't ask for cache (small prompt — eligibility helper would say nil).
        let cacheHints: CacheHints? = nil

        let events = provider.stream(
            messages: messages,
            tools: [],
            toolChoice: .auto,
            model: ModelID.opus47,
            maxOutputTokens: 64,
            cacheHints: cacheHints
        )

        var tokenDeltaCount = 0
        var messageStopSeen = false
        var providerErrors: [String] = []
        var stopReasons: [StopReason] = []
        var collectedText = ""

        for try await event in events {
            switch event {
            case .textDelta(let s):
                tokenDeltaCount += 1
                collectedText += s
            case .messageStop:
                messageStopSeen = true
            case .stopReason(let reason):
                stopReasons.append(reason)
            case .providerError(let err):
                providerErrors.append(String(describing: err))
            default:
                break
            }
        }

        // Diagnostic on failure
        if tokenDeltaCount == 0 {
            XCTFail("""
                L1 FAIL: zero tokenDelta events.
                  messageStopSeen=\(messageStopSeen)
                  stopReasons=\(stopReasons)
                  providerErrors=\(providerErrors)
                  collectedText='\(collectedText)'

                This is the production streamTruncatedFinal regression.
                """)
            return
        }

        XCTAssertGreaterThan(tokenDeltaCount, 0, "L1: expected at least one tokenDelta")
        XCTAssertTrue(messageStopSeen, "L1: expected messageStop")
        XCTAssertFalse(collectedText.isEmpty, "L1: expected non-empty text")
    }

    /// L3 — TDD assertion that should be the regression fence. Anthropic's
    /// `/v1/messages` returns SSE only when `"stream": true` is in the
    /// REQUEST BODY. The `Accept: text/event-stream` header alone is not
    /// sufficient; with `Accept: text/event-stream` + missing `stream` field
    /// the server returns a regular JSON response (200 OK + ~1 KB body),
    /// our SSELineReader reads zero `data:` frames, and the decoder emits
    /// `streamTruncatedFinal`. Reproduced live on 2026-05-05 against the
    /// production AppDelegate path.
    ///
    /// FAILING NOW. Will pass after RequestBody.encodeMultimodal sets
    /// `stream = true` in the encoded body.
    func testL3_requestBody_includesStreamTrue() throws {
        let messages: [LLMMessage] = [
            LLMMessage(role: .user, content: [.text("ping")])
        ]
        let body = try RequestBody.encodeMultimodal(
            messages: messages,
            images: [],
            tools: [],
            toolChoice: .auto,
            model: ModelID.opus47,
            maxOutputTokens: 16,
            cacheHints: nil
        )
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: body) as? [String: Any],
            "request body must be valid JSON object"
        )
        XCTAssertEqual(
            json["stream"] as? Bool, true,
            "L3: request body MUST include `\"stream\": true` to opt into SSE; missing field is the canonical streamTruncatedFinal cause"
        )
    }

    /// L2 — diagnostic: dump exactly what request body our code produces for
    /// the L1 prompt. No network. Useful for diff'ing against a known-good
    /// curl request once we figure out what's wrong.
    func testL2_dumpRequestBody_forSmallPrompt() throws {
        // Skip env gate for L2 — it's pure encoding.
        let messages: [LLMMessage] = [
            LLMMessage(role: .system, content: [.text("You are a helpful assistant.")]),
            LLMMessage(role: .user, content: [.text("Reply with exactly the word: pong")])
        ]
        let body = try RequestBody.encodeMultimodal(
            messages: messages,
            images: [],
            tools: [],
            toolChoice: .auto,
            model: ModelID.opus47,
            maxOutputTokens: 64,
            cacheHints: nil
        )
        let json = String(data: body, encoding: .utf8) ?? "<non-utf8>"
        // Print to stdout so we can read it from the test runner output.
        print("=== L2 request body ===")
        print(json)
        print("=== L2 end ===")
        XCTAssertTrue(json.contains("\"model\""), "body should include model field")
        XCTAssertTrue(json.contains("\"messages\""), "body should include messages field")
    }
}
