import Foundation
import AgentCore
import AgentOrchestrator

/// Connects a `BoundedAsyncChannel<DevSnapshot>` (produced by
/// `DevSnapshotEmitter`) to a `DevOverlayViewModel` (@MainActor).
///
/// **AGENT-10 compliance:** the channel itself is the bounded seam — this
/// class just pumps elements across the isolation boundary. The emitter owns
/// the capacity/policy choice (32 + .dropOldest — observational, stale is
/// fine).
///
/// Single subscriber Task; cancelled on `detach()` or deinit. The bridge
/// holds the view-model weakly so the subscriber task doesn't keep the
/// main-actor object alive beyond its natural lifetime.
@MainActor
public final class DevOverlayBridge {
    private var subscriberTask: Task<Void, Never>?
    private weak var viewModel: DevOverlayViewModel?

    public init(viewModel: DevOverlayViewModel) {
        self.viewModel = viewModel
    }

    /// Spawn the subscriber task. Safe to call repeatedly — previous task
    /// is cancelled before the new one is attached.
    ///
    /// The channel's bounded semantics live one level up in
    /// `DevSnapshotEmitter` (capacity 32, .dropOldest — AGENT-10 four-seam).
    public func attach(channel: BoundedAsyncChannel<DevSnapshot>) {
        subscriberTask?.cancel()
        let vm = viewModel
        let task = Task { @MainActor in
            for await snap in channel {
                if Task.isCancelled { break }
                vm?.apply(snap)
            }
        }
        self.subscriberTask = task
    }

    /// Cancel the subscriber. After this returns, subsequent channel sends
    /// do not reach the view-model.
    public func detach() {
        subscriberTask?.cancel()
        subscriberTask = nil
    }

    deinit {
        subscriberTask?.cancel()
    }
}
