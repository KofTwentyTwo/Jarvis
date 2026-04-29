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
    public func start(
        orchestratorEvents: BoundedAsyncChannel<OrchestratorEvent>,
        turnContent: @escaping TurnContentLookup
    ) {
        guard subscription == nil else { return }
        subscription = Task.detached { [weak self] in
            guard let self else { return }
            for await event in orchestratorEvents {
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
}
