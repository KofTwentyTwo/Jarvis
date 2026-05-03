import XCTest
@testable import AnthropicProvider

/// Coverage for `StreamOutcome.summary` — the human-readable diagnostic
/// label attached to one Anthropic streaming session. Closes the
/// observability gap from the 2026-05-03 audit:
///
///   `SSEDecoder.flushOnEOF` collapses "200 + 0 bytes" and "200 + N
///   deltas + truncation" into the same `.streamTruncated` event. The
///   user / replay log got no signal of which one happened, so chasing
///   `streamTruncatedFinal` had to fall back to manual curl
///   reproduction.
///
/// `StreamOutcome` records the per-stream counters and emits a tagged
/// summary string. The provider logs it once per session; production
/// logs now distinguish auth/cache-control rejections from mid-stream
/// network drops.
final class StreamOutcomeTests: XCTestCase {

    // MARK: - Non-2xx

    /// SO-1: HTTP error status surfaces verbatim.
    func test_non2xx_summary_carriesStatusCode() {
        let outcome = StreamOutcome(
            httpStatus: 401,
            bytesRead: 128,
            framesParsed: 0,
            messageStopSeen: false
        )
        XCTAssertTrue(outcome.summary.contains("HTTP 401"))
    }

    func test_non2xx_summary_500() {
        let outcome = StreamOutcome(
            httpStatus: 500,
            bytesRead: 0,
            framesParsed: 0,
            messageStopSeen: false
        )
        XCTAssertTrue(outcome.summary.contains("HTTP 500"))
    }

    // MARK: - 200 OK variants (the diagnostic the user actually needs)

    /// SO-2: 200 OK + zero bytes is the textbook cache_control / auth-header
    /// rejection symptom. The summary names it explicitly so it doesn't get
    /// confused with a mid-stream truncation.
    func test_200_zeroBytes_summary_namesCacheOrAuth() {
        let outcome = StreamOutcome(
            httpStatus: 200,
            bytesRead: 0,
            framesParsed: 0,
            messageStopSeen: false
        )
        let s = outcome.summary
        XCTAssertTrue(s.contains("200"))
        XCTAssertTrue(
            s.contains("0 bytes") || s.contains("zero bytes"),
            "summary should explicitly mention zero bytes: got '\(s)'"
        )
    }

    /// SO-3: 200 OK + bytes but no SSE frames parsed (malformed body).
    func test_200_bytesButNoFrames_summary_namesParserState() {
        let outcome = StreamOutcome(
            httpStatus: 200,
            bytesRead: 512,
            framesParsed: 0,
            messageStopSeen: false
        )
        XCTAssertTrue(outcome.summary.contains("200"))
        XCTAssertTrue(outcome.summary.contains("0 frames") ||
                      outcome.summary.contains("no SSE frames"))
    }

    /// SO-4: 200 OK + frames but no message_stop (genuine mid-stream drop).
    func test_200_truncatedMidStream_summary_namesEarlyEOF() {
        let outcome = StreamOutcome(
            httpStatus: 200,
            bytesRead: 4096,
            framesParsed: 12,
            messageStopSeen: false
        )
        let s = outcome.summary
        XCTAssertTrue(s.contains("200"))
        XCTAssertTrue(s.contains("12 frame"))
        XCTAssertTrue(
            s.lowercased().contains("eof") ||
            s.lowercased().contains("truncat") ||
            s.contains("before message_stop"),
            "summary should call out early EOF: got '\(s)'"
        )
    }

    /// SO-5: 200 OK complete (no truncation). Summary should say so —
    /// useful for healthy-path log validation.
    func test_200_complete_summary_says_complete() {
        let outcome = StreamOutcome(
            httpStatus: 200,
            bytesRead: 8192,
            framesParsed: 50,
            messageStopSeen: true
        )
        XCTAssertTrue(outcome.summary.contains("200"))
        XCTAssertTrue(outcome.summary.lowercased().contains("complete"))
    }

    // MARK: - Boundary

    /// SO-6: bytesRead < 0 / framesParsed < 0 should be impossible from a
    /// real session, but the struct must still be constructible (no
    /// preconditions that crash production on an off-by-one). The summary
    /// just dumps whatever it has.
    func test_negativeCounters_doNotCrash() {
        let outcome = StreamOutcome(
            httpStatus: 200,
            bytesRead: -1,
            framesParsed: -1,
            messageStopSeen: false
        )
        XCTAssertNotNil(outcome.summary)
    }
}
