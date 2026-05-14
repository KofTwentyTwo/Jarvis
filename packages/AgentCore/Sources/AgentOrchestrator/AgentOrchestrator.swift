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

    // MARK: - B-02 history threading

    /// One prior turn entry hydrated from the `turns` table (or any caller-
    /// supplied source). Role is constrained to user/assistant — the
    /// orchestrator's prior-history prefix never contains tool blocks
    /// (those are reconstructed locally per current turn).
    public struct PriorTurn: Sendable, Equatable {
        public enum Role: String, Sendable, Equatable {
            case user
            case assistant
        }
        public let role: Role
        public let content: String
        public init(role: Role, content: String) {
            self.role = role
            self.content = content
        }
    }

    /// B-02 (carry-forward bug, closed by tactical patch outside the v1.0
    /// migration sequence): closure returning the most recent N prior
    /// turn rows in CHRONOLOGICAL order (oldest first). Production
    /// wiring lives in `App/AppDelegate.swift` and calls
    /// `MemoryStore.recentTurnsForSession`. The default implementation
    /// `emptySessionHistoryLookup` returns [] to preserve pre-B-02
    /// behavior in any test setup that doesn't supply a lookup.
    ///
    /// Failure mode: the closure throws → orchestrator degrades to empty
    /// history with a warning log; the turn proceeds without prior
    /// context (same as pre-B-02 behavior). Matches the D-3
    /// `PriorFactsLookup` resilience contract.
    public typealias SessionHistoryLookup = @Sendable () async throws -> [PriorTurn]

    public static let emptySessionHistoryLookup: SessionHistoryLookup = { [] }


    // MARK: - Injected dependencies

    private let configStore: ConfigStore
    private let providerFactory: @Sendable (ProviderSelection) async throws -> any LLMProvider
    private let toolDispatcher: any ToolDispatcher
    private let replayLog: ReplayLog
    private let sessionId: SessionID
    private let systemPrompt: String
    private let availableToolsList: [ToolSchema]
    /// Plan 10-02b / B-01: optional lazy resolver for the tool catalog.
    /// When non-nil, takes precedence over `availableToolsList` and is
    /// invoked once per outer turn iteration so registration timing on
    /// the in-process side (e.g. self-knowledge tools register AFTER
    /// installAgent runs) doesn't strand the orchestrator with a stale
    /// snapshot. Tests continue to pass an immutable array via
    /// `availableTools:`; production wires the resolver.
    private let availableToolsResolver: (@Sendable () async -> [ToolSchema])?
    /// Plan 09-02 / D-01 — image-bearing turns are dispatched through the
    /// VisionRouter BEFORE the streaming loop. Defaulted-nil so existing test
    /// sites (and the Plan 1 installAgent wiring before Plan 2 lands) compile
    /// unchanged. When nil, the runTurn vision branch is a no-op (the standard
    /// streaming path runs for both text-only and image-bearing turns, with the
    /// caveat that the resolved provider may not be vision-capable — callers
    /// who care about that pre-route through their own dispatcher).
    private let visionRouter: VisionRouter?

    /// Audit 2026-05-12 F-V1 — honest T2 availability flag. The orchestrator
    /// previously derived `t2AvailableForThisTurn = (decision.tier != .t3Cloud)`,
    /// passing `true` on every local-tier vision turn. In production T2 is
    /// `MissingT2Provider` (no real T2 sidecar exists yet — that's v1.1, GH
    /// issue #84). Combined with the router's escalate-on-low-confidence
    /// heuristic, every short / "I'm not sure" T1 response escalated into
    /// `MissingT2Provider.stream(...)` which throws `t2ProviderUnavailable`,
    /// killing the turn. Until a real T2 provider is wired, production passes
    /// `false`; tests that exercise T1→T2 escalation pass `true` and supply a
    /// real mock T2 provider.
    private let hasRealT2Provider: Bool

    /// Plan 09-03 / D-13 + D-14 — read-only ambient presence snapshot.
    /// `runTurn` queries `currentEnrichment()` during system-prompt
    /// composition and appends a plain sentence (e.g., "User is at the
    /// desk.") OUTSIDE the nonce-wrapped untrusted region. Defaulted-nil so
    /// existing test sites compile unchanged; the snapshot is read-only on
    /// the orchestrator side. VISION-03 boundary: the orchestrator only
    /// touches the `String?` return type — never the underlying PresenceEvent.
    private let presenceSnapshot: PresenceStateSnapshot?

    /// B-02 history lookup closure (see `SessionHistoryLookup` doc on the
    /// enclosing actor). Defaulted to `emptySessionHistoryLookup` so test
    /// sites that don't care about history still compile unchanged.
    private let sessionHistoryLookup: SessionHistoryLookup

    /// Round 4 — boot-health degradation summary. When non-nil and non-empty,
    /// prepended VERBATIM before the system prompt on every turn so the
    /// model can't lie about working features (the Toby-the-dog case:
    /// embedder missing → fact never persisted → Jarvis said "Got it" anyway).
    ///
    /// The string is built by `AppDelegate.buildDegradationSummary` after
    /// `runBootHealth` finishes and is updated by re-probes from the Status
    /// panel via `setDegradationSummary(_:)`. The orchestrator treats it as
    /// an opaque trusted prefix — no parsing, no truncation beyond the soft
    /// 500-char ceiling enforced at build time (see CacheHints invariant:
    /// keep below the 4096-char Anthropic cache breakpoint).
    ///
    /// Mutable because `installAgent` runs BEFORE `runBootHealth` in the
    /// boot order, so we need to update the value post-construction. Reads
    /// happen inside `runTurn` so actor isolation makes the read/write
    /// pair safe without external locking.
    private var degradationSummary: String?

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
        availableToolsResolver: (@Sendable () async -> [ToolSchema])? = nil,
        visionRouter: VisionRouter? = nil,
        hasRealT2Provider: Bool = false,
        presenceSnapshot: PresenceStateSnapshot? = nil,
        sessionHistoryLookup: @escaping SessionHistoryLookup = AgentOrchestrator.emptySessionHistoryLookup,
        degradationSummary: String? = nil
    ) {
        self.configStore = configStore
        self.providerFactory = providerFactory
        self.toolDispatcher = toolDispatcher
        self.replayLog = replayLog
        self.sessionId = sessionId
        self.systemPrompt = systemPrompt
        self.availableToolsList = availableTools
        self.availableToolsResolver = availableToolsResolver
        self.visionRouter = visionRouter
        self.hasRealT2Provider = hasRealT2Provider
        self.presenceSnapshot = presenceSnapshot
        self.sessionHistoryLookup = sessionHistoryLookup
        self.degradationSummary = degradationSummary
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

    /// #20 (audit-2026-05-12 CRIT-1) — the in-flight `TurnID`, or `nil` if
    /// no turn is active. `ReplayingToolResultObserver.attach(...)` reads
    /// this from a `@Sendable () async -> TurnID?` closure so the SEC-07
    /// dual-write + ME-04 channel can correlate replay rows with the
    /// current turn. One actor-hop per tool dispatch — acceptable cost
    /// (tools fire 1–3× per turn).
    public func currentTurnID() -> TurnID? {
        currentTurn?.id
    }

    /// BLOCKER-2 actor-internal populator. Called from `runTurn` after
    /// allocating the `TurnID` when `input.source == .voice`.
    private func recordVoiceTurn(_ turnId: TurnID) {
        voiceOriginatedTurns.insert(turnId)
    }

    // MARK: - Round 4 — degradation summary setter

    /// Updates the boot-health degradation summary. Called from
    /// `AppDelegate.runBootHealth()` after every probe sweep — once at
    /// boot, then again on every Status-panel re-probe — so the agent's
    /// system prompt reflects current subsystem health on the very next
    /// turn. Pass `nil` (or empty string) to clear the summary when every
    /// subsystem returns to `.ok`.
    public func setDegradationSummary(_ summary: String?) {
        degradationSummary = summary
    }

    /// Test introspection — read-only view of the current summary, used
    /// by the AgentOrchestratorDegradationPreambleTests regression to
    /// confirm AppDelegate-side updates land inside the actor.
    public func _currentDegradationSummary() -> String? {
        degradationSummary
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
            // Audit 2026-05-12 F-V1: T2 is available iff we routed local AND
            // a real T2 provider is wired. Production passes
            // `hasRealT2Provider: false` because AppDelegate wires
            // `MissingT2Provider` (the real T2 sidecar is v1.1 work, GH
            // issue #84). Without the AND-gate, every low-confidence local
            // T1 response escalated into `MissingT2Provider.stream(...)`
            // which throws `t2ProviderUnavailable`, killing the turn. The
            // router's `evaluatePostResponse(..., t2Available: false)`
            // correctly stays-on-T1 in that case.
            t2AvailableForThisTurn = (decision.tier != .t3Cloud) && hasRealT2Provider
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
        // Round 4: degradation summary is the FIRST thing the model sees
        // when any subsystem is critical/loud. Prepended outside the
        // nonce wrapper because the string is locally rendered from a
        // typed BootHealthSnapshot (no untrusted input), and it must
        // outrank everything else — including the locked self-aware
        // preamble — so the model can't promise to use a dead capability.
        // Empty / nil → omit (no behavior change when everything is .ok).
        let degradationLine: String?
        if let summary = degradationSummary?.trimmingCharacters(in: .whitespacesAndNewlines), !summary.isEmpty {
            degradationLine = summary
        } else {
            degradationLine = nil
        }
        // Plan 09-03 / D-13 + D-14: append presence enrichment OUTSIDE the
        // nonce-wrapped untrusted region. The presence sentence is trusted
        // (rendered locally by PresenceStateSnapshot from a typed enum), so
        // it does not need to ride inside the wrapper. Suppression rule
        // (D-14) is enforced inside `currentEnrichment()` — when nil we
        // omit the suffix entirely.
        let presenceLine = await presenceSnapshot?.currentEnrichment()
        var finalSystem = composedSystem
        if let degradationLine {
            finalSystem = "\(degradationLine)\n\n\(finalSystem)"
        }
        if let presenceLine, !presenceLine.isEmpty {
            finalSystem = "\(finalSystem)\n\n\(presenceLine)"
        }
        // B-02 (carry-forward bug, fixed by tactical patch outside the
        // v1.0 migration sequence): hydrate prior turn history from the
        // session-history lookup and prepend between system prompt and
        // current user message. Without this, every turn looked like a
        // first message to the model — "yes" / "why?" / pronoun
        // resolution lost prior turn context.
        //
        // Failure mode: lookup throws → warning log + empty history.
        // Matches the D-3 priorFactsLookup pattern; drain task survives.
        //
        // The lookup returns turns in CHRONOLOGICAL order (oldest first)
        // so the LLM sees the natural alternation user → assistant →
        // user → assistant → … → current user.
        //
        // T-06-05-03: do NOT log row content; turn text is user-bearing
        // and may contain PII. Count only.
        let priorTurns: [PriorTurn]
        do {
            priorTurns = try await sessionHistoryLookup()
        } catch {
            logger.warning("sessionHistoryLookup failed: \(error) — proceeding with empty history")
            priorTurns = []
        }
        let priorMessages: [LLMMessage] = priorTurns.map { turn in
            switch turn.role {
            case .user:
                return LLMMessage(role: .user, content: [.text(turn.content)])
            case .assistant:
                return LLMMessage(role: .assistant, content: [.text(turn.content)])
            }
        }
        var initialMessages: [LLMMessage] = [
            LLMMessage(role: .system, content: [.text(finalSystem)])
        ]
        initialMessages.append(contentsOf: priorMessages)
        initialMessages.append(LLMMessage(role: .user, content: [.text(input.userText)]))

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
        // #24: text accumulated since the most recent toolUse append (or
        // since the start of the round if no toolUse yet). Distinct from
        // `assistantTextSoFar` which stays cumulative for D-02 vision
        // routing on endTurn. This buffer feeds the assistant message
        // history alongside each toolUse block so the model sees its own
        // narration ("Let me check..." → tool_use(get_time)) on subsequent
        // round-trips; previously the text was dropped entirely from
        // history and the model would deny ever saying it.
        var assistantTextSinceLastFlush: String = ""
        // D-02: escalation gets ONE shot. The second low-confidence outcome
        // stays on T1 (the user got the response we have). This mirrors the
        // AGENT-09 retry budget but is independent of it.
        var escalationConsumed = false

        outer: while true {
            // Compute tool_choice based on remaining budget.
            // AGENT-07: budget exhausted → toolChoice .none → cap-recovery.
            let toolChoice: ToolChoice = toolCallBudget > 0 ? .auto : .none
            // Plan 10-02b / B-01: prefer the lazy resolver so production
            // can refresh the catalog as in-process tools register after
            // installAgent runs. Tests pass an immutable array via
            // `availableTools:` and leave `availableToolsResolver: nil`,
            // so behavior there is unchanged.
            let resolvedCatalog: [ToolSchema]
            if let resolver = availableToolsResolver {
                resolvedCatalog = await resolver()
            } else {
                resolvedCatalog = availableToolsList
            }
            let toolsForCall: [ToolSchema] = toolCallBudget > 0 ? resolvedCatalog : []

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
                        // #24: also accumulate into the per-tool-use flush
                        // buffer so the next toolUseRequested attaches the
                        // preceding narration to its assistant message.
                        assistantTextSinceLastFlush += s
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
                        //
                        // #24: bundle any text the model emitted since the
                        // last flush — Opus 4.7 commonly narrates ("Let me
                        // check the time...") before calling a tool. Without
                        // this the text was dropped from history and the
                        // model would deny ever saying it on a follow-up.
                        // Trim whitespace-only text to avoid emitting empty
                        // text blocks (which Anthropic rejects with a 400).
                        var assistantContent: [LLMMessage.ContentBlock] = []
                        let pendingText = assistantTextSinceLastFlush
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                        if !pendingText.isEmpty {
                            assistantContent.append(.text(pendingText))
                        }
                        assistantContent.append(
                            .toolUse(id: req.id, name: req.name, argsJSON: req.argsJSON)
                        )
                        messages.append(LLMMessage(role: .assistant, content: assistantContent))
                        // Consumed — the next toolUseRequested in the same
                        // round (rare but possible) gets only the text that
                        // came BETWEEN the two tool_use blocks. D-02's
                        // cumulative `assistantTextSoFar` is untouched.
                        assistantTextSinceLastFlush = ""

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
        case .malformedToolCall(let reason):
            return .malformedToolCall(reason: Redact.apply(reason))
        case .emptyResponse:
            return .emptyResponse
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
