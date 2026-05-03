import Foundation

/// One Anthropic streaming session's bookkeeping. Constructed by the
/// provider as bytes flow through the SSE reader; finalized when the
/// stream ends (cleanly or otherwise) and emitted via `Logger.info` so
/// production logs distinguish:
///
/// - Non-2xx status → standard HTTP error (caller already handles)
/// - 200 OK + 0 bytes → cache_control / auth-header rejection class
///   (the 2026-05-03 audit symptom — Anthropic accepts the request,
///   then immediately closes when an `extended-cache-ttl` marker is
///   attached to a sub-1024-token system prompt)
/// - 200 OK + bytes + 0 frames → malformed response body (parser
///   couldn't find an SSE frame)
/// - 200 OK + frames + no message_stop → genuine mid-stream
///   truncation (network drop, server timeout)
/// - 200 OK complete → healthy turn
///
/// The classifier is pure (no I/O, no logging) so tests can drive it
/// with arbitrary counter combinations. The provider does the actual
/// counting in its read loop and the logging in its finalizer.
public struct StreamOutcome: Sendable, Equatable {
    public let httpStatus: Int
    public let bytesRead: Int
    public let framesParsed: Int
    public let messageStopSeen: Bool

    public init(
        httpStatus: Int,
        bytesRead: Int,
        framesParsed: Int,
        messageStopSeen: Bool
    ) {
        self.httpStatus = httpStatus
        self.bytesRead = bytesRead
        self.framesParsed = framesParsed
        self.messageStopSeen = messageStopSeen
    }

    /// Tagged human-readable diagnostic. Production callers log this once
    /// per stream session at `info` level. Format is intentionally simple
    /// (no JSON, no key=value soup) — the orchestrator's replay log + the
    /// per-channel system.log are the structured store; this string is for
    /// fast eyeballing during incident triage.
    public var summary: String {
        if !(200..<300).contains(httpStatus) {
            return "HTTP \(httpStatus)"
        }
        if bytesRead == 0 {
            return "200 OK + 0 bytes — probable cache_control rejection or auth/header issue"
        }
        if framesParsed == 0 {
            return "200 OK + \(bytesRead) bytes but 0 frames parsed — malformed SSE body"
        }
        if !messageStopSeen {
            return "200 OK + \(framesParsed) frame(s), EOF before message_stop — mid-stream truncation"
        }
        return "200 OK complete (\(framesParsed) frame(s), \(bytesRead) byte(s))"
    }
}
