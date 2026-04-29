import Foundation
import JarvisVision

/// Static facade for routing `PresenceSignalBus.stream` into the
/// `ContextBuilder` surface owned by Plan 07-05.
///
/// 07-06 calls `AppDelegateContextBuilderAdapter.attachPresence(bus.stream)`
/// from `installVision()`; the adapter forwards into
/// `ContextBuilder.installPresence(_:)` which currently drains the stream
/// as a deferred-wiring no-op (per the 07-06 SUMMARY's "Deferred wiring"
/// section). The actual per-turn system-prompt enrichment lands in a
/// follow-on plan.
///
/// VISION-03 preserved: the adapter is the ONLY caller into ContextBuilder
/// from the App target; the call passes the AsyncStream by reference. The
/// adapter has no reference to TTSEngine or AgentOrchestrator submit paths.
/// `scripts/check-presence-vision-isolation.sh` confirms.
public enum AppDelegateContextBuilderAdapter {
    public static func attachPresence(_ stream: AsyncStream<PresenceEvent>) {
        ContextBuilder.installPresence(stream)
    }
}
