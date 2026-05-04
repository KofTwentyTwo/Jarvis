import Foundation
import AgentCore
import JarvisLogging
import Logging

/// Background memory-extraction orchestrator (RESEARCH §7, D-01).
///
/// Holds a bounded channel of `ExtractionJob` and a serial detached Task
/// that drains jobs one at a time. Per RESEARCH §7 the channel uses
/// `.dropOldest` (capacity 32) so producers (turnEnd) never block; older
/// distillations are sacrificed because the underlying turn data is still
/// in the turns table.
///
/// Single-consumer invariant: only one drain Task is alive between
/// `start()` and `shutdown()`. Calling `start()` twice is a no-op (the
/// second call returns immediately).
///
/// **Test seam.** The orchestrator stores a closure for `applyOp` rather
/// than holding a `MemoryStore` directly. AppDelegate.installMemory
/// (Plan 07-06) supplies the production closure that calls
/// `await store.applyOp(op, sourceTurnId: turnId)`. Tests can supply a
/// spy without needing a real SQLite handle (vec0.dylib is env-gated in
/// 07-01, so DB-bound tests skip in CI).
public actor MemoryExtractionOrchestrator {

    public static let channelCapacity: Int = 32

    /// Closure invoked for each MemoryOp the extractor returns. Production
    /// wiring (Plan 07-06) closes over a `MemoryStore` and calls
    /// `try await store.applyOp(op, sourceTurnId: turnId)`. Errors thrown
    /// from this closure are caught and logged — never propagated to the
    /// producer.
    public typealias ApplyOp = @Sendable (MemoryOp, Int64) async throws -> Void

    /// Track-D D-3: priorFacts feed for the mem0 extractor.
    ///
    /// Pre-D-3, `process(_:)` hardcoded `priorFacts: []` — every fact got
    /// ADDed, none ever got UPDATEd, defeating mem0's whole supersede
    /// design. The closure now resolves prior active facts for each job;
    /// production passes a closure that returns `store.recentActiveFacts(
    /// limit: 50)` (capped server-side in SQL). Tests pass static `[Fact]`
    /// arrays.
    ///
    /// The job is passed in case future implementations want subject- or
    /// session-scoped shortlisting (Plan 07-03 deferred work). Today the
    /// simplest impl ignores the job and returns the recent slice.
    public typealias PriorFactsLookup = @Sendable (ExtractionJob) async throws -> [Fact]

    /// Default priorFactsLookup — empty list. Preserves pre-D-3 behavior
    /// for callers that don't need supersede semantics (most tests).
    public static let emptyPriorFactsLookup: PriorFactsLookup = { _ in [] }

    private let channel: BoundedAsyncChannel<ExtractionJob>
    private let extractor: MemoryExtractor
    private let applyOp: ApplyOp
    private let priorFactsLookup: PriorFactsLookup
    private let logger: Logger
    private var drainTask: Task<Void, Never>?

    public init(
        extractor: MemoryExtractor,
        applyOp: @escaping ApplyOp,
        priorFactsLookup: @escaping PriorFactsLookup = MemoryExtractionOrchestrator.emptyPriorFactsLookup
    ) {
        self.channel = BoundedAsyncChannel<ExtractionJob>(
            capacity: Self.channelCapacity,
            policy: .dropOldest
        )
        self.extractor = extractor
        self.applyOp = applyOp
        self.priorFactsLookup = priorFactsLookup
        self.logger = Logger(label: "memory.orchestrator")
    }

    /// Start the serial drain Task. Idempotent — calling twice is a no-op.
    public func start() {
        guard drainTask == nil else { return }
        drainTask = Task.detached { [weak self] in
            guard let self else { return }
            for await job in self.channel {
                if Task.isCancelled { return }
                await self.process(job)
            }
        }
    }

    /// Enqueue a job. Never blocks the caller — under overflow, oldest is
    /// dropped (RESEARCH §7).
    public func enqueue(_ job: ExtractionJob) async {
        await channel.send(job)
    }

    /// Cancel the drain Task and finish the channel.
    public func shutdown() async {
        drainTask?.cancel()
        drainTask = nil
        await channel.finish()
    }

    // MARK: - Job processing (serial — never parallel; 32B-model VRAM)

    private func process(_ job: ExtractionJob) async {
        // Best-effort. Errors are logged and never propagate — extraction
        // must never affect the producer's turnEnd path.
        do {
            // Track-D D-3: real prior facts so the extractor can emit UPDATE
            // ops (mem0 supersede pattern) instead of always ADDing. Lookup
            // failure degrades to empty list — extraction continues with
            // no prior context (pre-D-3 behavior) rather than dying.
            let priorFacts: [Fact]
            do {
                priorFacts = try await priorFactsLookup(job)
            } catch {
                logger.warning("priorFactsLookup failed for turnId=\(job.turnId.rawValue): \(error) — proceeding with empty priorFacts")
                priorFacts = []
            }
            let ops = try await extractor.extract(
                userText: job.userText,
                assistantText: job.assistantText,
                priorActiveFacts: priorFacts
            )
            // Stable, but currently best-effort: TurnID is a UUID-string
            // wrapper; we hash it to Int64 for the DB column. Plan 07-03's
            // search path can use the hash to correlate facts back to turns.
            let turnIdInt: Int64 = stableHash(job.turnId.rawValue)
            for op in ops {
                do {
                    try await applyOp(op, turnIdInt)
                } catch {
                    logger.error("memory applyOp failed: \(error)")
                }
            }
        } catch {
            logger.error("memory extraction failed for turnId=\(job.turnId.rawValue): \(error)")
        }
    }

    /// Stable 64-bit hash of an arbitrary string. We use FNV-1a so the
    /// hash is identical across process launches (Swift's built-in
    /// `String.hashValue` is randomized per process and can't be persisted
    /// to a SQLite column for correlation).
    private func stableHash(_ s: String) -> Int64 {
        var hash: UInt64 = 0xcbf29ce484222325
        let prime: UInt64 = 0x100000001b3
        for byte in s.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* prime
        }
        // Fold to signed Int64 — drop the sign bit so the value stays
        // positive (SQLite Int64 column indexes nicer when always positive).
        return Int64(hash & 0x7FFFFFFFFFFFFFFF)
    }
}
