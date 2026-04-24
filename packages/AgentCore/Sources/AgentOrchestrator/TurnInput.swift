import Foundation
import AgentCore
import Replay

/// Input handed to `AgentOrchestrator.submit(_:)` / `cancelAndSubmit(_:)`.
///
/// `source` distinguishes text / voice / memory-extraction turns for cohort
/// slicing in the replay log. `submittedAt` is the wall-clock instant the
/// user hit send (or the wake-word fired) — useful for end-to-end latency
/// measurement in DevOverlay.
public struct TurnInput: Sendable {
    public let source: TurnSource
    public let userText: String
    public let submittedAt: Date

    public init(source: TurnSource, userText: String, submittedAt: Date = Date()) {
        self.source = source
        self.userText = userText
        self.submittedAt = submittedAt
    }
}

public extension TurnInput {
    static func text(_ s: String, at date: Date = Date()) -> TurnInput {
        TurnInput(source: .text, userText: s, submittedAt: date)
    }

    static func voice(_ s: String, at date: Date = Date()) -> TurnInput {
        TurnInput(source: .voice, userText: s, submittedAt: date)
    }
}
