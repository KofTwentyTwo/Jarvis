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

    // MARK: - Phase 10 / Plan 10-02 — Self-aware preamble cache invariance
    //
    // Threat T-10-CACHE-01: introducing the self-aware preamble must NOT push
    // the system prompt over the 4096-char cache-eligibility boundary
    // unintentionally (RESEARCH Pitfall #4 / Assumption A4 / PATTERNS AP-04).
    //
    // The preamble is also locked per D-13 (single Swift string constant) and
    // D-14 (no Markdown tool catalog block — the Anthropic API tools array is
    // the catalog).

    /// preambleDoesNotEnableCacheUnintentionally — VALIDATION map row
    /// SELF-06 / T-10-CACHE-01.
    ///
    /// Asserts:
    /// 1. selfAwarePreamble length stays well below 2048 chars (head-room
    ///    against the 4096-char cache boundary so combined with rare
    ///    presence/memory enrichments it stays under 4 KB).
    /// 2. selfAwarePreamble starts with the prefix "You are Jarvis"
    ///    (D-13 lock anchor).
    /// 3. selfAwarePreamble does not contain a Markdown triple-backtick code
    ///    fence (D-14 — no tool catalog enumeration as block).
    /// 4. CacheHints.eligibleForSystemPrompt verdict for the prior literal
    ///    equals the verdict for the new preamble — i.e., the preamble does
    ///    not unintentionally flip cache-marker emission compared to the
    ///    prior tiny literal.
    /// 5. ContextBuilder.systemPrompt(for: .empty) returns a string starting
    ///    with the selfAwarePreamble (preamble FIRST, per D-12).
    func test_preambleDoesNotEnableCacheUnintentionally() {
        let preamble = ContextBuilder.selfAwarePreamble

        // (1) Head-room against the cache boundary.
        XCTAssertLessThan(
            preamble.count,
            2048,
            "selfAwarePreamble must stay well below the 4096-char cache boundary; combined with presence/memory enrichments it must stay < 4 KB (Pitfall #4 / A4)."
        )

        // (2) D-13 lock anchor.
        XCTAssertTrue(
            preamble.hasPrefix("You are Jarvis"),
            "selfAwarePreamble must begin with 'You are Jarvis' (D-13 locked identity)."
        )

        // (3) D-14 no Markdown tool-catalog block.
        XCTAssertFalse(
            preamble.contains("```"),
            "selfAwarePreamble must not contain a Markdown triple-backtick (D-14 — Anthropic tools array is the catalog)."
        )

        // (4) Cache-eligibility verdict invariance vs. prior literal.
        let priorLiteral = "You are Jarvis, a personal macOS assistant."
        let priorVerdict = CacheHints.eligibleForSystemPrompt(priorLiteral)
        let preambleVerdict = CacheHints.eligibleForSystemPrompt(preamble)
        XCTAssertEqual(
            priorVerdict == nil,
            preambleVerdict == nil,
            "Preamble must not flip cache-marker emission relative to the prior 10-token literal (T-10-CACHE-01)."
        )

        // (5) Composer order: preamble FIRST (D-12).
        let composed = ContextBuilder.systemPrompt(for: .empty)
        XCTAssertTrue(
            composed.hasPrefix(preamble),
            "ContextBuilder.systemPrompt(for: .empty) must start with selfAwarePreamble (D-12 — preamble FIRST, then per-turn enrichments)."
        )
    }
}
