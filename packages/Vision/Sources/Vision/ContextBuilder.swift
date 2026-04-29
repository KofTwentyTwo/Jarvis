import Foundation

/// Plan 07-05 / D-13 + D-18 — pre-turn text classifier owned by the Vision
/// package.
///
/// `ContextBuilder` is the SOLE non-test caller of `EscalationPhraseDetector`
/// in the production codebase. It delegates phrase classification down to the
/// detector but does not expose the detector's API directly to consumers.
///
/// VISION-03: this struct lives in `packages/Vision`. It does NOT depend on
/// `JarvisVoice` or `JarvisAgentOrchestrator`. Its consumers are AppDelegate
/// (Plan 07-06 integration closer) and HUD button-click handlers.
public struct ContextBuilder: Sendable {
    public let config: VisionRouterConfig

    public init(config: VisionRouterConfig = .default) {
        self.config = config
    }

    /// True when the user text contains a D-13 frame-attach trigger phrase.
    public func matchesFrameAttachPhrase(_ text: String) -> Bool {
        EscalationPhraseDetector.matchesFrameAttach(text, config: config)
    }

    /// True when the user text contains a D-18 cloud opt-in phrase.
    /// **CARDINAL INVARIANT:** the only outside-of-Vision-tests caller of
    /// `EscalationPhraseDetector.matchesCloudOptIn` is this method.
    public func matchesCloudOptIn(_ text: String) -> Bool {
        EscalationPhraseDetector.matchesCloudOptIn(text, config: config)
    }
}
