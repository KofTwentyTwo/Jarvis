import Foundation
import JarvisVision
import Replay
import AgentCore
import Logging
import JarvisLogging

/// Plan 09-02 / D-15 — App-target adapters that bridge production sinks to
/// FrameAttachController's nested protocols. Two thin wrappers, no business
/// logic.
///
/// **CameraCapture** (a `JarvisVision.actor`) already has a public
/// `captureFrame() async throws -> CapturedFrame` method that matches
/// `FrameAttachController.CaptureSource` shape. We supply a small adapter
/// rather than declaring conformance on `CameraCapture` itself so the
/// VISION-03 isolation gate stays on the Vision side and AppDelegate owns
/// the bridging concern.
///
/// **FrameAttachReplaySink** (the concrete `JarvisVision.actor`) accepts a
/// `ReplayLogProtocol`-conforming object — Replay's `ReplayLog` does not
/// itself conform, so we wrap it. The wrapper records the placeholder
/// payload via `ReplayEvent.userInput(payload)` against a synthetic
/// `TurnID` derived from the recording instant; the SOLE-emission-site
/// invariant for raw-byte-discard lives in
/// `packages/Vision/Sources/Vision/FrameAttachReplaySink.swift`, NOT here.
///
/// Both adapters are `Sendable` (their wrapped peers are actors / `Sendable`
/// classes); the structs themselves carry only references.

/// Wraps `CameraCapture` to satisfy `FrameAttachController.CaptureSource`.
/// One-shot capture — delegates straight through.
struct FrameAttachCaptureSourceAdapter: FrameAttachController.CaptureSource {
    let cameraCapture: CameraCapture

    func captureFrame() async throws -> CapturedFrame {
        try await cameraCapture.captureFrame()
    }
}

/// Wraps `Replay.ReplayLog` to satisfy
/// `FrameAttachReplaySink.ReplayLogProtocol`. The placeholder is logged
/// via `JarvisLogChannel.replay` rather than persisted into the SQLite
/// events table — `recordPlaceholder(_:)` does not receive a `TurnID`
/// (the placeholder is generated at confirm-send time, BEFORE the
/// orchestrator allocates the turn), and `events.turn_id` is a non-null
/// FK to `turns(turn_id)`. Emitting under a synthetic id would fail the
/// FK at flush time.
///
/// A follow-on plan will thread the upcoming TurnID through (the chat
/// handler invokes `requestAttach` BEFORE `submit`), at which point this
/// adapter can write through `replayLog.record(.userInput(payload), for:)`.
/// The privacy invariant — no raw bytes ever reach this adapter, only the
/// pre-formatted placeholder payload from
/// `FrameAttachReplaySink.placeholder(for:)` — is unaffected by the choice
/// of sink (log vs SQLite); the `FrameAttachDiscardSiteGrepTests` gate
/// guards the producer side, not the consumer.
struct FrameAttachReplaySinkAdapter: FrameAttachReplaySink.ReplayLogProtocol {
    let replayLog: ReplayLog
    private let logger = Logger(label: JarvisLogChannel.replay.rawValue)

    func recordPlaceholder(_ payload: Data) async {
        let preview = String(data: payload, encoding: .utf8) ?? "<non-utf8>"
        logger.info("frame-attach placeholder: \(preview)")
        // `replayLog` is captured for the future-plan migration documented
        // above; not used today. Avoids an "unused let" warning.
        _ = replayLog
    }
}

/// Bridge actor that conforms `FrameAttachReplaySink` (the Vision concrete
/// type) to `FrameAttachController.ReplaySink` (the controller's nested
/// protocol). The two share method shape (`recordImageTurn(text:) async`)
/// but the Vision type doesn't declare conformance — keeping the adapter
/// in the App target preserves the Vision package's public API as
/// authored.
actor FrameAttachControllerReplaySinkBridge: FrameAttachController.ReplaySink {
    private let underlying: FrameAttachReplaySink

    init(underlying: FrameAttachReplaySink) {
        self.underlying = underlying
    }

    func recordImageTurn(text: String) async {
        await underlying.recordImageTurn(text: text)
    }
}
