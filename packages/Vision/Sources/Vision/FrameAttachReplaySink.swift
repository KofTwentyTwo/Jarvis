import Foundation

/// Plan 07-05 / D-15 — privacy-critical replay sink for image-bearing turns.
///
/// **CARDINAL INVARIANT:** raw image bytes NEVER reach this sink. The
/// function signature `recordImageTurn(text:)` accepts only the user's
/// textual prompt — no `Data`, no `ImageBlock`. The placeholder payload
/// `{"type":"image","discarded":true,"text":"<text>"}` is what lands in
/// the replay log.
///
/// `FrameAttachDiscardSiteGrepTests` enforces structurally that no png/jpeg
/// serialization patterns appear in this file's source.
public actor FrameAttachReplaySink {

    /// Plan 07-06 (integration closer) provides the concrete `ReplayLog`-
    /// backed implementation. This plan ships a protocol so tests can
    /// inject a recorder without dragging the SQLite-backed log into the
    /// JarvisVision test target.
    public protocol ReplayLogProtocol: Sendable {
        func recordPlaceholder(_ payload: Data) async
    }

    private let replayLog: any ReplayLogProtocol

    public init(replayLog: any ReplayLogProtocol) {
        self.replayLog = replayLog
    }

    /// Record an image-bearing turn as a placeholder payload. The image
    /// bytes are NEVER passed in — the sink only learns the textual prompt.
    public func recordImageTurn(text: String) async {
        let payload = Self.placeholder(for: text)
        await replayLog.recordPlaceholder(payload)
    }

    /// Build the placeholder JSON payload. Pure function — testable in
    /// isolation. The exact byte sequence is the contract documented in
    /// `FrameAttachReplayPlaceholderTests`.
    public static func placeholder(for text: String) -> Data {
        // Escape backslashes and double-quotes only — the placeholder is
        // emitted as a flat string for byte-exact testability.
        let escaped = text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let s = "{\"type\":\"image\",\"discarded\":true,\"text\":\"\(escaped)\"}"
        return Data(s.utf8)
    }
}
