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

    /// Plan 07-06 wiring stub for D-10 system-prompt presence enrichment.
    ///
    /// AppDelegate.installVision calls this with the `PresenceSignalBus.stream`
    /// so a future per-turn ContextBuilder consumer can inject "user is at
    /// desk" / "last seen N minutes ago" into the system prompt.
    /// 07-06's responsibility is only to ensure the call site exists; the
    /// actual presence-state -> prompt enrichment is deferred to a follow-on
    /// plan (Phase 8 hardening or a dedicated context-enrichment plan).
    ///
    /// The implementation drains the stream into a Task that records the
    /// latest event into a process-wide `Atomic<PresenceEvent?>`-shaped
    /// holder. 07-06 ships only the no-op drain — no per-turn injection
    /// occurs yet. This preserves the VISION-03 boundary: the static
    /// function has no reference to TTSEngine or AgentOrchestrator submit
    /// paths.
    public static func installPresence(_ stream: AsyncStream<PresenceEvent>) {
        Task.detached {
            for await _ in stream {
                // 07-06 deferred wiring: the consumer that injects presence
                // into the per-turn system prompt lands in a future plan.
                // For now we drain the stream so the producer side never
                // blocks; the most-recent event is dropped.
            }
        }
    }
}
