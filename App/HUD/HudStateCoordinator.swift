import Foundation

/// HUD-08 single-writer keystone. This class is the **only** Swift-side writer
/// of `HudState`. All three producer subsystems (agent, voice, confirmation)
/// feed it via `AsyncStream`; the coordinator resolves them through the
/// precedence ladder and calls the injected `emit` closure exactly once per
/// *distinct* resolved state.
///
/// Precedence ladder (HUD-08, literal from spec):
///   `awaitingConfirmation > speaking > listening > thinking > idle > booting > reconfiguring`
///
/// The `ready` gate is a RESEARCH Open Q #4 pre-authorized inline tweak: until
/// `markReady()` flips `ready=true`, any fallthrough to `.idle`/`.reconfiguring`
/// is pinned to `.booting` so the HUD shows "starting up" during boot even
/// when no intents have fired yet. awaitingConfirm/speaking/listening/thinking
/// still dominate booting if they genuinely apply during boot.
///
/// Bus-agnostic: takes an injected `@MainActor (HudState) -> Void` emit
/// closure rather than a `WebviewBridge` dependency. Plan 03-05 wires the
/// closure to `bridge.send(.hudState(…))`.
@MainActor
public final class HudStateCoordinator {
    // MARK: - Shadow fields (single-writer by virtue of MainActor isolation)

    private var lastAgent: AgentHudIntent = .idle
    private var lastVoice: VoiceHudIntent = .silent
    private var awaitingConfirm: Bool = false
    private var ready: Bool = false
    private var current: HudState = .booting

    // MARK: - Injected collaborator

    private let emit: @MainActor (HudState) -> Void

    // MARK: - Subscriber tasks

    private var agentTask: Task<Void, Never>?
    private var voiceTask: Task<Void, Never>?
    private var confirmTask: Task<Void, Never>?

    public init(emit: @escaping @MainActor (HudState) -> Void) {
        self.emit = emit
    }

    deinit {
        agentTask?.cancel()
        voiceTask?.cancel()
        confirmTask?.cancel()
    }

    /// Test-only introspection. Not a setter — the ONLY path to mutate state
    /// is an intent arriving on one of the three streams or `markReady()`.
    public var currentStateForTests: HudState { current }

    /// Wire the three producer streams. Each stream is drained by a dedicated
    /// `Task { for await ... }` loop under `[weak self]` — cancellation on
    /// deinit prevents retain leaks (T-03-03 mitigation).
    public func start(
        agent: AsyncStream<AgentHudIntent>,
        voice: AsyncStream<VoiceHudIntent>,
        confirmation: AsyncStream<ConfirmHudIntent>
    ) {
        // Emit the initial `.booting` state so downstream observers see a
        // first value even if no intents fire before markReady().
        emit(current)

        agentTask = Task { [weak self] in
            for await intent in agent {
                guard let self else { return }
                await MainActor.run {
                    self.lastAgent = intent
                    self.resolveAndEmit()
                }
            }
        }
        voiceTask = Task { [weak self] in
            for await intent in voice {
                guard let self else { return }
                await MainActor.run {
                    self.lastVoice = intent
                    self.resolveAndEmit()
                }
            }
        }
        confirmTask = Task { [weak self] in
            for await intent in confirmation {
                guard let self else { return }
                await MainActor.run {
                    switch intent {
                    case .required: self.awaitingConfirm = true
                    case .cleared: self.awaitingConfirm = false
                    }
                    self.resolveAndEmit()
                }
            }
        }
    }

    /// Flip the boot gate. Typically promotes `.booting` → `.idle` (or
    /// whatever lastAgent/lastVoice resolve to).
    public func markReady() {
        ready = true
        resolveAndEmit()
    }

    /// Explicit cancellation for deterministic test teardown.
    public func cancelAll() {
        agentTask?.cancel()
        voiceTask?.cancel()
        confirmTask?.cancel()
        agentTask = nil
        voiceTask = nil
        confirmTask = nil
    }

    // MARK: - Resolver (the ONE call-site that writes `current`)

    private func resolveAndEmit() {
        let resolved: HudState
        if awaitingConfirm {
            resolved = .awaitingConfirmation
        } else if case .speaking = lastAgent {
            resolved = .speaking
        } else if case .listening = lastVoice {
            resolved = .listening
        } else if case .thinking = lastAgent {
            resolved = .thinking
        } else if !ready {
            // Booting gate — see doc-comment above + RESEARCH Open Q #4.
            resolved = .booting
        } else if case .reconfiguring = lastVoice {
            resolved = .reconfiguring
        } else {
            resolved = .idle
        }
        guard resolved != current else { return }
        current = resolved
        emit(resolved)
    }
}
