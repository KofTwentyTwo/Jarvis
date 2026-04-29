import Foundation
import AgentCore
import Replay

/// Input handed to `AgentOrchestrator.submit(_:)` / `cancelAndSubmit(_:)`.
///
/// `source` distinguishes text / voice / memory-extraction turns for cohort
/// slicing in the replay log. `submittedAt` is the wall-clock instant the
/// user hit send (or the wake-word fired) — useful for end-to-end latency
/// measurement in DevOverlay.
///
/// Plan 07-05 / D-18: gains `images: [ImageBlock]` (default `[]`) so
/// `FrameAttachController` can ferry a captured frame to a vision-capable
/// provider through the existing turn-lifecycle entry point. Existing
/// initializers compile unchanged because the new parameter is defaulted.
public struct TurnInput: Sendable {
    public let source: TurnSource
    public let userText: String
    public let submittedAt: Date
    /// Plan 07-05 / D-18. Empty for text-only turns; non-empty when a
    /// frame-attach turn has been confirmed by `FrameAttachController`.
    public let images: [ImageBlock]

    public init(
        source: TurnSource,
        userText: String,
        submittedAt: Date = Date(),
        images: [ImageBlock] = []
    ) {
        self.source = source
        self.userText = userText
        self.submittedAt = submittedAt
        self.images = images
    }
}

public extension TurnInput {
    static func text(_ s: String, at date: Date = Date()) -> TurnInput {
        TurnInput(source: .text, userText: s, submittedAt: date)
    }

    static func voice(_ s: String, at date: Date = Date()) -> TurnInput {
        TurnInput(source: .voice, userText: s, submittedAt: date)
    }

    /// Plan 07-05 / D-18 factory for image-bearing turns produced by
    /// `FrameAttachController` after the user confirms `[Send]`.
    static func withImages(
        _ source: TurnSource,
        text: String,
        images: [ImageBlock],
        submittedAt: Date = Date()
    ) -> TurnInput {
        TurnInput(source: source, userText: text, submittedAt: submittedAt, images: images)
    }
}
