import Foundation
import AgentCore
import Config
import Replay
import JarvisLogging
import JarvisVision
import Logging

/// Heart of Phase 4 — the turn-lifecycle actor.
///
/// **Entry points (AGENT-06):**
/// - `submit(_:)` — start a fresh turn; rejected with `.turnInFlight` if busy.
/// - `cancelAndSubmit(_:)` — barge-in primitive; cancels the in-flight turn,
///   awaits its task to drain (no actor-reentrancy race), then starts a new
///   turn returning `.superseded(priorId:newTurnId:reason:)`.
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
    /// Plan 09-02 / D-01 — image-bearing turns are dispatched through the
    /// VisionRouter BEFORE the streaming loop. Defaulted-nil so existing test
    /// sites (and the Plan 1 installAgent wiring before Plan 2 lands) compile
    /// unchanged. When nil, the runTurn vision branch is a no-op (the standard
    /// streaming path runs for both text-only and image-bearing turns, with the
    /// caveat that the resolved provider may not be vision-capable — callers
    /// who care about that pre-route through their own dispatcher).
    private let visionRouter: VisionRouter?

    /// Plan 09-03 / D-13 + D-14 — read-only ambient presence snapshot.
    /// `runTurn` queries `currentEnrichment()` during system-prompt
    /// composition and appends a plain sentence (e.g., "User is at the
    /// desk.") OUTSIDE the nonce-wrapped untrusted region. Defaulted-nil so
    /// existing test sites compile unchanged; the snapshot is read-only on
    /// the orchestrator side. VISION-03 boundary: the orchestrator only
    /// touches the `String?` return type — never the underlying PresenceEvent.
    private let presenceSnapshot: PresenceStateSnapshot?
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

    /// Plan 09-02 / D-16 — turns that carried an `ImageBlock`. The
    /// broadcaster's frame-attach subscriber asks `turnHadImage(_:)` after
    /// `.turnEnd` to decide whether to call `FrameAttachController
    /// .onAssistantTurnComplete()`. Grows monotonically; pruning is deferred
    /// (each entry is the size of a UUID-string TurnID, so even a long-running
    /// app accumulates only kilobytes per session).
    private var imageBearingTurns: Set<TurnID> = []

    /// Plan 09-02 / BLOCKER-2 — turns submitted via `.voice(...)`. Plan 4's
    /// voice subscriber drain gates `emitTurnEnded` on this set so
    /// text-originated turns don't drive `VoiceController` back to `.idle`
    /// from `.listening` when text + voice share the orchestrator. Same
    /// pruning caveat as `imageBearingTurns`.
    private var voiceOriginatedTurns: Set<TurnID> = []

    // MARK: - Init

    public init(
        configStore: ConfigStore,
        providerFactory: @escaping @Sendable (ProviderSelection) async throws -> any LLMProvider,
        toolDispatcher: any ToolDispatcher,
        replayLog: ReplayLog,
        sessionId: SessionID,
        systemPrompt: String,
        availableTools: [ToolSchema] = [],
        visionRouter: VisionRouter? = nil,
        presenceSnapshot: PresenceStateSnapshot? = nil
    ) {
        self.configStore = configStore
        self.providerFactory = providerFactory
        self.toolDispatcher = toolDispatcher
        self.replayLog = replayLog
        self.sessionId = sessionId
        self.systemPrompt = systemPrompt
        self.availableToolsList = availableTools
        self.visionRouter = visionRouter
        self.presenceSnapshot = presenceSnapshot
        self.logger = Logger(label: JarvisLogChannel.agent.rawValue)
        self.events = BoundedAsyncChannel<OrchestratorEvent>(capacity: 256, policy: .suspend)
    }

    // MARK: - Public accessors (Plan 09-02)

    /// D-16 — true iff the turn carried an `ImageBlock`. The broadcaster's
    /// frame-attach subscriber asks this on `.turnEnd` to decide whether to
    /// release the captured frame via `FrameAttachController.onAssistantTurnComplete()`.
    public func turnHadImage(_ turnId: TurnID) -> Bool {
        imageBearingTurns.contains(turnId)
    }

    /// BLOCKER-2 — true iff the turn was submitted via `TurnInput.voice(...)`.
    /// Plan 4's voice subscriber drain calls this to filter `.tokenDelta` /
    /// `.turnEnd` events that belong to text-originated turns (without this,
    /// a text-originated `.turnEnd` would drive `VoiceController` back to
    /// `.idle` from `.listening`).
    public func turnSourceWasVoice(_ turnId: TurnID) -> Bool {
        voiceOriginatedTurns.contains(turnId)
    }

    /// BLOCKER-2 actor-internal populator. Called from `runTurn` after
    /// allocating the `TurnID` when `input.source == .voice`.
    private func recordVoiceTurn(_ turnId: TurnID) {
        voiceOriginatedTurns.insert(turnId)
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

        // BLOCKER-2: track voice-originated turns inside the actor's isolation
        // domain so Plan 4's voice subscriber can filter text-originated turns.
        if input.source == .voice {
            recordVoiceTurn(turnId)
        }

        var provider: any LLMProvider
        do {
            provider = try await providerFactory(perTurn.resolvedProvider)
        } catch {
            logger.error("providerFactory failed", metadata: [
                "provider": "\(perTurn.resolvedProvider.rawValue)",
                "error": "\(error)",
            ])
            return .rejected(reason: .providerUnavailable)
        }

        // D-01: image-bearing turn → swap provider via VisionRouter BEFORE
        // the streaming loop. T2 is reachable only via post-response
        // escalation (D-02) inside runTurnLoop; route(...) selects T1 by
        // default and T3 ONLY when explicitCloudOptIn (D-18). The first
        // image is the routing input; Phase 9 supports single-frame attach
        // (VISION-04). Multi-frame turns are out of scope until a future
        // plan revisits the route signature.
        var t2AvailableForThisTurn = false
        if !input.images.isEmpty, let router = self.visionRouter,
           let firstImage = input.images.first {
            // Plan 10-02 disambiguation: qualify with `JarvisVision.` because
            // AgentCore now also exposes a `ContextBuilder` (the self-aware
            // system-prompt composer). The two types live in distinct modules;
            // bare `ContextBuilder()` would be ambiguous to the type checker.
            let cloudOptIn = JarvisVision.ContextBuilder().matchesCloudOptIn(input.userText)
            let decision = await router.route(
                for: firstImage,
                prompt: input.userText,
                explicitCloudOptIn: cloudOptIn
            )
            provider = await router.providerForTier(decision.tier)
            // T2 is available iff we routed local — D-04 ships with
            // t2Provider == t1Provider, but evaluatePostResponse correctly
            // stays-on-T1 when t2Available == false, so passing the actual
            // tier here keeps the contract honest.
            t2AvailableForThisTurn = (decision.tier != .t3Cloud)
            imageBearingTurns.insert(turnId)
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
        //
        // SEC-06: compose the caller's system prompt with a nonce-keyed
        // directive that tells the model the wrapper means "data, not
        // instructions". Without this directive the wrapper is decoration —
        // see `UntrustedWrapper.composeSystemPrompt(base:nonce:)` doc.
        let wrapper = UntrustedWrapper(nonce: nonce)
        let composedSystem = UntrustedWrapper.composeSystemPrompt(
            base: systemPrompt, nonce: nonce
        )
        // Plan 09-03 / D-13 + D-14: append presence enrichment OUTSIDE the
        // nonce-wrapped untrusted region. The presence sentence is trusted
        // (rendered locally by PresenceStateSnapshot from a typed enum), so
        // it does not need to ride inside the wrapper. Suppression rule
        // (D-14) is enforced inside `currentEnrichment()` — when nil we
        // omit the suffix entirely.
        let presenceLine = await presenceSnapshot?.currentEnrichment()
        let finalSystem: String
        if let presenceLine, !presenceLine.isEmpty {
            finalSystem = "\(composedSystem)\n\n\(presenceLine)"
        } else {
            finalSystem = composedSystem
        }
        let initialMessages: [LLMMessage] = [
            LLMMessage(role: .system, content: [.text(finalSystem)]),
            LLMMessage(role: .user, content: [.text(input.userText)]),
        ]

        // Phase E (2026-05-03 audit fix): gate `extended1h` cache hints on
        // system-prompt size. Anthropic returns 200 OK + immediate-EOF for
        // extended-cache-ttl markers below the cache breakpoint (~1024
        // tokens for Opus 4.7). The orchestrator's default system prompt
        // is ~10 tokens; passing the hint unconditionally produced
        // streamTruncatedFinal on every chat submit. Once memory hydration
        // / presence enrichment grows the prompt past the threshold, the
        // hint resumes automatically. Coverage:
        // CacheHintsEligibilityTests + RequestBodyTests R5a/R5b.
        let cacheHintsForThisTurn = CacheHints.eligibleForSystemPrompt(finalSystem)

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
                input: input,
                t2AvailableForThisTurn: t2AvailableForThisTurn,
                cacheHints: cacheHintsForThisTurn
            )
        }

        currentTurn = TurnExecution(id: turnId, task: task, startedAt: Date(), retryOf: retryOf)

        if let priorId = supersededPrior {
            return .superseded(priorId: priorId, newTurnId: turnId, reason: .bargedIn)
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
        input: TurnInput,
        t2AvailableForThisTurn: Bool,
        cacheHints: CacheHints?
    ) async {
        // `source` was a parameter prior to Plan 09-02; it's now derived from
        // `input.source` to match the AGENT-09 retry path (which still
        // allocates fresh turns under the original source). Keeping a local
        // `source` binding preserves the existing call sites below.
        let source: TurnSource = input.source

        var messages = initialMessages
        var toolCallBudget = perTurn.maxToolCallsPerTurn()
        var retry = RetryState(originalTurnId: turnId)
        var currentTurnId = turnId
        var currentProvider = provider
        var currentPerTurn = perTurn
        // D-02: post-response escalation needs the running concat of textDelta
        // for the current pass. Reset on each pass restart (initial entry +
        // T1→T2 escalation re-enter via `continue outer`).
        var assistantTextSoFar: String = ""
        // D-02: escalation gets ONE shot. The second low-confidence outcome
        // stays on T1 (the user got the response we have). This mirrors the
        // AGENT-09 retry budget but is independent of it.
        var escalationConsumed = false

        outer: while true {
            // Compute tool_choice based on remaining budget.
            // AGENT-07: budget exhausted → toolChoice .none → cap-recovery.
            let toolChoice: ToolChoice = toolCallBudget > 0 ? .auto : .none
            let toolsForCall: [ToolSchema] = toolCallBudget > 0 ? availableToolsList : []

            // D-01: image-bearing turns use the multimodal stream overload so
            // the provider can encode the image bytes per its API
            // (Anthropic vision blocks vs Ollama OpenAI-compat data URLs).
            // Text-only turns fall through to the single-modal stream — the
            // default `LLMProvider` extension handles `images.isEmpty`
            // gracefully on text-only conformers.
            let stream: AsyncThrowingStream<LLMEvent, Error>
            if !input.images.isEmpty {
                stream = currentProvider.stream(
                    messages: messages,
                    images: input.images,
                    tools: toolsForCall,
                    toolChoice: toolChoice,
                    model: modelIDFor(currentPerTurn.resolvedProvider),
                    maxOutputTokens: currentPerTurn.maxOutputTokens(),
                    cacheHints: cacheHints
                )
            } else {
                stream = currentProvider.stream(
                    messages: messages,
                    tools: toolsForCall,
                    toolChoice: toolChoice,
                    model: modelIDFor(currentPerTurn.resolvedProvider),
                    maxOutputTokens: currentPerTurn.maxOutputTokens(),
                    cacheHints: cacheHints
                )
            }

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
                        // D-02: accumulate the assistant's text for the
                        // current pass so the post-response escalation hook
                        // can hand it to VisionRouter.evaluatePostResponse.
                        // Reset on `continue outer` from the escalation arm.
                        assistantTextSoFar += s
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
                            // D-02 / WARNING-3 LOCKED STRATEGY: labeled-loop
                            // `continue outer`. When the post-response check
                            // says low-confidence + T2 available, discard the
                            // T1 assistant message from `messages`, swap to
                            // T2, reset the accumulator, and re-enter the
                            // streaming loop under the SAME `currentTurnId`.
                            // The user sees ONE final answer (no second turn
                            // row, no fresh turnId — this is what makes D-02
                            // distinct from AGENT-09's stream_truncated retry
                            // path which DOES allocate a fresh turnId).
                            //
                            // Escalation gets ONE shot (`escalationConsumed`).
                            // A second low-confidence outcome stays on T1 —
                            // we already have a response and the AGENT-09
                            // retry path is the only thing that reaches a
                            // fresh-turnId retry from here.
                            if !input.images.isEmpty,
                               !escalationConsumed,
                               let router = self.visionRouter {
                                let outcome = await router.evaluatePostResponse(
                                    assistantTextSoFar,
                                    config: .default,
                                    t2Available: t2AvailableForThisTurn
                                )
                                if outcome == .escalateToT2 {
                                    escalationConsumed = true
                                    await replayLog.record(
                                        .escalationAttempt(turnId: currentTurnId, kind: .t1ToT2),
                                        for: currentTurnId
                                    )
                                    currentProvider = await router.providerForTier(.t2LocalQuality)
                                    // Discard T1's assistant message from
                                    // model-facing history; T2 re-streams from
                                    // the same initial messages + image(s).
                                    messages = initialMessages
                                    assistantTextSoFar = ""
                                    continue outer
                                }
                            }
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
                        // HI-01: redact credential-shaped substrings from the
                        // provider error body BEFORE forwarding to either the
                        // bus or the replay log. Anthropic's API can echo a
                        // malformed `x-api-key` header value verbatim in the
                        // body of a 401 response; that string MUST NOT cross
                        // the webview trust boundary or land in persistent
                        // storage in cleartext. Single redaction site.
                        let redactedErr = Self.redact(err)
                        await events.send(.error(turnId: currentTurnId, error: redactedErr))
                        await replayLog.record(.error(Data(String(describing: redactedErr).utf8)), for: currentTurnId)
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
                // HI-01: same redaction at the catch boundary as the
                // .providerError case. Single redaction site — see
                // `redact(_:)` below.
                let redactedMapped = Self.redact(mapped)
                await events.send(.error(turnId: currentTurnId, error: redactedMapped))
                await replayLog.record(.error(Data(String(describing: redactedMapped).utf8)), for: currentTurnId)
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

    /// HI-01: scrub credential-shaped substrings (Anthropic `sk-ant-…`,
    /// OpenAI `sk-…`, Bearer tokens, AKIA, GitHub PATs) from the body of a
    /// provider error before it crosses the bus or lands in replay. The
    /// underlying regex lives in `JarvisLogging.Redact`; we only redact
    /// the `body`/`description` strings, preserving the case structure.
    nonisolated static func redact(_ err: LLMProviderError) -> LLMProviderError {
        switch err {
        case .api(let code, let body):
            return .api(statusCode: code, body: Redact.apply(body))
        case .decode(let reason):
            return .decode(reason: Redact.apply(reason))
        case .transport(let description):
            return .transport(description: Redact.apply(description))
        case .streamTruncatedFinal:
            return .streamTruncatedFinal
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
