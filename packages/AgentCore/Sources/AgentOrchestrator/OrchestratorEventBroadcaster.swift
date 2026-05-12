import Foundation
import AgentCore

/// Single drainer of `AgentOrchestrator.events`. Fans out each event onto N
/// child `AsyncStream<OrchestratorEvent>`s with per-consumer bounded buffers
/// and drop-oldest policy.
///
/// **D-05 / D-08:** owned for app lifetime by `AppDelegate`. The broadcaster's
/// drain Task is the only production call site that iterates
/// `orchestrator.events` (enforced by `scripts/check-orchestrator-events-single-consumer.sh`).
///
/// **D-06:** each subscriber has its own per-consumer ring buffer (default 256).
/// On overflow, the OLDEST drop-eligible event for that subscriber is removed
/// and the new event appended. Isolates a stuck consumer from blocking other
/// consumers — the broadcaster's drain never suspends on a saturated child.
///
/// **D-07:** the per-priority filter ensures memory's protected events are
/// NEVER dropped. Only `.tokenDelta` and `.thinkingDelta` are drop-eligible
/// for the memory subscriber. `.transcript` shares memory's protection rules
/// (its drop-eligible class is also `.tokenDelta` / `.thinkingDelta`).
public actor OrchestratorEventBroadcaster {
    public struct Subscription: Sendable {
        public let stream: AsyncStream<OrchestratorEvent>
        public let id: UUID
    }

    public enum Priority: Sendable {
        /// `.tokenDelta` / `.thinkingDelta` are drop-eligible. All other event
        /// classes (`.turnEnd`, `.toolCardUpdate`, `.usage`, `.error`,
        /// `.stateChange`) are protected — D-07.
        case memory
        /// All event classes are drop-eligible (lossy observational consumer).
        case devOverlay
        /// Only `.turnEnd` is protected — used by the FrameAttachReleaseSubscriber
        /// (Plan 2) so `onAssistantTurnComplete()` reliably fires.
        case frameAttach
        /// `.turnEnd` and `.error` are protected; everything else is drop-eligible.
        /// Used by Plan 4's voice subscriber.
        case voice
        /// Same protection rules as `.memory` — used by AppDelegate's
        /// transcript collector to feed `TurnTranscriptStore` from `.tokenDelta`.
        case transcript
        /// Webview-bus forwarding subscriber — drains orchestrator events
        /// out to the JS-side HUD via `OutboundBatcher` / `WebviewBridge`.
        /// `.tokenDelta` and `.thinkingDelta` are drop-eligible (the
        /// `OutboundBatcher` itself coalesces tokens at ~30 Hz, so tail-
        /// drop on extreme overload is acceptable). Everything else
        /// (`.turnEnd`, `.toolCardUpdate`, `.usage`, `.error`,
        /// `.stateChange`) is protected — those drive HUD chrome
        /// transitions that MUST reach the user.
        ///
        /// AUDIT-AND-FIX-PLAN.md / Phase E follow-up: closes
        /// BLOCKER-INT-2 (`tokenDelta` / `turnStarted` / `turnEnded` never
        /// emitted to webview) by giving AppDelegate a canonical
        /// priority to subscribe under for bus-forwarding.
        case bus
        /// HUD-state subscriber — drains `.stateChange` / `.turnEnd` to
        /// the dormant `AgentHudIntent` continuation so the HUD ring
        /// reflects agent activity (thinking / speaking / idle).
        /// `.stateChange` / `.turnEnd` are protected; all other events
        /// (tokenDelta / thinkingDelta / usage / toolCardUpdate / error)
        /// are drop-eligible — the HUD doesn't render tokens itself.
        ///
        /// (audit-2026-05-12 P1-5 / Issue #36: prior to this priority,
        /// the `dormantAgentContinuation` was constructed but never
        /// yielded into — the HUD ring stayed `.silent` during
        /// thinking and speaking.)
        case agentHud
    }

    private let upstream: BoundedAsyncChannel<OrchestratorEvent>
    private var subscribers: [Subscriber] = []
    private var drainTask: Task<Void, Never>?

    private struct Subscriber {
        let id: UUID
        let priority: Priority
        let capacity: Int
        let cont: AsyncStream<OrchestratorEvent>.Continuation
        var buffer: [OrchestratorEvent]
    }

    public init(upstream: BoundedAsyncChannel<OrchestratorEvent>) {
        self.upstream = upstream
    }

    /// Start the single drain Task. Idempotent: cancels any prior Task.
    /// (D-08: drain lives for app lifetime; only cancelled on explicit `stop()`.)
    public func start() {
        drainTask?.cancel()
        let upstream = self.upstream
        drainTask = Task { [weak self] in
            for await event in upstream {
                if Task.isCancelled { break }
                guard let self else { break }
                await self.fanOut(event)
            }
        }
    }

    /// Stop the drain Task and finish all subscriber streams.
    public func stop() {
        drainTask?.cancel()
        drainTask = nil
        for sub in subscribers { sub.cont.finish() }
        subscribers.removeAll()
    }

    public func subscribe(priority: Priority, capacity: Int = 256) -> Subscription {
        let (stream, cont) = AsyncStream<OrchestratorEvent>.makeStream(
            bufferingPolicy: .unbounded
        )
        let id = UUID()
        subscribers.append(Subscriber(
            id: id, priority: priority, capacity: capacity,
            cont: cont, buffer: []
        ))
        return Subscription(stream: stream, id: id)
    }

    /// Test seam: how many events are currently buffered for a subscriber.
    /// Used by tests verifying drop-oldest behaviour against the internal mirror.
    internal func bufferCount(for id: UUID) -> Int? {
        subscribers.first(where: { $0.id == id })?.buffer.count
    }

    private func fanOut(_ event: OrchestratorEvent) {
        for i in subscribers.indices {
            push(event, to: &subscribers[i])
        }
    }

    private func push(_ event: OrchestratorEvent, to sub: inout Subscriber) {
        // Capacity OK — append.
        if sub.buffer.count < sub.capacity {
            sub.buffer.append(event)
            sub.cont.yield(event)
            return
        }

        // Overflow path.
        let isProtected = isProtectedForPriority(event, priority: sub.priority)
        if isProtected {
            // D-07: protected events ALWAYS appended. Buffer may exceed
            // capacity; bounded by upstream's own 256-cap so worst case is
            // 256 protected events. Acceptable per D-06 ("isolates a stuck
            // consumer from blocking everyone else").
            sub.buffer.append(event)
            sub.cont.yield(event)
            return
        }

        // Drop oldest non-protected element.
        if let idx = sub.buffer.firstIndex(where: {
            !isProtectedForPriority($0, priority: sub.priority)
        }) {
            sub.buffer.remove(at: idx)
            sub.buffer.append(event)
            sub.cont.yield(event)
        }
        // else: buffer fully protected; drop the new non-protected event silently.
    }

    /// Returns true iff `event` MUST be delivered to a consumer of `priority`
    /// even when its buffer is at capacity. False ⇒ event is drop-eligible.
    internal func isProtectedForPriority(
        _ event: OrchestratorEvent,
        priority: Priority
    ) -> Bool {
        switch priority {
        case .memory, .transcript, .bus:
            // D-07 / Phase E (BLOCKER-INT-2): only .tokenDelta /
            // .thinkingDelta are drop-eligible. Bus forwarder shares
            // the rule — OutboundBatcher coalesces tokens at ~30 Hz,
            // so tail-dropping individual deltas under extreme overload
            // is preferable to back-pressuring the orchestrator.
            switch event {
            case .tokenDelta, .thinkingDelta: return false
            default: return true
            }
        case .devOverlay:
            return false  // all events lossy
        case .frameAttach:
            if case .turnEnd = event { return true }
            return false
        case .voice:
            switch event {
            case .turnEnd, .error: return true
            default: return false
            }
        case .agentHud:
            // HUD-state subscriber — protect lifecycle events; tokens,
            // thinking-text and tool cards aren't needed for ring
            // transitions and can drop under overload.
            switch event {
            case .stateChange, .turnEnd, .error: return true
            default: return false
            }
        }
    }
}
