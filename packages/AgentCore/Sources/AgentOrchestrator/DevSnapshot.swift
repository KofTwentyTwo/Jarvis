import Foundation
import AgentCore

/// Atomic state bag rendered by `DevOverlayView` (Plan 04-05, OBS-01).
///
/// Produced by `DevSnapshotEmitter` from the `OrchestratorEvent` stream and
/// shipped through a `BoundedAsyncChannel<DevSnapshot>` (capacity 32,
/// `.dropOldest` — see AGENT-10 four-seam topology). DevOverlay is
/// observational; stale snapshots are acceptable so we favour freshness over
/// completeness.
///
/// **Lives in the AgentOrchestrator target, not DevOverlay.** Rule 3
/// deviation: the plan frontmatter placed `DevSnapshot.swift` under
/// `packages/DevOverlay/Sources/DevOverlay/`, but `DevSnapshotEmitter` (Task
/// 2) consumes `OrchestratorEvent` + `DevSnapshot` and lives alongside the
/// orchestrator. Hosting `DevSnapshot` in DevOverlay would create a cycle
/// (AgentOrchestrator → DevOverlay → AgentOrchestrator). Parked here; the
/// DevOverlay package imports `AgentOrchestrator` and re-exposes the type
/// transitively.
public struct DevSnapshot: Sendable, Equatable {
    public let state: TurnState
    public let turnId: TurnID?
    public let provider: String
    public let modelId: String
    public let inputTokens: Int
    public let outputTokens: Int
    public let cacheCreationInputTokens: Int
    public let cacheReadInputTokens: Int
    public let ttfbMs: Int
    public let totalMs: Int
    public let toolCalls: [ToolCallRow]   // last 5, newest last

    public init(
        state: TurnState,
        turnId: TurnID?,
        provider: String,
        modelId: String,
        inputTokens: Int,
        outputTokens: Int,
        cacheCreationInputTokens: Int,
        cacheReadInputTokens: Int,
        ttfbMs: Int,
        totalMs: Int,
        toolCalls: [ToolCallRow]
    ) {
        self.state = state
        self.turnId = turnId
        self.provider = provider
        self.modelId = modelId
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheCreationInputTokens = cacheCreationInputTokens
        self.cacheReadInputTokens = cacheReadInputTokens
        self.ttfbMs = ttfbMs
        self.totalMs = totalMs
        self.toolCalls = toolCalls
    }

    /// `cacheReadInputTokens / (cacheReadInputTokens + cacheCreationInputTokens) * 100`
    /// — clamped to 0 when both counters are zero (cold turn, no cache activity).
    public var cacheHitPercentage: Double {
        let total = cacheReadInputTokens + cacheCreationInputTokens
        guard total > 0 else { return 0 }
        return Double(cacheReadInputTokens) / Double(total) * 100.0
    }

    public static let initial = DevSnapshot(
        state: .idle,
        turnId: nil,
        provider: "",
        modelId: "",
        inputTokens: 0,
        outputTokens: 0,
        cacheCreationInputTokens: 0,
        cacheReadInputTokens: 0,
        ttfbMs: 0,
        totalMs: 0,
        toolCalls: []
    )
}

public extension DevSnapshot {
    /// Copy-with helper for emitter updates. Any `nil` argument preserves the
    /// existing field. Keeps the emitter readable without manual mem-berwise
    /// re-init every time one field changes.
    func with(
        state: TurnState? = nil,
        turnId: TurnID? = nil,
        provider: String? = nil,
        modelId: String? = nil,
        inputTokens: Int? = nil,
        outputTokens: Int? = nil,
        cacheCreationInputTokens: Int? = nil,
        cacheReadInputTokens: Int? = nil,
        ttfbMs: Int? = nil,
        totalMs: Int? = nil,
        toolCalls: [ToolCallRow]? = nil
    ) -> DevSnapshot {
        DevSnapshot(
            state: state ?? self.state,
            turnId: turnId ?? self.turnId,
            provider: provider ?? self.provider,
            modelId: modelId ?? self.modelId,
            inputTokens: inputTokens ?? self.inputTokens,
            outputTokens: outputTokens ?? self.outputTokens,
            cacheCreationInputTokens: cacheCreationInputTokens ?? self.cacheCreationInputTokens,
            cacheReadInputTokens: cacheReadInputTokens ?? self.cacheReadInputTokens,
            ttfbMs: ttfbMs ?? self.ttfbMs,
            totalMs: totalMs ?? self.totalMs,
            toolCalls: toolCalls ?? self.toolCalls
        )
    }
}
