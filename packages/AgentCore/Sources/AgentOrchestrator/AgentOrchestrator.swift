import Foundation
import AgentCore
import Config
import Replay
import JarvisLogging
import Logging

/// Heart of Phase 4 — the turn-lifecycle actor.
///
/// **Entry points (AGENT-06):**
/// - `submit(_:)` — start a fresh turn; rejected with `.turnInFlight` if busy.
/// - `cancelAndSubmit(_:)` — barge-in primitive; cancels the in-flight turn,
///   awaits its task to drain (no actor-reentrancy race), then starts a new
///   turn returning `.superseded(priorId:reason:)`.
///
/// **Per-turn lifecycle:**
/// 1. Allocate `TurnID` + `TurnNonce` (SEC-06).
/// 2. Read `PerTurnSnapshot`; resolve provider via injected factory.
/// 3. `ReplayLog.startTurn(turnNonce:)` — nonce persisted, never on the bus.
/// 4. Spawn turn `Task` running `runTurnLoop`; assign to `currentTurn`.
/// 5. Loop streams `LLMEvent`s, dispatches tool uses through
///    `ToolDispatcher`, packs results (8 KB cap → model; full → replay).
/// 6. On budget exhaustion → cap-recovery (`toolChoice: .none`, AGENT-07).
/// 7. On `streamTruncated` → 1-shot retry (AGENT-09); 2nd is terminal.
/// 8. On any terminal stop reason → `endTurn` + `.stateChange(.idle)`.
///
/// **SEC-06:** `turnNonce` never appears in any `OrchestratorEvent`. Only
/// the model-facing prompt and the replay log row see it.
public actor AgentOrchestrator {
    // MARK: - Injected dependencies

    private let configStore: ConfigStore
    private let providerFactory: @Sendable (ProviderSelection) async throws -> any LLMProvider
    private let toolDispatcher: any ToolDispatcher
    private let replayLog: ReplayLog
    private let sessionId: SessionID
    private let systemPrompt: String
    private let availableToolsList: [ToolSchema]
    private let logger: Logger

    // MARK: - Outbound channel

    /// Bounded suspend-policy channel. Capacity 256 should comfortably hold a
    /// single turn's events (typical turns emit O(100) events). Plan 04-05's
    /// DevOverlay drains this channel.
    ///
    /// `nonisolated` because the channel is itself an actor — callers can
    /// `for await event in orch.events` without entering the orchestrator's
    /// isolation domain. Same idiom Plan 04-03's `ReplayLog` uses for log
    /// channels.
    public nonisolated let events: BoundedAsyncChannel<OrchestratorEvent>

    // MARK: - Actor-protected turn state

    private var currentTurn: TurnExecution?

    // MARK: - Init

    public init(
        configStore: ConfigStore,
        providerFactory: @escaping @Sendable (ProviderSelection) async throws -> any LLMProvider,
        toolDispatcher: any ToolDispatcher,
        replayLog: ReplayLog,
        sessionId: SessionID,
        systemPrompt: String,
        availableTools: [ToolSchema] = []
    ) {
        self.configStore = configStore
        self.providerFactory = providerFactory
        self.toolDispatcher = toolDispatcher
        self.replayLog = replayLog
        self.sessionId = sessionId
        self.systemPrompt = systemPrompt
        self.availableToolsList = availableTools
        self.logger = Logger(label: JarvisLogChannel.agent.rawValue)
        self.events = BoundedAsyncChannel<OrchestratorEvent>(capacity: 256, policy: .suspend)
    }

    // MARK: - Public entry points (AGENT-06)

    public func submit(_ input: TurnInput) async -> SubmitOutcome {
        if currentTurn != nil {
            return .rejected(reason: .turnInFlight)
        }
        return await runTurn(input: input, retryOf: nil, supersededPrior: nil)
    }

    public func cancelAndSubmit(_ input: TurnInput) async -> SubmitOutcome {
        let priorId = currentTurn?.id
        let priorTask = currentTurn?.task

        // CRITICAL (AGENT-06 actor-reentrancy guard):
        // Cancel the prior turn's task AND await its completion BEFORE
        // assigning a new currentTurn. Without `await task.value`, the
        // cancelled task's last `.messageStop` could race the new turn's
        // startup and clobber `currentTurn`.
        if let priorTask = priorTask {
            priorTask.cancel()
            _ = await priorTask.value
        }

        // Stamp the cancelled turn's replay row with stop_reason="cancelled"
        // (idempotent — runTurnLoop's normal endTurn never fires after cancel
        //  because the cancelled task returns early on Task.isCancelled).
        if let priorId = priorId {
            await replayLog.endTurn(priorId, stopReason: "cancelled")
        }
        currentTurn = nil

        return await runTurn(input: input, retryOf: nil, supersededPrior: priorId)
    }

    // MARK: - Internal: turn launch

    private func runTurn(
        input: TurnInput,
        retryOf: TurnID?,
        supersededPrior: TurnID?
    ) async -> SubmitOutcome {
        let turnId = TurnID.fresh()
        let nonce = TurnNonce.fresh()
        let perTurn = await configStore.perTurn()

        let provider: any LLMProvider
        do {
            provider = try await providerFactory(perTurn.resolvedProvider)
        } catch {
            logger.error("providerFactory failed", metadata: [
                "provider": "\(perTurn.resolvedProvider.rawValue)",
                "error": "\(error)",
            ])
            return .rejected(reason: .providerUnavailable)
        }

        // Persist turnNonce in the replay log row (NOT in OrchestratorEvent —
        // SEC-06 invariant).
        do {
            try await replayLog.startTurn(
                turnId: turnId,
                sessionId: sessionId,
                retryOf: retryOf,
                turnNonce: nonce.rawValue,
                source: input.source,
                provider: perTurn.resolvedProvider.rawValue,
                modelId: modelIDFor(perTurn.resolvedProvider).rawValue
            )
        } catch {
            logger.error("replayLog.startTurn failed", metadata: ["error": "\(error)"])
            return .rejected(reason: .configError)
        }

        // Build the initial messages with the untrusted-content wrapper
        // pattern in scope. The user message itself is trusted; the wrapper
        // is held for the *tool result* messages that arrive later.
        let wrapper = UntrustedWrapper(nonce: nonce)
        let initialMessages: [LLMMessage] = [
            LLMMessage(role: .system, content: [.text(systemPrompt)]),
            LLMMessage(role: .user, content: [.text(input.userText)]),
        ]

        await events.send(.stateChange(.thinking))

        // Strong self capture: the orchestrator owns the task; the task lives
        // only as long as the actor (or until cancelAndSubmit drains it).
        let task = Task { [self] in
            await self.runTurnLoop(
                turnId: turnId,
                provider: provider,
                initialMessages: initialMessages,
                perTurn: perTurn,
                wrapper: wrapper,
                source: input.source
            )
        }

        currentTurn = TurnExecution(id: turnId, task: task, startedAt: Date(), retryOf: retryOf)

        if let priorId = supersededPrior {
            return .superseded(priorId: priorId, reason: .bargedIn)
        }
        return .ran(turnId: turnId)
    }

    // MARK: - Internal: turn loop (AGENT-07/08/09 live here)

    private func runTurnLoop(
        turnId: TurnID,
        provider: any LLMProvider,
        initialMessages: [LLMMessage],
        perTurn: PerTurnSnapshot,
        wrapper: UntrustedWrapper,
        source: TurnSource
    ) async {
        var messages = initialMessages
        var toolCallBudget = perTurn.maxToolCallsPerTurn()
        var retry = RetryState(originalTurnId: turnId)
        var currentTurnId = turnId
        var currentProvider = provider
        var currentPerTurn = perTurn

        outer: while true {
            // Compute tool_choice based on remaining budget.
            // AGENT-07: budget exhausted → toolChoice .none → cap-recovery.
            let toolChoice: ToolChoice = toolCallBudget > 0 ? .auto : .none
            let toolsForCall: [ToolSchema] = toolCallBudget > 0 ? availableToolsList : []

            let stream = currentProvider.stream(
                messages: messages,
                tools: toolsForCall,
                toolChoice: toolChoice,
                model: modelIDFor(currentPerTurn.resolvedProvider),
                maxOutputTokens: currentPerTurn.maxOutputTokens(),
                cacheHints: CacheHints(systemPromptTTL: .extended1h)
            )

            do {
                for try await event in stream {
                    if Task.isCancelled {
                        // cancelAndSubmit called endTurn; just exit.
                        return
                    }
                    switch event {
                    case .messageStart:
                        // No replay write for messageStart; usage block lands later.
                        break

                    case .textDelta(let s):
                        await replayLog.record(.textDelta(s), for: currentTurnId)
                        await events.send(.tokenDelta(turnId: currentTurnId, text: s))

                    case .thinkingDelta(let s):
                        await replayLog.record(.thinkingDelta(s), for: currentTurnId)
                        await events.send(.thinkingDelta(turnId: currentTurnId, text: s))

                    case .toolUseRequested(let req):
                        toolCallBudget -= 1
                        await replayLog.record(
                            .toolCallRequested(id: req.id, name: req.name, argsJSON: req.argsJSON),
                            for: currentTurnId
                        )
                        await events.send(.toolCardUpdate(ToolCardUpdate(
                            turnId: currentTurnId,
                            toolUseId: req.id,
                            toolName: req.name,
                            phase: .running,
                            resultPreview: nil,
                            error: nil
                        )))

                        // Append the assistant's tool_use block to the message
                        // history so providers that require the original
                        // tool_use round-trip (Anthropic) can resolve the
                        // tool_use_id when the next tool_result lands.
                        messages.append(LLMMessage(role: .assistant, content: [
                            .toolUse(id: req.id, name: req.name, argsJSON: req.argsJSON),
                        ]))

                        do {
                            let resultData = try await toolDispatcher.dispatch(toolUse: req)
                            // AGENT-08: cap model-facing string at 8 KB.
                            let packed = ToolResultPacker.pack(resultData)
                            // Replay receives the FULL blob — no truncation.
                            await replayLog.record(
                                .toolResultFull(toolUseId: req.id, bytes: packed.fullBytes),
                                for: currentTurnId
                            )
                            // Wrap with turn nonce (SEC-06) before promoting
                            // to the model-facing message history.
                            let wrapped = wrapper.wrap(packed.modelFacing)
                            messages.append(LLMMessage(
                                role: .tool,
                                content: [.toolResult(toolUseId: req.id, content: wrapped)],
                                untrusted: true
                            ))
                            await events.send(.toolCardUpdate(ToolCardUpdate(
                                turnId: currentTurnId,
                                toolUseId: req.id,
                                toolName: req.name,
                                phase: .completed,
                                resultPreview: String(packed.modelFacing.prefix(200)),
                                error: nil
                            )))
                        } catch {
                            let errText = String(describing: error)
                            await replayLog.record(
                                .error(Data(errText.utf8)),
                                for: currentTurnId
                            )
                            messages.append(LLMMessage(
                                role: .tool,
                                content: [.toolResult(toolUseId: req.id, content: "ERROR: \(errText)")],
                                untrusted: true
                            ))
                            await events.send(.toolCardUpdate(ToolCardUpdate(
                                turnId: currentTurnId,
                                toolUseId: req.id,
                                toolName: req.name,
                                phase: .failed,
                                resultPreview: nil,
                                error: errText
                            )))
                        }

                    case .toolUseBuffering, .partialToolUseAtDisconnect:
                        // UI hints / disconnect markers — not persisted at
                        // the replay layer (the toolCallRequested already
                        // captured the args).
                        break

                    case .usage(let u):
                        // Encode the usage as the JSON we want in replay.
                        let dict: [String: Int] = [
                            "input_tokens": u.inputTokens,
                            "output_tokens": u.outputTokens,
                            "cache_creation_input_tokens": u.cacheCreationInputTokens,
                            "cache_read_input_tokens": u.cacheReadInputTokens,
                        ]
                        if let bytes = try? JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys]) {
                            await replayLog.record(.usage(bytes), for: currentTurnId)
                        }
                        // Plan 04-05: surface usage to DevOverlay via
                        // OrchestratorEvent so token counts + cache hit ratio
                        // can be rendered without reading replay. TurnUsage
                        // has no nonce field — SEC-06 invariant preserved.
                        await events.send(.usage(turnId: currentTurnId, usage: u))

                    case .stopReason(let reason):
                        await replayLog.record(.stopReason(stopReasonString(reason)), for: currentTurnId)
                        switch reason {
                        case .endTurn:
                            await events.send(.turnEnd(turnId: currentTurnId, stopReason: .endTurn))
                            await replayLog.endTurn(currentTurnId, stopReason: "end_turn")
                            await events.send(.stateChange(.idle))
                            currentTurn = nil
                            return

                        case .toolUse:
                            // The model finished its message but wants a tool
                            // result. Continue the outer loop to re-invoke
                            // stream with the updated `messages` (which now
                            // contains the tool_result we appended above).
                            continue outer

                        case .maxTokens:
                            await events.send(.turnEnd(turnId: currentTurnId, stopReason: .maxTokens))
                            await replayLog.endTurn(currentTurnId, stopReason: "max_tokens")
                            await events.send(.stateChange(.idle))
                            currentTurn = nil
                            return

                        case .refusal:
                            await events.send(.turnEnd(turnId: currentTurnId, stopReason: .refusal))
                            await replayLog.endTurn(currentTurnId, stopReason: "refusal")
                            await events.send(.stateChange(.idle))
                            currentTurn = nil
                            return

                        case .streamTruncated:
                            // AGENT-09: bounded retry. First truncation → fresh
                            // turn id, retryOf = original, reset budget. Second
                            // → terminal `.streamTruncatedFinal`.
                            if retry.budget > 0 {
                                retry.budget -= 1

                                // Re-read PerTurnSnapshot — config can have
                                // changed between the original attempt and
                                // the retry (AGENT-09 requirement).
                                let updated = await configStore.perTurn()
                                let nextProvider: any LLMProvider
                                do {
                                    nextProvider = try await providerFactory(updated.resolvedProvider)
                                } catch {
                                    await events.send(.error(turnId: currentTurnId, error: .streamTruncatedFinal))
                                    await replayLog.endTurn(currentTurnId, stopReason: "stream_truncated_final")
                                    await events.send(.stateChange(.idle))
                                    currentTurn = nil
                                    return
                                }

                                // Close the old turn row.
                                await replayLog.endTurn(currentTurnId, stopReason: "stream_truncated_retry")

                                // Open a new turn row with retryOf set.
                                let newTurnId = TurnID.fresh()
                                do {
                                    try await replayLog.startTurn(
                                        turnId: newTurnId,
                                        sessionId: sessionId,
                                        retryOf: retry.originalTurnId,
                                        turnNonce: wrapper.nonce.rawValue,
                                        source: source,
                                        provider: updated.resolvedProvider.rawValue,
                                        modelId: modelIDFor(updated.resolvedProvider).rawValue
                                    )
                                } catch {
                                    logger.error("retry startTurn failed", metadata: ["error": "\(error)"])
                                    await events.send(.error(turnId: currentTurnId, error: .streamTruncatedFinal))
                                    await events.send(.stateChange(.idle))
                                    currentTurn = nil
                                    return
                                }

                                currentTurnId = newTurnId
                                currentProvider = nextProvider
                                currentPerTurn = updated
                                toolCallBudget = updated.maxToolCallsPerTurn()  // AGENT-09: reset
                                if let exec = currentTurn {
                                    currentTurn = TurnExecution(
                                        id: newTurnId, task: exec.task,
                                        startedAt: exec.startedAt, retryOf: retry.originalTurnId
                                    )
                                }
                                await events.send(.stateChange(.reconfiguring))
                                continue outer
                            } else {
                                // Second truncation in the same logical turn.
                                await events.send(.error(turnId: currentTurnId, error: .streamTruncatedFinal))
                                await replayLog.endTurn(currentTurnId, stopReason: "stream_truncated_final")
                                await events.send(.stateChange(.idle))
                                currentTurn = nil
                                return
                            }
                        }

                    case .providerError(let err):
                        await events.send(.error(turnId: currentTurnId, error: err))
                        await replayLog.record(.error(Data(String(describing: err).utf8)), for: currentTurnId)
                        await replayLog.endTurn(currentTurnId, stopReason: "provider_error")
                        await events.send(.stateChange(.idle))
                        currentTurn = nil
                        return

                    case .messageStop:
                        // Canonical close emitted alongside .stopReason; the
                        // .stopReason branch above is the only one that
                        // terminates the turn. Swallow this here.
                        break
                    }
                }

                // Stream ended without a .stopReason. Defensive — providers
                // are required to emit one. Treat as transport failure.
                let err: LLMProviderError = .transport(description: "stream ended without stop_reason")
                await events.send(.error(turnId: currentTurnId, error: err))
                await replayLog.endTurn(currentTurnId, stopReason: "error")
                await events.send(.stateChange(.idle))
                currentTurn = nil
                return

            } catch is CancellationError {
                return
            } catch {
                let mapped: LLMProviderError = (error as? LLMProviderError)
                    ?? .transport(description: String(describing: error))
                await events.send(.error(turnId: currentTurnId, error: mapped))
                await replayLog.record(.error(Data(String(describing: mapped).utf8)), for: currentTurnId)
                await replayLog.endTurn(currentTurnId, stopReason: "error")
                await events.send(.stateChange(.idle))
                currentTurn = nil
                return
            }
        }
    }

    // MARK: - Helpers

    private func modelIDFor(_ provider: ProviderSelection) -> ModelID {
        switch provider {
        case .anthropic: return .opus47
        case .ollama:    return .qwen25coder32b
        }
    }

    private func stopReasonString(_ r: StopReason) -> String {
        switch r {
        case .endTurn:         return "end_turn"
        case .toolUse:         return "tool_use"
        case .maxTokens:       return "max_tokens"
        case .refusal:         return "refusal"
        case .streamTruncated: return "stream_truncated"
        }
    }

    // MARK: - Test hooks

    /// For tests only: read the active turn's id (or nil). Lives here so
    /// orchestrator-internal state remains private; the @testable import
    /// barrier still keeps it out of release-build callers.
    internal func _testCurrentTurnId() -> TurnID? { currentTurn?.id }

    // MARK: - Nested types

    private struct TurnExecution: Sendable {
        let id: TurnID
        let task: Task<Void, Never>
        let startedAt: Date
        let retryOf: TurnID?
    }
}
