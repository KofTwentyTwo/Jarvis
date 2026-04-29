import Foundation

/// Plan 07-05 / D-17 + D-18 — planner-tuned router configuration.
///
/// All knobs live as named public-let fields on this struct so they are
/// reviewable and tunable in version control. The substring set and length
/// threshold are NOT magic constants buried in the router function body —
/// they're addressable here.
public struct VisionRouterConfig: Sendable, Equatable {
    /// D-17 low-confidence substring set. Case-insensitive contains-match
    /// against the assembled T1 response triggers automatic T1→T2 escalation.
    public var lowConfidenceSubstrings: Set<String>

    /// D-17 length threshold. Responses shorter than this (after trimming
    /// whitespace) are treated as low-confidence and trigger T1→T2 escalation.
    public var lowConfidenceMinChars: Int

    /// D-13 frame-attach trigger phrases. Case-insensitive word-bounded
    /// match against user text invokes `FrameAttachController.requestAttach`.
    public var frameAttachPhrases: [String]

    /// D-18 cloud opt-in phrases. The ONLY user-visible signal that flips
    /// the router to the cloud tier (T3). Phrase set is matched by
    /// `EscalationPhraseDetector.matchesCloudOptIn`.
    public var cloudOptInPhrases: [String]

    /// Plan 07-05 / Task 4 — bounded vllm-mlx /health warmup window.
    public var vllmMlxHealthTimeout: Duration

    /// Plan 07-05 / Task 6 — frame-attach confirmation default-cancel timeout.
    public var frameConfirmTimeout: Duration

    public init(
        lowConfidenceSubstrings: Set<String>,
        lowConfidenceMinChars: Int,
        frameAttachPhrases: [String],
        cloudOptInPhrases: [String],
        vllmMlxHealthTimeout: Duration,
        frameConfirmTimeout: Duration
    ) {
        self.lowConfidenceSubstrings = lowConfidenceSubstrings
        self.lowConfidenceMinChars = lowConfidenceMinChars
        self.frameAttachPhrases = frameAttachPhrases
        self.cloudOptInPhrases = cloudOptInPhrases
        self.vllmMlxHealthTimeout = vllmMlxHealthTimeout
        self.frameConfirmTimeout = frameConfirmTimeout
    }

    public static let `default` = VisionRouterConfig(
        lowConfidenceSubstrings: [
            "i'm not sure",
            "i am not sure",
            "unclear",
            "cannot determine",
            "can't determine",
            "i don't know",
            "hard to tell",
        ],
        lowConfidenceMinChars: 24,
        frameAttachPhrases: [
            "can you see this",
            "what am i looking at",
            "show this to jarvis",
            "what's on my screen",
            "what is on my screen",
        ],
        cloudOptInPhrases: [
            "send to opus",
            "use cloud",
            "use opus",
            "send to claude",
        ],
        vllmMlxHealthTimeout: .seconds(60),
        frameConfirmTimeout: .seconds(2)
    )
}
