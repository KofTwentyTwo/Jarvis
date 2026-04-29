import Foundation
import AgentCore   // TurnID
import Replay      // TurnSource

/// One unit of work the extraction orchestrator processes (RESEARCH §7).
///
/// Carries enough context to drive a single mem0 ADD/UPDATE/NOOP turn:
/// the source `turnId` (for attribution), the user/assistant text pair, and
/// a shortlist of `subjects` to pre-load active facts for (so the extractor
/// can UPDATE rather than ADD-with-duplicate).
///
/// `subjects` defaults to an empty array — the orchestrator's `process` step
/// will heuristically extract candidate subjects via FTS5 if empty (heuristic
/// lives in plan 07-03's read-path; this struct just carries the seed).
public struct ExtractionJob: Sendable, Equatable {
    public let turnId: TurnID
    public let userText: String
    public let assistantText: String
    public let subjects: [String]
    public let source: TurnSource    // always .memoryExtraction once routed — reified for downstream replay

    public init(
        turnId: TurnID,
        userText: String,
        assistantText: String,
        subjects: [String] = [],
        source: TurnSource = .memoryExtraction
    ) {
        self.turnId = turnId
        self.userText = userText
        self.assistantText = assistantText
        self.subjects = subjects
        self.source = source
    }
}
