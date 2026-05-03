import XCTest
@testable import AgentCore

/// Coverage for `CacheHints.eligibleForSystemPrompt(_:ttl:)` — the gate that
/// suppresses `cache_control` markers when the system prompt is below
/// Anthropic's minimum cache breakpoint (~1024 tokens for Opus 4.7 and most
/// current models).
///
/// Closes the bug class observed in the v0.12.0 INT-3 audit (2026-05-03):
///
///   `AppDelegate.swift` set system prompt = "You are Jarvis, a personal
///   macOS assistant." (~10 tokens). `AgentOrchestrator` passed
///   `cacheHints: CacheHints(systemPromptTTL: .extended1h)` unconditionally
///   on every Anthropic call. `RequestBody.encodeCacheControl` emitted
///   `{"type":"ephemeral","ttl":"1h"}` on the first system block. Anthropic
///   responded 200 OK then EOF before any SSE frame — the documented edge
///   case for `extended-cache-ttl` + sub-1024-token prompts.
///
/// All `streamTruncatedFinal` chat submissions during the audit had this
/// shape. The fix is to refuse the cache hint entirely when the prompt is
/// too small. Once the prompt grows past the threshold (e.g. memory
/// hydration adds context), the hint resumes.
final class CacheHintsEligibilityTests: XCTestCase {

    // MARK: - Threshold (CHE-1..CHE-4)

    /// CHE-1: empty system prompt is never eligible.
    func test_emptyPromptIsIneligible() {
        XCTAssertNil(CacheHints.eligibleForSystemPrompt(""))
    }

    /// CHE-2: 10 tokens (~40 chars) is the production state today; it must
    /// NOT be eligible. This is the literal regression we're guarding.
    func test_shortProductionPromptIsIneligible() {
        let prompt = "You are Jarvis, a personal macOS assistant."
        XCTAssertNil(
            CacheHints.eligibleForSystemPrompt(prompt),
            "The 10-token default system prompt MUST NOT advertise cache_control to Anthropic — that's the streamTruncated trigger from the 2026-05-03 audit."
        )
    }

    /// CHE-3: just below the threshold is still ineligible.
    func test_promptOneCharBelowThresholdIsIneligible() {
        let prompt = String(repeating: "a", count: 4095)
        XCTAssertNil(CacheHints.eligibleForSystemPrompt(prompt))
    }

    /// CHE-4: at and above the threshold is eligible with the requested TTL.
    func test_promptAtThresholdIsEligible() {
        let prompt = String(repeating: "a", count: 4096)
        let hints = CacheHints.eligibleForSystemPrompt(prompt)
        XCTAssertNotNil(hints)
        XCTAssertEqual(hints?.systemPromptTTL, .extended1h)
    }

    func test_largePromptIsEligible() {
        let prompt = String(repeating: "x", count: 10_000)
        let hints = CacheHints.eligibleForSystemPrompt(prompt)
        XCTAssertNotNil(hints)
        XCTAssertEqual(hints?.systemPromptTTL, .extended1h)
    }

    // MARK: - TTL parameter (CHE-5)

    /// CHE-5: callers can request a different TTL; the helper preserves it.
    func test_caller_can_request_5m_ttl() {
        let prompt = String(repeating: "y", count: 4096)
        let hints = CacheHints.eligibleForSystemPrompt(prompt, ttl: .ephemeral5m)
        XCTAssertEqual(hints?.systemPromptTTL, .ephemeral5m)
    }
}
