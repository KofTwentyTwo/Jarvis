import Foundation
import AgentCore
import AgentOrchestrator
import JarvisLogging
import Logging

/// Subscribes to `AgentOrchestrator.events` and converts successful
/// `.turnEnd(stopReason: .endTurn)` events into `ExtractionJob` enqueues
/// against `MemoryExtractionOrchestrator` (D-01).
///
/// Crucially, this coordinator NEVER blocks turnEnd — `enqueue()` is
/// `.dropOldest`-backed, so it returns immediately even when the channel
/// is saturated. Refusals, max-token, and error turns are intentionally
/// skipped (RESEARCH §7: incomplete turns yield noisy facts).
public actor MemoryExtractionCoordinator {

    public typealias TurnContentLookup = @Sendable (TurnID) async -> (user: String, assistant: String)?

    private let memoryOrchestrator: MemoryExtractionOrchestrator
    private let logger: Logger
    private var subscription: Task<Void, Never>?

    public init(memoryOrchestrator: MemoryExtractionOrchestrator) {
        self.memoryOrchestrator = memoryOrchestrator
        self.logger = Logger(label: "memory.coordinator")
    }

    /// Begin draining the supplied OrchestratorEvent stream. The
    /// `turnContent` closure is called for each `.turnEnd` to fetch the
    /// user/assistant text pair (AppDelegate.installMemory in 07-06 hands
    /// it a TurnLog accessor).
    ///
    /// **S-4 generic AsyncSequence (Phase 9 Plan 1).** Originally accepted
    /// `BoundedAsyncChannel<OrchestratorEvent>` directly; the generalized
    /// signature lets the OrchestratorEventBroadcaster's
    /// `AsyncStream<OrchestratorEvent>` plug in without a typecast while
    /// preserving compile-compatibility for existing call sites that pass
    /// a BoundedAsyncChannel (which already conforms to AsyncSequence).
    public func start<S: AsyncSequence & Sendable>(
        orchestratorEvents: S,
        turnContent: @escaping TurnContentLookup
    ) where S.Element == OrchestratorEvent {
        guard subscription == nil else { return }
        subscription = Task.detached { [weak self] in
            guard let self else { return }
            do {
                for try await event in orchestratorEvents {
                    if Task.isCancelled { return }
                    guard case let .turnEnd(turnId, stop) = event else { continue }
                    // D-01: only successful turns produce facts. Refusals,
                    // max-tokens, tool-use mid-stream, and stream-truncated
                    // turns are intentionally dropped.
                    guard stop == .endTurn else { continue }
                    guard let pair = await turnContent(turnId) else {
                        await self.warnNoTurnContent(turnId: turnId)
                        continue
                    }
                    let job = ExtractionJob(
                        turnId: turnId,
                        userText: pair.user,
                        assistantText: pair.assistant
                    )
                    // .dropOldest: never blocks turnEnd.
                    await self.memoryOrchestrator.enqueue(job)
                }
            } catch {
                // Generic AsyncSequence iteration may throw; log and exit drain.
                await self.warnDrainError(error: error)
            }
        }
    }

    /// Stop draining. Subsequent events on the source channel are ignored.
    public func stop() async {
        subscription?.cancel()
        subscription = nil
    }

    private func warnNoTurnContent(turnId: TurnID) {
        logger.warning("turnContent returned nil for turnId=\(turnId.rawValue)")
    }

    private func warnDrainError(error: any Error) {
        logger.warning("orchestratorEvents drain threw: \(String(describing: error))")
    }
}
