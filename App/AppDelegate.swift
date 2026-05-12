// AppDelegate.swift
//
// Composition root of the Jarvis host. Owns every system-level surface (menu
// bar, HUD panel, banner panel, hotkey monitor) plus the install entry points
// that wire AgentOrchestrator + MCP runtime + voice/vision/memory subsystems +
// the Bus bridge + the boot-health probe set.
//
// This is the file every new contributor opens first. The class docstring
// below carries the install-order DAG + the "Before you edit" invariant list;
// read both before touching anything in here.
//
// See also: App/HUD/HudStateCoordinator.swift (single HudState writer),
//           App/MCP/MCPRuntimeWiring.swift (MCP composite construction),
//           packages/AgentCore/Sources/AgentOrchestrator/AgentOrchestrator.swift
//           (the LLM turn loop this file owns the lifetime of).
// (audit trail: Plans 03–10 wired this file end-to-end; audit-2026-05-04
//  P3-16 flagged it for a `+Voice` / `+Vision` / `+Memory` / `+Agent` split.)

import AppKit
import AVFoundation
import Bus
import Config
import DevOverlay
import Keychain
import JarvisLogging
import Shell
import Voice                 // VoiceController + PushToTalk + MuteWakeWord.
import WebKit
import Logging               // swift-log; `Logger` here resolves to `Logging.Logger`.
import AgentCore             // BoundedAsyncChannel (ME-04 closure).
import AgentOrchestrator     // OrchestratorEvent type for memory-coordinator wiring.
import Replay                // ReplayEvent + ReplayLog for the orch→replay channel.
import JarvisMCP             // MCPRuntimeWiring.build for end-to-end ME-04 closure.
import Memory                // MemoryStore + MemoryExtraction{Orchestrator,Coordinator}.
import JarvisVision          // CameraCapture + PresenceMonitor + VisionRouter.
import OllamaProvider        // Local provider — T1 vision + memory extractor backbone.
import AnthropicProvider     // Cloud provider — T3 vision escape hatch.

/// Abstracts the `JarvisEntitlementsVerified` Info.plist read so tests can
/// inject a stub probe instead of mutating the running binary's Info.plist.
/// The key itself is flipped to `true` by `scripts/verify-entitlements.sh
/// --pre-codesign` after every required entitlement passes its grep.
public protocol EntitlementGateProbe: Sendable {
    func isVerified() -> Bool
}

/// Production probe — reads `JarvisEntitlementsVerified` straight from
/// `Bundle.main`. Missing key (e.g. an ad-hoc local build that skipped the
/// verify script) reads as `false`, which hard-blocks launch with the
/// "Jarvis can't start" modal.
public struct InfoPlistEntitlementGateProbe: EntitlementGateProbe {
    public init() {}
    public func isVerified() -> Bool {
        Bundle.main.object(forInfoDictionaryKey: "JarvisEntitlementsVerified") as? Bool ?? false
    }
}

/// Composition root of the Jarvis host. Owns the menu bar item, HUD panel,
/// banner panel, hotkey monitor, agent orchestrator, MCP runtime, voice/vision/
/// memory subsystems, the Bus bridge, and the boot-health probe set.
///
/// ## Where this fits
/// AppKit ──▶ this file ──▶ {WKWebView (HUD), agent orchestrator, MCP runtime,
/// voice/vision/memory subsystems}. Almost everything else is leaf code
/// reachable from here.
///
/// ## Install order (lifecycle, top of `applicationWillFinishLaunching`)
///
///     1. loggingBootstrap()           — multiplex (file + os + broadcast)
///     2. entitlement verification     — hard-block if marker missing
///     3. config load                  — hard-block on malformed
///     4. installMenuBar / installHUDPanel / installBannerPanel
///     4.5 installBus                  — WKWebView + HudStateCoordinator wired
///     5. keychain probe               — banner if API key absent
///     6. input-monitoring probe       — banner if TCC denied
///     7. HotkeyBinder constructor     — unbound at launch
///     8. first-launch wizard          — if Keychain empty
///     9. orch→replay channel + log    — ME-04 closure (drain task spawned)
///    10. mcpInstallTask     (parallel) ──┐
///    11. memoryInstallTask  (parallel) ──┤
///    12. visionInstallTask  (parallel) ──┤
///                                        ├──▶ agentInstallTask
///                                        │           │
///                                        │           ▼
///                                        │   voiceInstallTask
///                                        │           │
///                                        │           ▼
///                                        │   selfKnowledgeInstallTask
///                                        │           │
///                                        │           ▼
///                                        └──▶ bootHealthTask
///
/// Every install Task is fail-soft (degrades + banner) except entitlement
/// verification, config-load malformed, and MemoryStore.init failure — those
/// three call `TCCAlertService.presentHardBlock` and `NSApp.terminate`.
///
/// ## Threading
/// `@MainActor` because every AppKit surface this touches (`NSStatusItem`,
/// `NSPanel`, alert presenter) is main-thread-only. Subsystems live behind
/// their own actors; we hop into them with `await`. The single `@MainActor`
/// guarantee on this class is what lets every install method read mutable
/// properties without locks.
///
/// ## Before you edit
/// - **Single-writer HudState** (`scripts/check-single-writer-hudstate.sh`) —
///   only `HudStateCoordinator` mutates `HudState`. AppDelegate is allowlisted
///   solely as the wiring-layer emit closure inside `installBus`; do not
///   construct `.hudState(_:)` anywhere else in this file.
/// - **Install order is locked** (`scripts/check-install-order.sh`) — vision →
///   agent → voice. Reordering the Task spawn lines breaks `installAgent`'s
///   dependency on `visionRouter` + `frameAttachController`, and breaks
///   `installVoice`'s dependency on `agentOrchestrator` + `turnTranscriptStore`.
///   The gate also enforces `await self?.agentInstallTask?.value` inside the
///   voice spawn.
/// - **Shared `inProcessToolRegistry`** — three install sites (`installMCP`,
///   `installMemory`, `installSelfKnowledgeTools`) register tools INTO the
///   same instance. The property is eagerly default-initialized so all three
///   see the same actor regardless of who wins the parallel-spawn race.
///   Don't construct a fresh `InProcessToolRegistry()` in any installer.
/// - **JIT entitlement** — `com.apple.security.cs.allow-jit` is mandatory on
///   Apple Silicon for WKWebView's JavaScriptCore JIT. Without it Release
///   builds crash on first navigation; Debug builds are silent.
/// - **No modal presentation** (`scripts/check-no-modal-presentation.sh`) —
///   never call `runModal`, `beginModalSession`, `NSApp.run` from this file;
///   hard-blocks route through `TCCAlertService.presentHardBlock` (NSPanel
///   beginSheet).
/// - **No `evaluateJavaScript`** (`scripts/check-no-evaluate-javascript.sh`) —
///   the only path from Swift into the webview is `WebviewBridge.send(_:)`.
///   `copyStateDump` writes a presence boolean for the API key, never the
///   value — SEC-01 / T-04-02 defense in depth.
///
/// ## Note on size
/// 2089 LOC at the audit-2026-05-04 baseline; the docstring rewrite has
/// nudged it up. Flagged for an `AppDelegate+Voice.swift` / `+Vision.swift` /
/// `+Memory.swift` / `+Agent.swift` split (audit-2026-05-04 P3-16). Until
/// then, navigate by `// MARK:` headers.
///
/// ## See Also
/// - ``AgentOrchestrator`` — the LLM turn loop
/// - ``MCPRuntime`` — tool dispatch composite (stdio helpers + in-process)
/// - ``HudStateCoordinator`` — single-writer HUD state
/// - ``BootHealthOrchestrator`` — Round 2/3/4 probe set + Status panel feed
/// - ``WebviewBridge`` — Swift↔JS bus
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    // MARK: - Test-injectable seams
    //
    // Production defaults are real adapters; XCTest hosts override these
    // before calling `applicationWillFinishLaunching` directly. Every seam
    // here is a hot path the bootstrap chain reads exactly once.

    /// Probes `JarvisEntitlementsVerified` at boot. Production reads the
    /// Info.plist key flipped by `verify-entitlements.sh --pre-codesign`;
    /// tests inject a stub that returns `false` to drive the hard-block
    /// path without rewriting the signed binary.
    var entitlementProbe: EntitlementGateProbe = InfoPlistEntitlementGateProbe()

    /// Invoked when `entitlementProbe.isVerified()` returns false.
    /// Production presents the "Jarvis can't start" modal and terminates;
    /// the XCTest-host override is a silent no-op so the test bundle loads.
    var onEntitlementFailure: @MainActor () -> Void = AppDelegate.defaultOnEntitlementFailure

    /// One-shot logging bootstrap. The default calls
    /// `JarvisLogHandlerFactory.bootstrap()`; injecting a no-op here keeps
    /// repeated XCTest runs from tripping S-8's "exactly one bootstrap"
    /// invariant inside the swift-log machinery.
    var loggingBootstrap: () -> Void = { JarvisLogHandlerFactory.bootstrap() }

    /// Reads config.json. Default: `ConfigLoader.loadSnapshots`. Tests
    /// inject closures that return canned snapshots without touching disk.
    var configLoader: (URL) throws -> (LaunchSnapshot, PerTurnSnapshot) = ConfigLoader.loadSnapshots(from:)

    /// First-launch path — writes defaults then re-reads. Same injection
    /// rationale as `configLoader`.
    var configWriter: (URL) throws -> (LaunchSnapshot, PerTurnSnapshot) = ConfigLoader.writeDefaultAndReload(to:)

    /// Keychain interface for the Anthropic API key + wizard's secret
    /// writes. `SystemKeychainStore` is the production adapter; tests use
    /// `FakeKeychain` (an in-memory dictionary).
    var keychainStore: any KeychainStore = SystemKeychainStore()

    /// Input-Monitoring TCC probe (SHELL-06). `IOHIDCheckAccess` is
    /// query-only; the probe never prompts at boot — the wizard's TCC
    /// stage owns the prompt.
    var hidProbe: any HIDAccessProbe = SystemHIDAccessProbe()

    /// Fires when the bus handshake resolves to a mismatch or timeout.
    /// Production terminates the app after `TCCAlertService` shows the
    /// hard-block modal — a broken handshake means the HUD can never
    /// render, so there is no recovery path. Tests inject a recording
    /// closure instead of terminating the XCTest process.
    var onHandshakeMismatch: @MainActor () -> Void = { NSApp.terminate(nil) }

    /// Fires after `WebviewBridge.onHandshakeArmed`. Default is a no-op;
    /// tests set this to observe armed transitions without polling.
    var onBusArmed: (@MainActor () -> Void)?

    // MARK: - AppKit surfaces
    //
    // Status item, panels, hotkey monitor, wizard/settings windows. All
    // strong, all `@MainActor` because AppKit demands it.

    var statusItem: NSStatusItem?
    var menuBarController: MenuBarIconController?
    var hudPanel: JarvisHUDPanel?
    var bannerPanel: HUDBannerPanel?
    var bannerCoordinator: HUDBannerCoordinator?
    var hotkeyBinder: HotkeyBinder?
    var wizardController: OnboardingWizardController?
    var settingsWindowController: SettingsWindowController?
    var wizardState: WizardState?
    var webviewBridge: WebviewBridge?

    // MARK: - HUD state coordinator + bus producer continuations

    /// Single Swift-side writer of `HudState`. The emit closure (installed
    /// in `installBus`) bridges `App.HudState` → `Bus.HudState` and posts
    /// `.hudState(_:)` through `WebviewBridge.send`. `markReady()` fires
    /// from `onHandshakeArmed` so the HUD promotes `.booting` → `.idle`
    /// the instant the webview handshake completes.
    ///
    /// Enforced single-writer by `scripts/check-single-writer-hudstate.sh`;
    /// only this coordinator (and the AppDelegate emit closure that wires
    /// it) may construct `.hudState(_:)` payloads.
    var hudStateCoordinator: HudStateCoordinator?

    /// Producer-side continuations for the coordinator's three input
    /// streams (agent / voice / confirmation). Held strongly on the
    /// delegate because Swift 6 terminates a `for await` the instant the
    /// matching continuation deinits — and the coordinator's subscriber
    /// Tasks must survive until the real producers (AgentOrchestrator,
    /// VoiceController, ConfirmationBroker) take over.
    ///
    /// `installVoice` swaps the voice slot to `nil` when `VoiceController`
    /// becomes the live producer. The agent + confirm slots stay dormant
    /// because the orchestrator/broker do not yet emit through these
    /// streams — they drive HudState via the broadcaster fan-out.
    var dormantAgentContinuation: AsyncStream<AgentHudIntent>.Continuation?
    var dormantVoiceContinuation: AsyncStream<VoiceHudIntent>.Continuation?
    var dormantConfirmContinuation: AsyncStream<ConfirmHudIntent>.Continuation?

    // MARK: - Orch→replay seam + MCP runtime

    /// Bounded fan-in channel carrying `ReplayEnvelope`s from the MCP
    /// observer (producer) to the on-disk `ReplayLog` (consumer).
    /// Capacity 2048 + `.dropOldest` matches AGENT-10's tokenDelta-class
    /// policy: lossy under saturation, freshness > completeness.
    ///
    /// Held strongly so it doesn't deinit before either side attaches —
    /// the producer is created lazily inside `MCPRuntimeWiring.build`
    /// (step 10 of the bootstrap chain) and the consumer is the drain
    /// Task in `applicationWillFinishLaunching` step 9.
    /// (audit trail: Plan 05-05 / ME-04; CR-02 REVIEW 05 wired
    /// producer + consumer end-to-end.)
    var orchToReplayChannel: BoundedAsyncChannel<ReplayEnvelope>?

    /// On-disk audit log opened at boot. The orch→replay drain Task writes
    /// `ReplayEvent`s here; held strongly so it outlives the drain Task.
    /// Pre-CR-02, the observer wrote into a `ReplayLog` that
    /// `MCPRuntimeWiring.build` constructed and dropped on return — the
    /// log was effectively write-only-to-`/dev/null`.
    /// (audit trail: CR-02 REVIEW 05.)
    var replayLog: ReplayLog?

    /// Live MCP composite (broker + presenter + observer + dispatcher).
    /// Held strongly so the full dispatch chain stays alive for the
    /// process lifetime. Constructed inside `mcpInstallTask`.
    /// (audit trail: CR-02 REVIEW 05.)
    var mcpRuntime: MCPRuntime?

    /// Builds the `MCPRuntime`. Spawned at the top of the install chain so
    /// `agentInstallTask` can `await` it before `installAgent` runs — MCP
    /// runtime build is ~1s because each helper (`mcp-time`,
    /// `mcp-clipboard`, `mcp-applescript`) spawns a child process. Pre-gate
    /// every cold launch showed `installAgent: deps not ready — skipping`
    /// arriving ~900 ms before `MCPRuntime built`, leaving the orchestrator
    /// + broadcaster + every downstream subscriber dormant for the rest of
    /// the process. The gate (Phase E follow-up) closes that race.
    private var mcpInstallTask: Task<Void, Never>?

    // MARK: - Boot health (Round 2/3/4)

    /// Owns the live `BootHealthSnapshot`. Round 3's Status menu reads from
    /// here and re-probes via `runAll()` on open. Constructed eagerly so
    /// `lastSnapshot()` is queryable even before the first probe sweep —
    /// the menu can render `.unknown` rows instead of crashing on nil.
    let bootHealthOrchestrator = BootHealthOrchestrator()

    /// Tail of the install chain. Awaits every other install Task
    /// (transitively, via `selfKnowledgeInstallTask`), registers concrete
    /// probes against the now-live actors, then runs the first sweep.
    /// Subsequent sweeps are user-driven from the Status menu.
    private var bootHealthTask: Task<Void, Never>?

    /// Lazy `StatusPanel` — Round 3 surface. Constructed on first menu
    /// click; kept alive across closes via `isReleasedWhenClosed = false`
    /// so the SwiftUI model state survives the panel cycling.
    private var statusPanel: StatusPanel?

    /// Drains `orchToReplayChannel` into `replayLog`. Pre-CR-02 this Task
    /// `for await _ in channel`'d into `/dev/null` and the channel had no
    /// producer either — ME-04's contract was structurally unverifiable
    /// in production code.
    /// (audit trail: Plan 05-05 / CR-02 REVIEW 05.)
    var orchToReplayDrainTask: Task<Void, Never>?

    // MARK: - Voice subsystem
    //
    // Wake-word DAG, VAD, STT, TTS, mic graph. Every property here is held
    // strongly so the subsystem outlives `applicationWillFinishLaunching`.
    // `voiceController` is wired in `installVoice` which runs on a
    // background Task after launch (gated behind `agentInstallTask`).
    // The `dormantVoiceContinuation` slot above is swapped to `nil` once
    // `VoiceController` becomes the live producer.

    /// End-to-end voice pipeline actor — owns the wake-word → VAD → STT →
    /// orchestrator → TTS loop and the HUD state it implies. Nil until
    /// `installVoice` runs and finds models + mic permission.
    var voiceController: VoiceController?

    /// Push-to-talk hotkey binding. Unbound at launch; the wizard /
    /// settings UI rebinds it when the user sets a shortcut. (VOICE-13.)
    var pushToTalk: PushToTalk?

    /// Menu-bar wake-word mute toggle. Mirrors the `disablePresence`
    /// toggle on the same context menu. (VOICE-12.)
    var muteWakeWord: MuteWakeWord?

    /// Owns the live `AVAudioEngine` audio graph — opened in `installVoice`
    /// so mic samples flow into the wake-word DAG. Held strongly because
    /// the actor's tap closures retain the ring buffer; if this property
    /// goes nil, wake-word inference reads an empty ring forever.
    /// (audit trail: 2026-05-03 voice audit fix / Track B-4 — production
    /// was never constructing this, so wake word never fired.)
    var audioGraphOwner: AudioGraphOwner?

    /// Drains `AudioGraphOwner.degradationStream` into
    /// `voiceController.handleAECUnavailable()` so VOICE-09 fallback
    /// banners surface natively. Cancelled on shutdown.
    var audioGraphDegradationTask: Task<Void, Never>?

    /// Drains `AudioGraphOwner.rebuildStream`; when an `aec=on` rebuild
    /// succeeds, asks the controller to dismiss the AEC banner.
    var audioGraphRebuildTask: Task<Void, Never>?

    /// Constructs + starts the voice subsystem. Held strongly so the
    /// async setup isn't cancelled prematurely. Awaits
    /// `agentInstallTask?.value` first (WARNING-5 — `installVoice`'s
    /// adapters require the live `agentOrchestrator` and
    /// `turnTranscriptStore`).
    var voiceInstallTask: Task<Void, Never>?

    /// Registers the four self-knowledge MCP tools (`list_audio_devices`,
    /// `get_active_audio_route`, `get_self_state`, `list_camera_devices`)
    /// into the shared `inProcessToolRegistry`. Spawned AFTER
    /// `voiceInstallTask` because `AudioGraphRouteAdapter` needs the live
    /// `audioGraphOwner`. (Plan 10-01.)
    var selfKnowledgeInstallTask: Task<Void, Never>?

    /// Process-start timestamp captured at object construction. `get_self_state`
    /// reports APP uptime against this instant — NOT host uptime via
    /// `ProcessInfo.systemUptime`, which would lie after a sleep/wake cycle.
    /// (Plan 10-01 / D-11.)
    let launchInstant: Date = Date()

    // MARK: - Memory subsystem

    /// `MemoryStore` opened against
    /// `~/Library/Application Support/Jarvis/jarvis.db`. After the
    /// 2026-05-11 D-5/D-6 closure this property is effectively non-nil at
    /// runtime — `installMemory` calls `NSApp.terminate(nil)` if
    /// `MemoryStore.init` throws. The optional remains for the
    /// pre-`installMemory` window and for XCTest hosts that skip install.
    var memoryStore: MemoryStore?

    /// Flag splitting "store unavailable" from "store ok, search degraded".
    /// Vec0 is statically linked today via `CSQLiteVec`, so search is
    /// always available when the store opens — this flag stays `true` for
    /// the lifetime of a healthy boot. Kept on the type because a future
    /// ops plan may ship a custom libsqlite3 with runtime extension
    /// loading; under that variant, MemoryStore can open without vec0 and
    /// this flag splits from `memoryStore != nil`.
    /// (audit trail: Track-D D-1; semantics unchanged after D-5/D-6.)
    var memorySearchAvailable: Bool = false

    /// Background memory-extraction orchestrator. Drains a bounded
    /// `AsyncChannel(capacity: 32, .dropOldest)` one job at a time so a
    /// stalled 32B-model extraction never back-pressures `.turnEnd`
    /// (MEM-06).
    ///
    /// Constructed even when `memoryStore` is nil. The `applyOp` closure
    /// no-ops on writes when there's no store, so the extractor →
    /// coordinator chain still runs end-to-end (the LLM still sees the
    /// conversation, decides ADD/UPDATE/NOOP) — visible via system log
    /// rather than Phase-7-era silent dormancy.
    /// (audit trail: Plan 07-02 / Track-D D-1.)
    var memoryExtractionOrchestrator: MemoryExtractionOrchestrator?

    /// Subscribes to `AgentOrchestrator.events`; on `.turnEnd(.endTurn)`
    /// enqueues an `ExtractionJob` into `memoryExtractionOrchestrator`.
    /// Held strongly so the subscriber Task it spawns isn't cancelled
    /// prematurely. Constructed even when `memoryStore` is nil — see
    /// `memoryExtractionOrchestrator` for rationale.
    var memoryExtractionCoordinator: MemoryExtractionCoordinator?

    /// Shared in-process tool registry. Three install sites must register
    /// tools INTO the same instance:
    ///   1. `installMCP` — hands it to `MCPRuntimeWiring.build` so the
    ///      dispatch composite knows where to route in-process tool calls.
    ///   2. `installMemory` — registers `search_memory` + `forget_fact`.
    ///   3. `installSelfKnowledgeTools` — registers `get_self_state`,
    ///      `list_audio_devices`, `get_active_audio_route`,
    ///      `list_camera_devices`, `get_memory_stats`.
    ///
    /// Eagerly default-initialized at declaration (never nil after the
    /// delegate is constructed) so all three Tasks see the same actor
    /// reference regardless of who wins the parallel-spawn race. Without
    /// this, `installMemory` would build a second registry that the
    /// orchestrator's dispatch composite never sees.
    ///
    /// Registration is gated per dispatcher availability:
    ///   - `forget_fact` registers when `memoryStore != nil` (writes need DB).
    ///   - `search_memory` registers when `memorySearchAvailable == true`
    ///     (reads need both DB and vec0).
    ///
    /// (audit trail: Plan 10-02c / B-01b — dispatch routing bug; before
    /// this, `installMemory` was building a second registry that the
    /// orchestrator never saw.)
    var inProcessToolRegistry: InProcessToolRegistry? = InProcessToolRegistry()

    /// Builds + starts the memory subsystem. See `installMemory` for the
    /// six-step flow it executes.
    var memoryInstallTask: Task<Void, Never>?

    // MARK: - Vision subsystem

    /// Live `AVCaptureSession` adapter. Owns camera hardware claim + frame
    /// production. Surfaces TCC denial / mid-session revocation through
    /// `degradationStream` for the banner watcher.
    var captureSession: CameraCapture?

    /// Per-frame presence inference (face count + glance state).
    /// Constructs and owns the single `PresenceSignalBus` instance — only
    /// `PresenceMonitor` is allowed to call the bus's `internal init`.
    var presenceMonitor: PresenceMonitor?

    /// The SINGLE `PresenceSignalBus` reference, shared by reference
    /// (Sendable struct wrapping an `AsyncStream`) between two read-only
    /// consumers: `ContextBuilder` (system-prompt enrichment) and
    /// `HudStateCoordinator` (subtle ring indicator).
    ///
    /// The bus must have ZERO subscribers in `JarvisTTS` or any code path
    /// reaching `AgentOrchestrator.runTurn` / `cancelAndSubmit` —
    /// presence is an ambient signal, not a turn input. Enforced by
    /// `scripts/check-presence-vision-isolation.sh` and
    /// `PhaseSevenGrepGateTests`.
    /// (audit trail: VISION-03 / D-10.)
    var presenceSignalBus: PresenceSignalBus?

    /// Menu-bar toggle for ambient presence. Mirrors `muteWakeWord` on the
    /// same context menu. Disabling presence does NOT disable frame-attach
    /// (the explicit "look at this" path stays live). (D-12.)
    var disablePresence: DisablePresence?

    /// T1/T2/T3 vision routing ladder. Passed into `AgentOrchestrator` at
    /// construction so image-bearing turns hit the pre-stream branch +
    /// post-response escalation hook. T2 is currently a `MissingT2Provider`
    /// that surfaces unavailability as an explicit error rather than
    /// silently falling back to T1.
    /// (audit trail: Plan 07-05 / Plan 09-02 D-01 / Track-C 4.)
    var visionRouter: VisionRouter?

    /// Frame-attach controller. Owns the dual-trigger ingest path (HUD
    /// camera-icon button + matched phrase) and the D-15
    /// SOLE-emission-site discard invariant. Nil until `installVision`
    /// completes; the broadcaster's frame-attach release subscriber drives
    /// `onAssistantTurnComplete()` after every image-bearing `.turnEnd`.
    /// (audit trail: Plan 09-02 / D-15.)
    var frameAttachController: FrameAttachController?

    /// Drains the broadcaster's `.frameAttach` priority subscription. On
    /// `.turnEnd` for an image-bearing turn (per
    /// `agentOrchestrator.turnHadImage`), calls
    /// `frameAttachController.onAssistantTurnComplete()` to release the
    /// captured frame's in-memory bytes. (D-16.)
    private var frameAttachReleaseTask: Task<Void, Never>?

    /// Surfaces TCC denial / mid-session revocation as HUD banners (S-4
    /// graceful denial). Drains `CameraCapture.degradationStream`.
    var cameraDegradationTask: Task<Void, Never>?

    /// Builds + starts the vision subsystem. Spawned BEFORE `agentInstallTask`
    /// because the orchestrator constructor takes `visionRouter` and the
    /// broadcaster's frame-attach release subscriber needs
    /// `frameAttachController` — both populated by `installVision`.
    var visionInstallTask: Task<Void, Never>?

    // MARK: - Agent subsystem

    /// `ConfigStore` built from launch + per-turn snapshots in
    /// `applicationWillFinishLaunching`. Held strongly so `installAgent`
    /// can hand it to the `AgentOrchestrator` constructor and so per-turn
    /// reads from the boot-health + self-knowledge probes hit the same
    /// authoritative store.
    private var configStore: ConfigStore?

    /// Live `AgentOrchestrator`. Held strongly so the actor + its
    /// `events` channel + the broadcaster's drain Task all outlive
    /// launch. Nil until `installAgent` completes.
    private var agentOrchestrator: AgentOrchestrator?

    /// Single fan-out drain over `agentOrchestrator.events`. Six
    /// subscribers attach in `installAgent` (memory, transcript,
    /// devOverlay, frameAttach, voice, bus). The broadcaster's
    /// per-subscriber priority + protection matrix is what makes the
    /// drop-eligible classification of `.tokenDelta` safe.
    /// (audit trail: D-05 / D-08.)
    private var eventBroadcaster: OrchestratorEventBroadcaster?

    /// Per-turn `(userText, assistantText)` accumulator. The single source
    /// of truth for `lookupTurnContent` — the transcript subscriber feeds
    /// the assistant side from `.tokenDelta` and `handleChatSubmit` /
    /// `handleChatCancelAndSubmit` append the user side at submit time.
    /// (audit trail: BLOCKER-1 source-of-truth fix.)
    private var turnTranscriptStore: TurnTranscriptStore?

    /// Builds + starts the agent subsystem. Awaits `memoryInstallTask`,
    /// `visionInstallTask`, and `mcpInstallTask` first because
    /// `installAgent` needs each of their products at construction time.
    private var agentInstallTask: Task<Void, Never>?

    /// Drains the broadcaster's `memory` priority subscription into
    /// `MemoryExtractionCoordinator`. Forms the `turnContent` lookup
    /// closure that reads from `turnTranscriptStore` + persists completed
    /// turns into the `turns` table.
    private var memoryEventSubscriberTask: Task<Void, Never>?

    /// Drains the broadcaster's `transcript` priority subscription —
    /// appends assistant-side `.tokenDelta` text into the
    /// `turnTranscriptStore`. (BLOCKER-1 source-of-truth feeder.)
    private var transcriptSubscriberTask: Task<Void, Never>?

    /// Drains the broadcaster's `devOverlay` priority subscription into
    /// `DevSnapshotEmitter`. Lossy by design — the DevOverlay is
    /// observational; the emitter's output channel is `.dropOldest`.
    /// Pre-fix this drain was `for await _ in …`, which is why the panel
    /// rendered zeros from P4 onward.
    /// (audit trail: 2026-05-12 dev-overlay-end-to-end Slice 2.)
    private var devOverlaySubscriberTask: Task<Void, Never>?

    /// Aggregates `OrchestratorEvent` into `DevSnapshot`s for the
    /// DevOverlay window. Constructed in `installAgent` once the
    /// broadcaster is alive; `toggleDevOverlay` hands a reference to the
    /// lazy `DevOverlayWindow` so its `DevOverlayBridge` can subscribe to
    /// `emitter.output`.
    private var devSnapshotEmitter: DevSnapshotEmitter?

    /// Voice-path bridge into `AgentOrchestrator`. Constructed in
    /// `installVoice` (after the orchestrator exists) and held here so the
    /// broadcaster's `voice` subscriber drain can call its
    /// `emitTurnEnded` / `emitError` hooks. (Plan 09-04.)
    private var voiceOrchestratorAdapter: VoiceOrchestratorAdapter?

    /// Stored handle to the wake-word DAG so `WakeWordBootHealthProbe`
    /// (audit-2026-05-12 P1-2 / Issue #33) can query `isFeedArmed`.
    /// Nil before `installVoice` succeeds (model files missing, etc.).
    private var wakeWordDAG: WakeWordDAG?

    /// Stored handle to the production TTS adapter so
    /// `TTSBootHealthProbe` can query whether a real `TTSEngineActor`
    /// is wired. Nil before `installVoice` succeeds.
    /// (audit-2026-05-12 P1-2 / Issue #33.)
    private var voiceTTSAdapter: VoiceTTSAdapter?

    /// Drains the broadcaster's `.voice` priority subscription. Maintains
    /// a per-turn assistant-text accumulator gated by
    /// `agentOrchestrator.turnSourceWasVoice` — text-originated turns
    /// MUST NOT drive `VoiceController` back to `.idle` from `.listening`,
    /// because that would silently break voice for any user who types
    /// while talking. (audit trail: Plan 09-04 / BLOCKER-2.)
    private var voiceEventTranslatorTask: Task<Void, Never>?

    /// Drains the broadcaster's `.bus` priority subscription and forwards
    /// `.tokenDelta` chunks into `outboundBatcher.postToken(_:)` so they
    /// reach the JS-side HUD chat panel. Without this subscriber, the
    /// orchestrator emits tokens that never leave Swift — the chat panel
    /// renders an empty `chatEvents` array forever.
    /// (audit trail: Phase E follow-up / BLOCKER-INT-2 from
    /// `.planning/v0.12.0-MILESTONE-AUDIT.md`.)
    private var busSubscriberTask: Task<Void, Never>?

    /// 30 Hz outbound coalescer with the `WebviewBridge` as its sink. Used
    /// by `VoiceBusEmitterAdapter` (audio-level RMS → RingMesh pulse) AND
    /// by the bus-forwarding subscriber (tokenDelta → chat panel).
    /// Constructed in `installAgent` so the bus forwarder works even when
    /// the voice DAG short-circuits on missing models. (Plan 09-04 +
    /// Phase E hoist.)
    private var outboundBatcher: OutboundBatcher?

    /// Filename of the HTML entry the webview loads. Production value is
    /// `"index"` (the R3F bundle); `installBus` assigns it on construction.
    /// Test seam — XCTest asserts the post-install value to confirm the
    /// handler loaded the R3F bundle and not 02-03's `bus-harness.html`.
    var webviewEntryFilename: String = "index"

    private var systemLogger: Logger?
    private var bridgeNavigationDelegate: BridgeNavigationDelegate?

    // MARK: - Launch chain

    /// Bootstrap entry point. Executes the 16-step install chain documented
    /// in the class docstring's "Install order" section above. Two hard-block
    /// branches early-return before any subsystem touches state:
    ///
    /// 1. **Entitlement gate** — if `JarvisEntitlementsVerified` is missing
    ///    or `false`, the production `onEntitlementFailure` presents the
    ///    "Jarvis can't start" modal via `TCCAlertService` and terminates.
    ///    The XCTest-host override is silent so test bundles still load.
    /// 2. **Config malformed** — `ConfigError` (or any throw from
    ///    `configLoader`/`configWriter`) routes through `Redact.apply`
    ///    before logging (a malformed config may carry an inlined API key
    ///    that would otherwise hit `~/Library/Logs/Jarvis/system.log` as
    ///    plaintext — WR-02), then hard-blocks + terminates.
    ///
    /// Everything after step 3 is fail-soft via banners + degraded
    /// subsystems, except `installMemory`'s `MemoryStore.init` failure
    /// path which also terminates (D-5/D-6 closure: no silent forgetting).
    ///
    /// The install order is locked by `scripts/check-install-order.sh`:
    /// vision → agent → voice, and `voiceInstallTask` MUST `await
    /// agentInstallTask?.value`. See the class docstring's DAG.
    func applicationWillFinishLaunching(_ notification: Notification) {
        // 1. Logging bootstrap. S-8 requires exactly one call site; tests
        //    inject a no-op to keep repeated XCTest runs from tripping it.
        loggingBootstrap()
        systemLogger = Logger(label: JarvisLogChannel.system.rawValue)
        systemLogger?.info("Jarvis launching — Phase 1 scaffold")

        // 2. Entitlement hard-block. `defaultOnEntitlementFailure`
        //    short-circuits to a no-op when `XCTestConfigurationFilePath`
        //    is set so the bundled process doesn't terminate before tests
        //    load. Tests that want the full bootstrap chain inject an
        //    `EntitlementYes` probe and call this method directly.
        guard entitlementProbe.isVerified() else {
            systemLogger?.critical("JarvisEntitlementsVerified missing/false — hard-blocking")
            onEntitlementFailure()
            return
        }

        // 3. Config load (or first-run defaults write). Redact error text
        //    before logging — a malformed config that inlines a secret
        //    would otherwise land in OSLog (where `OSLogHandler` skips
        //    redaction by design) as plaintext. (WR-02.)
        let configURL = configFileURL()
        let snapshots: (LaunchSnapshot, PerTurnSnapshot)
        do {
            if FileManager.default.fileExists(atPath: configURL.path) {
                snapshots = try configLoader(configURL)
            } else {
                snapshots = try configWriter(configURL)
            }
        } catch let e as ConfigError {
            let description = Redact.apply(String(describing: e))
            systemLogger?.critical("Config malformed: \(description)")
            TCCAlertService.presentHardBlock(
                title: "Jarvis can't start",
                informativeText: "Your config file couldn't be read. \(description). Details in ~/Library/Logs/Jarvis/system.log."
            )
            NSApp.terminate(nil)
            return
        } catch {
            let description = Redact.apply(error.localizedDescription)
            systemLogger?.critical("Config load failed: \(description)")
            TCCAlertService.presentHardBlock(
                title: "Jarvis can't start",
                informativeText: "Config load failed: \(description)"
            )
            NSApp.terminate(nil)
            return
        }
        // Wrap the snapshots in a `ConfigStore` actor so `installAgent`
        // can pass it into the orchestrator constructor and so every
        // probe / self-knowledge tool reads the same authoritative store.
        let configStore = ConfigStore(launch: snapshots.0, initial: snapshots.1)
        self.configStore = configStore

        // 4. AppKit surfaces.
        installMenuBar()
        installHUDPanel()
        installBannerPanel()

        // 4.5 Bus wiring — construct the `WebviewBridge` around the HUD's
        //     `WKWebView`, install the `WKUserScript` at document-start in
        //     the isolated `JarvisBusWorld`, start the single-writer
        //     `HudStateCoordinator`, and load the R3F bundle's
        //     `index.html` so the handshake kicks off. See `installBus`
        //     for the seven-step sequence.
        installBus()

        // 5. Keychain probe. Banner suppression: when the API key is
        //    missing, the wizard (step 8) is going to ask for it —
        //    enqueuing `.keychainEmpty` here would stack a "No API key
        //    configured" HUD banner on top of the wizard's own apiKey
        //    stage. The actual `.keychainEmpty` enqueue happens in step
        //    8b, gated on `!willOpenWizard`.
        let apiKeyStored: Bool
        do {
            _ = try keychainStore.get(.anthropic)
            apiKeyStored = true
        } catch KeychainError.itemNotFound {
            apiKeyStored = false
        } catch {
            systemLogger?.error("Keychain fetch error: \(String(describing: error))")
            apiKeyStored = false
        }

        // 6. Input Monitoring — query-only via `IOHIDCheckAccess`. We do
        //    NOT call `requestListenEventAccess` here for two reasons:
        //      (a) it would fire a TCC dialog outside the wizard's TCC
        //          stage, surprising the user before they've even seen
        //          the wizard's explainer copy; and
        //      (b) the wizard already owns the prompt (with the System
        //          Settings fallback path).
        //    Like the keychain probe, the banner enqueue is deferred to
        //    step 8b so it doesn't stack on top of the wizard.
        let inputMonitoringGranted = hidProbe.isListenEventAccessGranted()

        // 7. Hotkey binder. Unbound at launch — the wizard / Settings UI
        //    binds a shortcut later.
        hotkeyBinder = HotkeyBinder()

        // 8. Wizard state + first-launch open.
        let state = WizardState(keychain: keychainStore)
        wizardState = state
        wizardController = OnboardingWizardController(state: state)
        settingsWindowController = SettingsWindowController(state: state)
        let willOpenWizard = !apiKeyStored
        if willOpenWizard {
            openWizard(firstLaunch: true)
        }

        // 8b. Banner enqueue, now that the wizard's open/closed decision
        //     is settled. Only enqueue missing-prerequisite banners when
        //     the wizard ISN'T going to address them — avoids stacking
        //     redundant banners on top of a wizard asking for the same
        //     thing. (See steps 5 + 6.)
        if !apiKeyStored && !willOpenWizard {
            bannerCoordinator?.enqueue(.keychainEmpty)
        }
        if !inputMonitoringGranted && !willOpenWizard {
            bannerCoordinator?.enqueue(.inputMonitoringDenied)
        }

        // 9. Orch→replay seam. Allocate the 2048-capacity .dropOldest
        //    channel, open the on-disk `ReplayLog`, and spawn the drain
        //    task that writes drained envelopes to the log. AGENT-10's
        //    four-seam contract is now exercised by production traffic:
        //    the observer (created lazily inside `MCPRuntimeWiring.build`,
        //    next step) PRODUCES; this drain task CONSUMES.
        //    (audit trail: Plan 05-05 / ME-04 / CR-02 REVIEW 05.)
        let channel = BoundedAsyncChannel<ReplayEnvelope>(capacity: 2048, policy: .dropOldest)
        orchToReplayChannel = channel
        let replayDBURL = replayDatabaseURL()
        do {
            let log = try ReplayLog(databaseURL: replayDBURL)
            self.replayLog = log
            orchToReplayDrainTask = Task.detached {
                for await envelope in channel {
                    await log.record(envelope.event, for: envelope.turnId)
                }
            }
        } catch {
            systemLogger?.error("CR-02: failed to open ReplayLog at \(replayDBURL.path): \(String(describing: error))")
            // Drain still runs — discards events so the producer doesn't
            // back-pressure. Replay capture is best-effort per OBS-02.
            orchToReplayDrainTask = Task.detached { [weak self] in
                for await _ in channel {
                    _ = self
                }
            }
        }

        // 10. MCP runtime build. Constructs the broker + presenter +
        //     observer + dispatcher composite and the in-process tool
        //     registry it routes to. Helpers may be absent (XCTest hosts,
        //     pre-codesign builds); failure is non-fatal — we log and
        //     proceed without MCP, the same way a missing API key
        //     proceeds without the agent.
        //
        //     The `bus` adapter resolves `outboundBatcher` lazily via a
        //     MainActor closure because the batcher is constructed later
        //     in `installAgent`. Until it exists, tool-card emissions are
        //     dropped — but `ReplayingToolResultObserver` still records
        //     every call so the audit trail isn't lost.
        //     (audit trail: CR-02 REVIEW 05; BLOCKER-INT-1 fix replaced
        //     the previous Null bus adapter.)
        let bundleURL = Bundle.main.bundleURL
        mcpInstallTask = Task { @MainActor [weak self] in
            guard let self = self, let channel = self.orchToReplayChannel else { return }
            let busAdapter = MCPBusGatewayAdapter(resolveBatcher: { [weak self] in
                await MainActor.run { [weak self] in self?.outboundBatcher }
            })
            do {
                // Pass the eagerly-constructed `inProcessToolRegistry` so
                // `MCPRuntimeWiring` wraps the inner `MCPToolDispatcher`
                // with `InProcessAwareToolDispatcher`. Memory tools and
                // the four self-knowledge tools register into THIS same
                // registry from later install steps — the composite's
                // name-routing query reads from the live actor on every
                // dispatch, so late registrations are routable too.
                // (Plan 10-02c / B-01b.)
                let runtime = try await MCPRuntimeWiring.build(
                    bundleURL: bundleURL,
                    bus: busAdapter,
                    replayChannel: channel,
                    turnIDResolver: { nil },  // No live orchestrator yet — observer logs without writing.
                    inProcessRegistry: self.inProcessToolRegistry
                )
                self.mcpRuntime = runtime
                let toolCount = await runtime.client.registeredToolNames().count
                self.systemLogger?.info("MCPRuntime built — \(toolCount) tools")
            } catch {
                self.systemLogger?.warning("MCPRuntime build failed (helpers absent or unsigned?): \(String(describing: error))")
            }
        }

        // 11. Memory install. Spawned BEFORE voice so the extraction
        //     coordinator is subscribed to `AgentOrchestrator.events`
        //     before the first voice-driven turn lands. `MemoryStore.init`
        //     hard-blocks on failure per D-5/D-6 (no silent forgetting).
        memoryInstallTask = Task { @MainActor [weak self] in
            await self?.installMemory()
        }

        // MARK: - Install order: vision → agent → voice (LOCKED)
        //
        // Enforced literally by `scripts/check-install-order.sh`:
        //   - Vision must finish before agent because `installAgent`'s
        //     orchestrator constructor takes `self.visionRouter` and the
        //     broadcaster's frame-attach release subscriber needs
        //     `frameAttachController`.
        //   - Agent must finish before voice because `installVoice`'s
        //     adapters require `self.agentOrchestrator` and
        //     `self.turnTranscriptStore` (both constructed inside
        //     `installAgent`).
        // The gate checks BOTH the literal Task-spawn line order AND the
        // explicit `await self?.agentInstallTask?.value` inside the voice
        // spawn. Removing either trips CI.

        // 12. Vision install. Camera TCC may be undetermined or denied at
        //     first launch; presence + frame-attach degrade gracefully via
        //     the `cameraDegradationTask` banner watcher.
        visionInstallTask = Task { @MainActor [weak self] in
            await self?.installVision()
        }

        // 13. Agent install. Awaits memory + vision + MCP install tasks
        //     because:
        //       - memory: `MemoryExtractionCoordinator` must exist before
        //         the broadcaster's memory subscriber attaches.
        //       - vision: `installAgent` passes `visionRouter:` and
        //         `frameAttachController` into the orchestrator + the
        //         broadcaster's frame-attach release subscriber.
        //       - MCP: `installAgent` short-circuits when `mcpRuntime`
        //         is nil. MCP build is ~1s due to helper child-process
        //         spawn; before this gate landed, every cold launch
        //         showed `installAgent: deps not ready — skipping`
        //         arriving ~900 ms before `MCPRuntime built`, leaving the
        //         orchestrator + broadcaster + ALL six subscribers
        //         dormant for the process lifetime. The
        //         v0.12.0-MILESTONE-AUDIT.md "5 subscribers wired"
        //         finding was static-grep correct but runtime-false
        //         until this gate landed. (Phase E follow-up.)
        agentInstallTask = Task { @MainActor [weak self] in
            await self?.memoryInstallTask?.value
            await self?.visionInstallTask?.value
            await self?.mcpInstallTask?.value
            await self?.installAgent()
        }

        // 14. Voice install. Model files (ORT sessions, Orpheus MLX
        //     weights) may be absent on first launch — failure is
        //     non-fatal (voice degrades gracefully, banner surfaces).
        //     The `dormantVoiceContinuation` slot is replaced with the
        //     real producer once `VoiceController` is live.
        //     Awaits `agentInstallTask` — the real voice adapters require
        //     `agentOrchestrator` and `turnTranscriptStore`.
        voiceInstallTask = Task { @MainActor [weak self] in
            await self?.agentInstallTask?.value
            await self?.installVoice()
        }

        // 15. Self-knowledge tool registration. Runs AFTER voice so the
        //     live `audioGraphOwner` reference is available for
        //     `AudioGraphRouteAdapter`. All queries are read-only
        //     metadata (CoreAudio + AVCaptureDevice) — no TCC prompt.
        //     Every tool registers with `requiresConfirmation: false`
        //     explicitly. (Plan 10-01 / D-10.)
        selfKnowledgeInstallTask = Task { @MainActor [weak self] in
            await self?.voiceInstallTask?.value
            await self?.installSelfKnowledgeTools()
        }

        // 16. Boot-health probe sweep. Awaits the tail of the install
        //     chain so each probe reads the live state of a settled
        //     subsystem. Logs structured per-subsystem lines, enqueues
        //     severity-classified banners, pushes the degradation
        //     summary into the agent, and tints the menu-bar icon by
        //     overall health. (Round 2/3/4.)
        bootHealthTask = Task { @MainActor [weak self] in
            await self?.selfKnowledgeInstallTask?.value
            await self?.runBootHealth()
        }
    }

    /// On-disk replay log path. Lives next to `config.json` under
    /// `~/Library/Application Support/Jarvis/replay.sqlite`.
    /// (audit trail: CR-02 REVIEW 05.)
    private func replayDatabaseURL() -> URL {
        configFileURL().deletingLastPathComponent().appendingPathComponent("replay.sqlite")
    }

    // MARK: - Boot health (Round 2/3/4)

    /// Runs one boot-health sweep against every registered subsystem
    /// probe. Idempotent — safe to call again from the Status panel's
    /// "Re-probe" button (Round 3); the orchestrator's snapshot
    /// overwrites cleanly.
    ///
    /// Four side effects per call:
    ///   1. Register probes the first time (`registeredNames().isEmpty`
    ///      guard handles the Round 3 re-probe case).
    ///   2. Log one structured line per subsystem (parser-friendly
    ///      `key=value` pairs).
    ///   3. Enqueue severity-classified banners for non-ok subsystems.
    ///   4. Push the degradation summary into `AgentOrchestrator` so the
    ///      next turn's system prompt warns the model not to lie about
    ///      dead capabilities (the Toby case), and paint the menu-bar
    ///      icon by overall health.
    ///
    /// Anti-fake-status invariant: every probe MUST report a concrete
    /// status (`.ok`, `.degraded`, `.failed`, `.unknown`). A subsystem
    /// that never installed still runs a probe — it just returns
    /// `.unknown(reason:)`. The orchestrator is not a "best effort"
    /// surface; a missing probe is itself a bug.
    @MainActor
    func runBootHealth() async {
        if await bootHealthOrchestrator.registeredNames().isEmpty {
            await registerBootHealthProbes()
        }
        let snapshot = await bootHealthOrchestrator.runAll()
        emitBootHealthLog(snapshot: snapshot)
        enqueueFailedBootHealthBanners(snapshot: snapshot)
        // The bootHealthTask awaits selfKnowledgeInstallTask which
        // transitively awaits agentInstallTask, so the orchestrator is
        // normally live by the time we get here. The nil-coalesce is
        // belt-and-suspenders against future install-order changes.
        let summary = buildDegradationSummary(snapshot: snapshot)
        if let orchestrator = self.agentOrchestrator {
            await orchestrator.setDegradationSummary(summary)
        }
        // Single-writer-safe: `contentTintColor` lives on the
        // `NSStatusItemButton`, not in `HudState`, so HUD-08 stays intact.
        menuBarController?.applyHealth(snapshot.overallHealth)
    }

    /// Builds the agent-facing "DO NOT promise" preamble from a
    /// boot-health snapshot. Returns `nil` when everything is `.ok` so
    /// the orchestrator's normal system prompt is used verbatim. Keeps
    /// the string well under the 4096-char cache-eligibility boundary
    /// (Opus pitfall #4) so adding it doesn't flip `cache_control`
    /// emission. (Round 4.)
    @MainActor
    func buildDegradationSummary(snapshot: BootHealthSnapshot) -> String? {
        var critical: [(name: String, reason: String)] = []
        var loud: [(name: String, reason: String)] = []
        for health in snapshot.subsystems {
            guard let severity = health.status.severity else { continue }
            let reason = reasonForBanner(health.status)
            switch severity {
            case .critical:
                critical.append((name: health.name, reason: reason))
            case .loud:
                loud.append((name: health.name, reason: reason))
            case .soft:
                continue
            }
        }
        if critical.isEmpty && loud.isEmpty { return nil }

        var lines: [String] = ["CRITICAL — SUBSYSTEMS DEGRADED:"]
        for entry in critical {
            lines.append("- \(entry.name): \(entry.reason) — DO NOT promise to use \(entry.name)")
        }
        for entry in loud {
            lines.append("- \(entry.name): degraded — \(entry.reason)")
        }
        lines.append("Be honest. Do not claim to use tools that are unavailable. Do not pretend memory works if it doesn't.")
        return lines.joined(separator: "\n")
    }

    /// Opens the Status panel (lazy-creates on first click). The panel's
    /// `.task { await model.reprobe() }` SwiftUI modifier fires a fresh
    /// probe sweep on every appearance, so the user always sees live
    /// state — never a stale boot snapshot. (Round 3.)
    @MainActor
    func openStatusPanel() {
        if statusPanel == nil {
            let model = StatusPanelModel(
                orchestrator: bootHealthOrchestrator,
                probeRunner: { [weak self] in
                    await self?.runBootHealth()
                }
            )
            statusPanel = StatusPanel(model: model)
        }
        statusPanel?.present()
    }

    /// Constructs one probe per subsystem and registers it on the
    /// orchestrator. Each register call is awaited inline so the caller
    /// can `runAll()` immediately after and be certain every probe is in
    /// the registry (no fire-and-forget Task race). Subsystems that never
    /// installed get a `DormantSubsystemProbe` that honestly reports
    /// `.unknown` (or `.critical` for memory — silent forgetting is the
    /// loudest possible failure mode).
    ///
    /// Probes registered:
    ///   - **memory** — `MemoryBootHealthProbe` on `MemoryStatsStoreAdapter`,
    ///     same adapter the `get_memory_stats` MCP tool consumes.
    ///   - **anthropic** — `AnthropicBootHealthProbe` — structural keychain
    ///     check, no network.
    ///   - **ollama** — `OllamaBootHealthProbe` — live `/api/tags` against
    ///     the configured base URL.
    ///   - **voice** — `VoiceBootHealthProbe` against `AudioGraphOwner`.
    ///   - **vision** — `VisionBootHealthProbe` — TCC status + device
    ///     enumeration only, no captured actor.
    ///   - **mcp** — `MCPBootHealthProbe` over `MCPRuntime` + the
    ///     in-process registry, because the composite dispatcher routes
    ///     both stdio helpers AND in-process tools.
    ///   - **replay** — `ReplayBootHealthProbe` on DB URL + `replayLog`
    ///     presence.
    ///   - **webview** — `WebviewBootHealthProbe` on `WebviewBridge`
    ///     handshake state.
    @MainActor
    private func registerBootHealthProbes() async {
        let dbURL = configFileURL().deletingLastPathComponent().appendingPathComponent("jarvis.db")
        if let memoryStore = self.memoryStore {
            await bootHealthOrchestrator.register(
                MemoryBootHealthProbe(adapter: MemoryStatsStoreAdapter(store: memoryStore, databaseURL: dbURL))
            )
        } else {
            // Memory dormant = silent forgetting. Critical severity so the
            // banner is non-dismissible and the agent's preamble warns the
            // model not to promise to remember anything.
            await bootHealthOrchestrator.register(DormantSubsystemProbe(
                subsystemName: "memory",
                reason: "MemoryStore.init failed at install (vec0 missing or DB unwritable)",
                severity: .critical
            ))
        }

        await bootHealthOrchestrator.register(
            AnthropicBootHealthProbe(keychain: self.keychainStore)
        )

        // `ConfigStore` is an actor; `launch` is actor-isolated even
        // though it's a `let`. Read it inside the await before registering.
        if let cfg = self.configStore {
            let baseURL = await cfg.launch.ollama.baseURL
            await bootHealthOrchestrator.register(OllamaBootHealthProbe(baseURL: baseURL))
        } else {
            await bootHealthOrchestrator.register(DormantSubsystemProbe(
                subsystemName: "ollama",
                reason: "ConfigStore nil — base URL unknown"
            ))
        }

        await bootHealthOrchestrator.register(
            VoiceBootHealthProbe(audioGraphOwner: self.audioGraphOwner)
        )

        // Three voice-watchdog probes — fill the gap surfaced by
        // audit-2026-05-12 P1-2 / Issue #33. `VoiceBootHealthProbe`
        // alone checked `audioGraphOwner` + `micStatus` + `currentVariant`
        // and reported `ok` even after the wake-word DAG died (P0-1) or
        // TTS was never wired (Track B-3 pre-fix). These probes
        // distinguish "voice is plumbed" from "voice will actually work".
        await bootHealthOrchestrator.register(
            WakeWordBootHealthProbe(isArmed: { [weak self] in
                guard let dag = await MainActor.run(body: { self?.wakeWordDAG })
                else { return nil }
                return await dag.isFeedArmed
            })
        )

        await bootHealthOrchestrator.register(STTBootHealthProbe())

        await bootHealthOrchestrator.register(
            TTSBootHealthProbe(engineAlive: { [weak self] in
                guard let adapter = await MainActor.run(body: { self?.voiceTTSAdapter })
                else { return false }
                return await adapter.hasEngine
            })
        )

        await bootHealthOrchestrator.register(VisionBootHealthProbe())

        await bootHealthOrchestrator.register(
            MCPBootHealthProbe(
                mcpRuntime: self.mcpRuntime,
                inProcessRegistry: self.inProcessToolRegistry
            )
        )

        await bootHealthOrchestrator.register(
            ReplayBootHealthProbe(
                databaseURL: self.replayDatabaseURL(),
                replayLogPresent: self.replayLog != nil
            )
        )

        await bootHealthOrchestrator.register(
            WebviewBootHealthProbe(bridge: self.webviewBridge)
        )
    }

    /// Writes one structured log line per subsystem in the snapshot, plus
    /// a header summarising the `total / .ok / .failed / .degraded /
    /// .unknown` counts. The format is parser-friendly (`key=value` pairs
    /// with quoted values where evidence contains spaces) so a future log
    /// scraper can extract the columns cleanly.
    @MainActor
    private func emitBootHealthLog(snapshot: BootHealthSnapshot) {
        let counts = countByStatus(snapshot.subsystems)
        systemLogger?.info(
            "BootHealth: probed=\(snapshot.subsystems.count) ok=\(counts.ok) degraded=\(counts.degraded) failed=\(counts.failed) unknown=\(counts.unknown)"
        )
        for health in snapshot.subsystems {
            let label = stateLabel(health.status)
            let evidence = health.evidence.replacingOccurrences(of: "\"", with: "\\\"")
            systemLogger?.info(
                "BootHealth: subsystem=\(health.name) state=\(label) latencyMs=\(health.latencyMs) evidence=\"\(evidence)\""
            )
        }
    }

    /// Enqueues one banner per non-ok subsystem, routed by severity:
    ///   - `.critical` → non-dismissible red banner at priority 1, plus a
    ///     `[system] CRITICAL` log line so the system channel reflects it.
    ///   - `.loud`     → dismissible banner at priority 3.
    ///   - `.soft`     → no banner (Status panel only).
    ///
    /// Banner ids are severity-scoped, so re-probing the same subsystem
    /// doesn't spam — the coordinator dedupes on the
    /// `boot-health-{severity}-{subsystem}` key. (Round 4.)
    @MainActor
    private func enqueueFailedBootHealthBanners(snapshot: BootHealthSnapshot) {
        for health in snapshot.subsystems {
            guard let severity = health.status.severity else { continue }
            let reason = reasonForBanner(health.status)
            switch severity {
            case .critical:
                systemLogger?.error("BootHealth: [system] CRITICAL subsystem=\(health.name) reason=\(reason)")
                bannerCoordinator?.enqueue(.bootHealthCritical(subsystem: health.name, reason: reason))
            case .loud:
                bannerCoordinator?.enqueue(.bootHealthLoud(subsystem: health.name, reason: reason))
            case .soft:
                continue
            }
        }
    }

    /// Extracts the reason string from a non-ok status for use in banner
    /// copy. Falls back to `"unknown"` for `.ok` (defensive — the caller
    /// already filters those out via `severity.map`). (Round 4.)
    @MainActor
    private func reasonForBanner(_ status: ProbeStatus) -> String {
        switch status {
        case .ok: return "unknown"
        case .degraded(let r, _), .failed(let r, _), .unknown(let r, _):
            return r
        }
    }

    private func stateLabel(_ status: ProbeStatus) -> String {
        switch status {
        case .ok: return "ok"
        case .degraded: return "degraded"
        case .failed: return "failed"
        case .unknown: return "unknown"
        }
    }

    private func countByStatus(_ subsystems: [SubsystemHealth]) -> (ok: Int, degraded: Int, failed: Int, unknown: Int) {
        var ok = 0; var degraded = 0; var failed = 0; var unknown = 0
        for h in subsystems {
            switch h.status {
            case .ok: ok += 1
            case .degraded: degraded += 1
            case .failed: failed += 1
            case .unknown: unknown += 1
            }
        }
        return (ok, degraded, failed, unknown)
    }

    /// Cancels every long-lived Task and shuts down every subsystem actor
    /// the delegate owns. Each cancellation is explicit (not relying on
    /// process exit to GC them) because long-lived subscribers must not
    /// outlive the process — a stray `for await` Task that survives
    /// teardown will keep the actor alive and prevent clean shutdown
    /// reporting in the `at_exit` log line.
    ///
    /// Order matters lightly: hotkey unbind first so the global event
    /// monitor releases its TCC claim cleanly; install Tasks next so any
    /// in-flight install sees `Task.isCancelled` and exits; subscriber
    /// Tasks last so the broadcaster's drain finishes cleanly. The
    /// per-subsystem `shutdown()`/`stop()`/`cancel()` calls run as
    /// detached Tasks because we're already on `@MainActor` and the
    /// subsystems live on their own actors.
    func applicationWillTerminate(_ notification: Notification) {
        hotkeyBinder?.unbind()
        // Probes are short-lived but a re-probe triggered from Round 3's
        // Status menu can still be mid-flight when the user quits.
        bootHealthTask?.cancel()
        orchToReplayDrainTask?.cancel()
        voiceInstallTask?.cancel()
        audioGraphDegradationTask?.cancel()
        audioGraphRebuildTask?.cancel()
        if let owner = audioGraphOwner {
            Task { await owner.shutdown() }
        }
        if let vc = voiceController {
            Task { await vc.shutdown() }
        }
        memoryInstallTask?.cancel()
        visionInstallTask?.cancel()
        cameraDegradationTask?.cancel()
        if let monitor = presenceMonitor {
            Task { await monitor.cancel() }
        }
        if let extractor = memoryExtractionOrchestrator {
            Task { await extractor.shutdown() }
        }
        if let coord = memoryExtractionCoordinator {
            Task { await coord.stop() }
        }
        if let capture = captureSession {
            Task { await capture.shutdown() }
        }
        agentInstallTask?.cancel()
        memoryEventSubscriberTask?.cancel()
        transcriptSubscriberTask?.cancel()
        devOverlaySubscriberTask?.cancel()
        frameAttachReleaseTask?.cancel()
        voiceEventTranslatorTask?.cancel()
        busSubscriberTask?.cancel()
        if let broadcaster = eventBroadcaster {
            Task { await broadcaster.stop() }
        }
    }

    // MARK: - Voice install

    /// Constructs and starts the voice subsystem (wake word → VAD → STT
    /// → orchestrator → TTS). Runs on the voice install Task after
    /// `agentInstallTask` completes; the agent + transcript dependencies
    /// it captures don't exist any earlier.
    ///
    /// Fail-soft policy: model files and hardware are best-effort. Each
    /// of these failures degrades voice to dormant + a banner, but the
    /// rest of the app keeps running:
    ///   - ORT models missing → no wake word.
    ///   - Silero models missing → no VAD.
    ///   - Mic permission denied → no audio graph.
    ///   - Audio graph fails to open → no listening loop.
    ///
    /// Step sequence:
    ///   1. Construct `OpenWakeWordSession` + `SileroVAD` + `WakeWordDAG`.
    ///   2. Construct `AudioGraphOwner` and spawn the degradation +
    ///      rebuild consumer Tasks BEFORE `open()`. `open()` may
    ///      immediately emit `.aecUnavailable` on its retry-with-aec=off
    ///      path; the consumers must be ready.
    ///   3. Request mic permission (`AVCaptureDevice.requestAccess`) so
    ///      first-launch surfaces the prompt — without this the wizard's
    ///      "request at first use" contract is violated and the app
    ///      receives a silent input stream.
    ///   4. Open the graph; hand its ring buffer to the wake-word DAG.
    ///   5. Construct the production adapter triad
    ///      (`VoiceOrchestratorAdapter`, `VoiceTTSAdapter`,
    ///      `VoiceBusEmitterAdapter`).
    ///   6. Construct `VoiceController` against `dormantVoiceContinuation`
    ///      (the coordinator is already subscribed to it). Swap the
    ///      continuation slot to `nil` so the controller is now the sole
    ///      producer.
    ///   7. Wire `PushToTalk` + `MuteWakeWord` + `AudioLevelEmitter`.
    ///   8. Call `voiceController.start()`.
    @MainActor
    private func installVoice() async {
        // Require dormant continuation — it's our connection to HudStateCoordinator.
        guard let voiceCont = dormantVoiceContinuation else {
            systemLogger?.warning("installVoice: dormantVoiceContinuation is nil — voice subsystem not installed")
            return
        }

        // Model directories from the app bundle's Resources/Models/ directory.
        // These are absent in Debug builds without the model download step.
        let bundleModels = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Resources/Models", isDirectory: true)

        let openWakeWordModelDir = bundleModels.appendingPathComponent("openWakeWord", isDirectory: true)
        let sileroModelDir = bundleModels.appendingPathComponent("silero", isDirectory: true)

        // Construct OpenWakeWordSession (requires ORT model files).
        let wakeWordSession: OpenWakeWordSession
        do {
            wakeWordSession = try OpenWakeWordSession(modelDir: openWakeWordModelDir)
        } catch {
            systemLogger?.warning("installVoice: OpenWakeWordSession init failed (models absent?): \(String(describing: error))")
            // Non-fatal: voice subsystem skipped; dormant continuation retained.
            return
        }

        // Construct SileroVAD (requires ORT model files).
        let sileroVAD: SileroVAD
        do {
            sileroVAD = try SileroVAD(modelDir: sileroModelDir)
        } catch {
            systemLogger?.warning("installVoice: SileroVAD init failed: \(String(describing: error))")
            return
        }

        let wakeWordDAG = WakeWordDAG(session: wakeWordSession)
        self.wakeWordDAG = wakeWordDAG  // expose to BootHealthProbe (Issue #33)

        // The degradation + rebuild consumer Tasks MUST be spawned before
        // `graphOwner.open()` because `open()` may immediately yield
        // `.aecUnavailable` on its retry-with-aec=off path (VOICE-09) —
        // dropping that first event on the floor leaves voice without
        // banners until the second AEC failure.
        // (audit trail: 2026-05-03 voice audit / Track B-4 — production
        // was never constructing AudioGraphOwner; the wake-word DAG read
        // an empty ring forever.)
        let (degradationStream, degradationCont) = AsyncStream<DegradationReason>.makeStream()
        let (rebuildStream, rebuildCont) = AsyncStream<RebuildEvent>.makeStream()

        let graphOwner = AudioGraphOwner(
            degradationContinuation: degradationCont,
            rebuildContinuation: rebuildCont
        )
        self.audioGraphOwner = graphOwner

        // Spawn degradation consumer — fires `.aecUnavailable` into the
        // VoiceController's banner path. VoiceController may not exist yet
        // when the first event arrives (open() runs below), so the consumer
        // resolves the controller lazily on each event.
        audioGraphDegradationTask = Task { @MainActor [weak self] in
            for await reason in degradationStream {
                guard case .aecUnavailable = reason else { continue }
                if let vc = self?.voiceController {
                    await vc.handleAECUnavailable()
                }
            }
        }

        // Spawn rebuild consumer — once an aec=on rebuild succeeds we ask the
        // controller to dismiss the banner. The owner only emits
        // `.reconfiguring(reason:)` on each rebuild start; the variant flip
        // is observable via `await graphOwner.currentVariant`. We poll the
        // variant after each rebuild event.
        //
        // Re-arm the wake-word DAG against the new ring on every rebuild.
        // The `cancelInFlight` slot (set below) calls `stopFeed()` to halt
        // the old feed task; the public `wakeWordStream` survives, but the
        // DAG has no producer until we call `start(ring:)` again. Without
        // this, wake-word stops working after any device-change /
        // mic-regrant / ring-overflow event.
        // (audit-2026-05-12 P0-1 / Issue #28.)
        audioGraphRebuildTask = Task { @MainActor [weak self, wakeWordDAG] in
            for await _ in rebuildStream {
                guard let self else { return }
                if let newRing = await self.audioGraphOwner?.ringBuffer {
                    await wakeWordDAG.start(ring: newRing)
                }
                let variant = await self.audioGraphOwner?.currentVariant
                if case .aecOn = variant {
                    await self.voiceController?.handleAECRestored()
                }
            }
        }

        // macOS does not deterministically surface the microphone prompt
        // from `AVAudioEngine` alone; without an explicit
        // `AVCaptureDevice.requestAccess(for: .audio)` the app receives a
        // silent input stream and the wizard's "request at first use"
        // contract is violated. This is the single point where the voice
        // loop first claims the mic, so it's the right place to ask.
        // (audit trail: 2026-05-06 voice-permission fix.)
        let micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        let micGranted: Bool
        switch micStatus {
        case .authorized:
            micGranted = true
        case .notDetermined:
            systemLogger?.info("installVoice: requesting mic permission (.notDetermined)")
            micGranted = await AVCaptureDevice.requestAccess(for: .audio)
            systemLogger?.info("installVoice: mic permission \(micGranted ? "granted" : "denied")")
        case .denied, .restricted:
            systemLogger?.warning("installVoice: mic permission \(String(describing: micStatus)) — voice loop dormant; user must grant in System Settings")
            micGranted = false
        @unknown default:
            micGranted = false
        }

        guard micGranted else {
            audioGraphDegradationTask?.cancel()
            audioGraphRebuildTask?.cancel()
            self.audioGraphOwner = nil
            return
        }

        // Open the graph. Failure here is non-fatal: voice degrades to
        // dormant + banner, the rest of the app keeps running. The owner
        // itself emits `.aecUnavailable` on its retry path, so we only need
        // to log on the catastrophic `bothVariantsFailed` case.
        do {
            try await graphOwner.open()
        } catch {
            systemLogger?.warning("installVoice: AudioGraphOwner.open() failed (\(String(describing: error))) — voice subsystem dormant")
            audioGraphDegradationTask?.cancel()
            audioGraphRebuildTask?.cancel()
            self.audioGraphOwner = nil
            return
        }

        // Hand the ring buffer to the wake-word DAG so mic samples flow
        // through the openWakeWord pipeline. The detached feed Task inside
        // the DAG drives wakeWordStream, which VoiceController consumes.
        if let ring = await graphOwner.ringBuffer {
            await wakeWordDAG.start(ring: ring)
        } else {
            systemLogger?.warning("installVoice: graph opened but ringBuffer is nil — wake-word DAG not started")
        }

        // Cancel wake-word inference before the engine stops — otherwise
        // the detached feed Task races the ring deallocation during graph
        // rebuilds. (VOICE-10.)
        //
        // Use `stopFeed()` (not `cancel()`) so the public wakeWordStream
        // survives the rebuild — `VoiceController.spawnWakeWordConsumer`
        // keeps iterating across the boundary. The rebuild completion
        // consumer below re-arms the DAG against the new ring.
        // (audit-2026-05-12 P0-1 / Issue #28: cancel() permanently
        // finished the stream, killing wake-word on first device-change /
        // mic-regrant / ring-overflow event.)
        await graphOwner.setCancelInFlight { [wakeWordDAG] in
            await wakeWordDAG.stopFeed()
        }

        // The production adapter triad replaces the three earlier Null
        // placeholders:
        //   - `VoiceOrchestratorAdapter` wraps `agentOrchestrator` and
        //     surfaces `SubmitOutcome.rejected` reasons to the banner
        //     coordinator. Requires `turnTranscriptStore` so the adapter
        //     can append user-side text after every submit /
        //     cancelAndSubmit — without that append, the memory
        //     coordinator's drain sees nil pair text. (BLOCKER-1.)
        //   - `VoiceTTSAdapter` wraps a `TTSEngineActor` (tier-1
        //     AVSpeechSynthesizer today; tier-2 Orpheus is gated on the
        //     ~6 GB weight download).
        //   - `VoiceBusEmitterAdapter` wraps an `OutboundBatcher` whose
        //     sink is the `WebviewBridge` (audio-level RMS → RingMesh
        //     pulse, ~30 Hz coalesced).
        // (audit trail: Plan 09-04 / D-09 + D-11.)
        let bannerAdapter = AppDelegateBannerAdapter(coordinator: bannerCoordinator)

        guard let agentOrch = self.agentOrchestrator else {
            systemLogger?.warning("installVoice: agentOrchestrator nil — voice adapters dormant")
            return
        }

        let orchAdapter = VoiceOrchestratorAdapter(
            orchestrator: agentOrch,
            transcriptStore: self.turnTranscriptStore,
            bannerCoordinator: self.bannerCoordinator
        )
        self.voiceOrchestratorAdapter = orchAdapter

        // Real TTS engine via `TTSEngineWiring`. The wiring helper lives in
        // `App/Voice/` so the VISION-03 Layer 3 gate doesn't see
        // `TTSEngine*` symbols in this file. Tier-1 (AVSpeechSynthesizer)
        // wires alone here; tier-2 (Orpheus) is gated behind the ~6 GB
        // weight download and degrades to tier-1 transparently.
        // (audit trail: 2026-05-03 voice audit / Track B-3.)
        // Resolve TTS tier from PerTurnSnapshot per synthesis. Defaults
        // to `.tier1` when configStore is nil or `tts.tier` is anything
        // other than "tier2". Today this is decorative — Orpheus weights
        // aren't shipped, so the engine resolves tier-2 back to tier-1
        // inside `synthesize` — but the moment weights arrive, this
        // closure becomes the user-facing tier switch.
        // (audit-2026-05-12 P0-4 / Issue #31: was unwired; the default
        // `{ .tier1 }` constant masked any `tts.tier = "tier2"` config.)
        let ttsAdapter = VoiceTTSAdapter(
            engine: VoiceOutputWiring.makeTier1Engine(),
            tierResolver: { [configStore = self.configStore] in
                guard let configStore else { return .tier1 }
                let snap = await configStore.perTurn()
                return snap.tts.tier == "tier2" ? .tier2 : .tier1
            }
        )
        self.voiceTTSAdapter = ttsAdapter  // expose to BootHealthProbe (Issue #33)

        // Reuse the `OutboundBatcher` constructed by `installAgent`. The
        // batcher coalesces high-frequency audio-level RMS at ~30 Hz
        // before crossing the JS-call boundary. It moved up to
        // `installAgent` so the bus forwarder works even when the voice
        // DAG short-circuits on missing models (Phase E hoist). If even
        // `installAgent` couldn't construct one (no `webviewBridge`),
        // fall back to the dormant emitter so audio-level emissions
        // degrade gracefully instead of crashing.
        let busAdapter: any BusOutboundEmitter
        if let batcher = self.outboundBatcher {
            busAdapter = VoiceBusEmitterAdapter(batcher: batcher)
        } else {
            systemLogger?.warning("installVoice: outboundBatcher nil — audio-level emissions dropped")
            busAdapter = DormantVoiceBusEmitter()
        }

        // Production chunk pump. `VoiceController.startSTTSession` opens
        // an `AsyncStream<AudioChunk>` and hands the consumer side to the
        // STT provider; this pump fills the producer side from the live
        // audio graph. The closure body lives in
        // `ProductionChunkPump.swift` so it can be exercised by an
        // integration test against a real `AudioGraphOwner` + mock
        // `GraphBuilder`, closing the "tested with synthetic pumps only"
        // gap that allowed BLOCKER-INT-1-style divergence.
        // (audit trail: 2026-05-03 voice audit / Track B-5 + B-7;
        // audit-2026-05-04 P1-2.)
        let chunkPump = makeProductionChunkPump { [weak self] in
            await MainActor.run { self?.audioGraphOwner }
        }

        let vc = VoiceController(
            wakeWordStream: wakeWordDAG.wakeWordStream,
            vadFactory: { sileroVAD },
            sttFactory: { [configStore = self.configStore] in
                // Read STT backend from PerTurnSnapshot. Defaults to
                // SpeechAnalyzer when the snapshot disables WhisperKit
                // fallback (today's default) or when configStore is nil.
                // (audit-2026-05-12 P0-2 / Issue #29: was hard-coded to
                // "speech_analyzer", making `stt.whisperKitFallback`
                // unreachable from config.)
                let backend: String
                if let configStore {
                    let snap = await configStore.perTurn()
                    backend = snap.stt.whisperKitFallback
                        ? STTBackendSelector.backendWhisperKit
                        : STTBackendSelector.backendSpeechAnalyzer
                } else {
                    backend = STTBackendSelector.backendSpeechAnalyzer
                }
                return STTBackendSelector.make(backend: backend)
            },
            tts: ttsAdapter,
            orchestrator: orchAdapter,
            bannerCoordinator: bannerAdapter,
            bus: busAdapter,
            voiceHudCont: voiceCont,
            chunkPump: chunkPump
        )
        voiceController = vc

        // Wire `AudioLevelEmitter` so the listening-state HUD ring pulses
        // on real mic RMS. The emitter consumes a dedicated
        // `BufferBroadcaster` subscription so it does NOT steal samples
        // from `WakeWordDAG` / `chunkPump` (Track B-7 invariant).
        // `VoiceController.start()` / `.stop()` drive from
        // `doTransition`'s listening-boundary edges.
        // (audit trail: audit-2026-05-04 P1-1.)
        if let levelSubscription = await graphOwner.subscribe() {
            let emitter = AudioLevelEmitter(subscription: levelSubscription, bus: busAdapter)
            await vc.setAudioLevelEmitter(emitter)
        } else {
            systemLogger?.warning("installVoice: AudioGraphOwner.subscribe() returned nil — HUD ring pulse degraded")
        }

        // Transfer continuation ownership to `VoiceController`. The
        // coordinator's subscriber Task continues to drain; the controller
        // is now the sole producer. Setting the dormant slot to nil
        // releases our hold on the continuation.
        dormantVoiceContinuation = nil

        // PTT hotkey binding is deferred to the wizard / Settings UI —
        // unbound at launch. (VOICE-13.)
        let ptt = PushToTalk(controller: vc)
        pushToTalk = ptt

        // Menu-bar wake-word mute toggle. (VOICE-12.)
        if let menu = menuBarController?.contextMenu {
            muteWakeWord = MuteWakeWord(controller: vc, wakeWordDAG: wakeWordDAG, menuBarMenu: menu)
        }

        await vc.start()
        systemLogger?.info("installVoice: VoiceController started")
    }

    // MARK: - Memory install

    /// Constructs and starts the memory subsystem. The 2026-05-11 D-5/D-6
    /// closure changed the boot policy: `MemoryStore.init` is now a
    /// hard-block. Vec0 is statically linked via `CSQLiteVec`, so init
    /// has only two failure modes — file-system / permission error on
    /// the DB path, or an extraordinarily rare SQLite-internal failure.
    /// Both are operator-environment problems the user MUST be told
    /// about, not papered over.
    ///
    /// Failure path: `Logger.critical` + `TCCAlertService.presentHardBlock`
    /// + `NSApp.terminate(nil)`. Matches the existing entitlement /
    /// config-malformed hard-block pattern. (Not `NSAlert.runModal` —
    /// that's forbidden by `scripts/check-no-modal-presentation.sh`.)
    ///
    /// Bootstrap sequence:
    ///   1. Build the `jarvis.db` URL under Application Support.
    ///   2. Construct `MemoryStore`. Hard-block on failure.
    ///   3. Wire the `replayLog` sink so `MemoryStore.applyOp` records
    ///      `ReplayEvent.memoryMutation` through to the on-disk log.
    ///   4. Construct `MemoryExtractor` on `OllamaProvider` configured for
    ///      `qwen2.5-coder:32b` (CLAUDE.md known-good local baseline).
    ///   5. Construct `MemoryExtractionOrchestrator` (bounded channel,
    ///      capacity 32, `.dropOldest`, serial drain) and start its
    ///      consumer Task. `applyOp` adapts the orchestrator's Int64
    ///      trigger-turn-id to `MemoryStore.applyOp`.
    ///   6. Construct `MemoryExtractionCoordinator`. `installAgent`
    ///      subscribes it to the broadcaster's `.memory` priority stream.
    ///   7. Register `forget_fact` + `search_memory` into the shared
    ///      `inProcessToolRegistry`.
    @MainActor
    func installMemory() async {
        // 1. DB URL.
        let dbURL = configFileURL()
            .deletingLastPathComponent()
            .appendingPathComponent("jarvis.db")

        // 2. MemoryStore. Hard-block on failure per D-5/D-6 — see method
        //    docstring above for the policy + the prior Track-D D-1 era
        //    that this reversed.
        let store: MemoryStore
        do {
            store = try MemoryStore(databaseURL: dbURL)
        } catch {
            let description = String(describing: error)
            systemLogger?.critical(
                "installMemory: MemoryStore.init failed — \(description). Hard-blocking; check disk permissions or move jarvis.db aside."
            )
            TCCAlertService.presentHardBlock(
                title: "Jarvis can't start",
                informativeText: "MemoryStore initialization failed: \(description). Details in ~/Library/Logs/Jarvis/system.log. Common fix: check disk permissions on \(dbURL.path), or move the file aside and relaunch to recreate it."
            )
            NSApp.terminate(nil)
            return
        }
        self.memoryStore = store
        // Vec0 is statically linked via auto-extension; search is always
        // available when the store opens. The pre-D-5/D-6 split between
        // "store works" and "search works" no longer applies.
        self.memorySearchAvailable = true
        let searchAvailable = true

        // 3. Wire the replay sink. `store` is non-optional after D-5/D-6
        //    (we'd have terminated above if init had failed).
        if let log = replayLog {
            await store.setReplayLog(AppDelegateMemoryReplaySink(replayLog: log))
        } else {
            systemLogger?.warning("installMemory: replayLog absent — memory mutation rows won't persist")
        }

        // 4. MemoryExtractor on OllamaProvider(qwen2.5-coder:32b). Always
        //    constructed — the LLM call is independent of the store.
        let extractorProvider = OllamaProvider(
            baseURL: URL(string: "http://127.0.0.1:11434")!
        )
        let extractor = MemoryExtractor(provider: extractorProvider)

        // 5. Background orchestrator. Held strongly; `start()` spawns the
        //    drain Task. `priorFactsLookup` caps at 50 recent active facts
        //    so the extractor can emit UPDATE ops (mem0 supersede pattern)
        //    instead of always ADDing. The 50 cap matches RESEARCH §5's
        //    ~4 KB priorFacts budget. `applyOp` logs-and-drops when
        //    `memoryStore` is nil (drain loop survives, so a future
        //    reconstruction can replace this orchestrator).
        //    (audit trail: Track-D D-1 / D-3.)
        let logger = self.systemLogger
        let memoryOrch = MemoryExtractionOrchestrator(
            extractor: extractor,
            applyOp: { [weak self] op, turnId in
                if let store = await self?.memoryStore {
                    _ = try await store.applyOp(op, sourceTurnId: turnId)
                } else {
                    // T-06-05-03 / memory-content note: log only the op kind
                    // and the turnId hash, never the subject/object content.
                    logger?.debug("memory applyOp dropped (no store): turnId=\(turnId)")
                }
            },
            priorFactsLookup: { [weak self] _ in
                guard let store = await self?.memoryStore else { return [] }
                return try await store.recentActiveFacts(limit: 50)
            }
        )
        await memoryOrch.start()
        memoryExtractionOrchestrator = memoryOrch

        // 6. Construct the coordinator. `installAgent` calls
        //    `coord.start(...)` once the broadcaster's `.memory` priority
        //    child stream exists and the BLOCKER-1-fixing
        //    `lookupTurnContent` closure is bound.
        let coord = MemoryExtractionCoordinator(memoryOrchestrator: memoryOrch)
        memoryExtractionCoordinator = coord

        // 7. Register memory tools into the SHARED in-process registry.
        //    Adapters bridge MCP's `HybridSearchDispatching` /
        //    `ForgetFactDispatching` protocols to `Memory.HybridSearch` /
        //    `MemoryStore.forgetFact`. (audit trail: Track-D D-2.)
        let forgetDispatcher: any ForgetFactDispatching = ForgetFactStoreAdapter(store: store)
        var searchDispatcher: (any HybridSearchDispatching)? = nil
        if searchAvailable {
            do {
                let embedder = try OllamaEmbeddingClient(
                    baseURL: URL(string: "http://127.0.0.1:11434")!
                )
                let hybrid = HybridSearch(store: store, embedder: embedder)
                searchDispatcher = HybridSearchAdapter(hybrid: hybrid)
            } catch {
                systemLogger?.warning(
                    "installMemory: embedder init failed — search_memory not registered: \(String(describing: error))"
                )
            }
        }

        // Register INTO the shared `inProcessToolRegistry` — never
        // construct a fresh one here. See the property docstring on
        // `inProcessToolRegistry` for the three-site sharing contract.
        // The `??` is dead-defensive: the property is eagerly
        // default-initialized at declaration. (Plan 10-02c / B-01b.)
        let registry = self.inProcessToolRegistry ?? InProcessToolRegistry()
        self.inProcessToolRegistry = registry
        await Self.populateMemoryTools(
            in: registry,
            forgetDispatcher: forgetDispatcher,
            searchDispatcher: searchDispatcher
        )

        let toolNames = await registry.registered().map { $0.name }
        systemLogger?.info(
            "installMemory: extractor up; store=\(store != nil) search=\(searchAvailable) inProcessTools=\(toolNames)"
        )
    }

    /// Track-D D-2 test seam: pure registry-construction helper. Takes
    /// optional already-built dispatchers and registers tools per the
    /// gating rules:
    ///   - `forget_fact` registers if `forgetDispatcher` is non-nil.
    ///   - `search_memory` registers if `searchDispatcher` is non-nil.
    /// The production path passes nil dispatchers when their preconditions
    /// (store exists / searchAvailable) aren't met — which is exactly the
    /// gating semantics. Tests can pass stub dispatchers to assert positive
    /// registration without needing a real MemoryStore (which requires
    /// vec0.dylib, env-gated in CI).
    static func buildInProcessToolRegistry(
        forgetDispatcher: (any ForgetFactDispatching)?,
        searchDispatcher: (any HybridSearchDispatching)?
    ) async -> InProcessToolRegistry {
        let registry = InProcessToolRegistry()
        await populateMemoryTools(
            in: registry,
            forgetDispatcher: forgetDispatcher,
            searchDispatcher: searchDispatcher
        )
        return registry
    }

    /// Plan 10-02c (B-01b): populate memory tools INTO an existing registry.
    /// Same gating semantics as `buildInProcessToolRegistry`, but writes to
    /// the caller's registry instance so the eagerly-constructed
    /// `inProcessToolRegistry` (shared with `MCPRuntimeWiring.build` for the
    /// dispatch composite) gets the memory tools registered alongside the
    /// later-registered self-knowledge tools.
    static func populateMemoryTools(
        in registry: InProcessToolRegistry,
        forgetDispatcher: (any ForgetFactDispatching)?,
        searchDispatcher: (any HybridSearchDispatching)?
    ) async {
        if let forget = forgetDispatcher {
            await registry.register(ForgetFactTool(dispatcher: forget))
        }
        if let search = searchDispatcher {
            await registry.register(SearchMemoryTool(dispatcher: search))
        }
    }

    // MARK: - Agent install

    /// Bootstraps the agent subsystem: `AgentOrchestrator` +
    /// `OrchestratorEventBroadcaster` + `TurnTranscriptStore` and six
    /// broadcaster subscribers (memory, transcript, devOverlay,
    /// frameAttach, voice, bus). Without this method running, the
    /// orchestrator + broadcaster + every downstream consumer stays
    /// dormant — which is the runtime-dormancy class of bug the
    /// 2026-05-04 / 2026-05-12 audits surfaced repeatedly.
    ///
    /// Fail-soft policy: returns early when any required dep is nil
    /// (mcp / replay / config) or when `replayLog.beginSession` throws.
    /// In both cases the agent stays dormant and the rest of the app
    /// continues; the boot-health probe set reports the dormancy.
    ///
    /// Step sequence:
    ///   1. Guard on `mcpRuntime`, `replayLog`, `configStore` (set by
    ///      earlier installs that this Task awaited).
    ///   2. Build the provider factory closure — `AnthropicProvider`
    ///      uses `AnthropicAPIKeyProvider.make` so keychain errors
    ///      surface as `LLMProviderError.transport` instead of being
    ///      silently substituted with empty headers (the pre-fix path
    ///      was `(try? get) ?? ""`, which made auth failures
    ///      indistinguishable from `streamTruncatedFinal`).
    ///   3. Construct the orchestrator with `visionRouter`,
    ///      `presenceSnapshot`, `sessionHistoryLookup`, and a lazy tool
    ///      catalog resolver (in-process tools register late — see
    ///      `toolCatalogResolver`).
    ///   4. Hoist `OutboundBatcher` up here (out of `installVoice`) so
    ///      the `.bus` subscriber works even when the voice DAG
    ///      short-circuits on missing models.
    ///   5. Construct `OrchestratorEventBroadcaster` +
    ///      `TurnTranscriptStore` and attach six subscribers:
    ///        5a. memory      — extraction coordinator drain.
    ///        5b. transcript  — assistant-side tokenDelta accumulator.
    ///        5c. devOverlay  — `DevSnapshotEmitter` feed.
    ///        5d. frameAttach — release captured image bytes on turnEnd.
    ///        5e. voice       — turn-source-filtered voice translator.
    ///        5f. bus         — `BusForwarder.drain` → chat panel.
    @MainActor
    private func installAgent() async {
        // 1. Required deps from earlier installs.
        guard let mcpRuntime = self.mcpRuntime,
              let replayLog = self.replayLog,
              let configStore = self.configStore else {
            systemLogger?.warning("installAgent: deps not ready (mcp/replay/config) — skipping")
            return
        }

        // 2. Provider factory closure — closes over a local Sendable copy
        //    of the keychain reference (the existential itself is not
        //    Sendable). The propagating `AnthropicAPIKeyProvider.make`
        //    surfaces real `KeychainError`s as
        //    `LLMProviderError.transport(...)` so they reach the chat
        //    panel via `BusForwarder`. The pre-fix `(try? get) ?? ""`
        //    pattern silently substituted an empty `x-api-key` header,
        //    making auth failures indistinguishable from a stale key —
        //    the user only ever saw `streamTruncatedFinal` after
        //    Anthropic's 401 → SSE EOF cascade. (audit trail: Phase E
        //    2026-05-03 audit; coverage in `AnthropicAPIKeyProviderTests`.)
        let keychainStoreLocal: any KeychainStore = self.keychainStore
        let providerFactory: @Sendable (ProviderSelection) async throws -> any LLMProvider = {
            selection in
            switch selection {
            case .anthropic:
                return AnthropicProvider(
                    apiKeyProvider: AnthropicAPIKeyProvider.make(keychain: keychainStoreLocal)
                )
            case .ollama:
                return OllamaProvider(baseURL: URL(string: "http://127.0.0.1:11434")!)
            }
        }

        // 3. Construct the orchestrator. Image-bearing turns dispatch
        //    through `visionRouter` (pre-stream branch + post-response
        //    escalation hook). `presenceSnapshot` lets `runTurn` append
        //    ambient presence enrichment to the system prompt.
        //
        //    `beginSession` inserts the parent row in the `sessions`
        //    table; without it, every `startTurn` violates the
        //    `turns.session_id REFERENCES sessions(session_id)` FK and
        //    the orchestrator returns
        //    `SubmitOutcome.rejected(reason: .configError)` for every
        //    text turn (surfacing as "Config error — see system.log" in
        //    the chat panel). Pre-fix production only called
        //    `beginSession` from tests; the sessions table was empty on
        //    every cold launch.
        //    (audit trail: Plan 09-02 D-01 / 09-03 D-13+D-14 / Phase E
        //    2026-05-03 smoke test.)
        let info = Bundle.main.infoDictionary ?? [:]
        let appVersion = info["CFBundleShortVersionString"] as? String ?? "dev"
        let buildSHA = info["CFBundleVersion"] as? String ?? "dev"
        let sessionId: SessionID
        do {
            sessionId = try await replayLog.beginSession(
                appVersion: appVersion,
                buildSHA: buildSHA
            )
        } catch {
            systemLogger?.error(
                "installAgent: replayLog.beginSession failed — turns will be rejected: \(String(describing: error))"
            )
            return
        }
        // Plan 10-02b / B-01: source the tool catalog lazily from BOTH
        // the in-process registry (memory + self-knowledge tools) AND
        // the stdio MCPClient (mcp-time / mcp-clipboard /
        // mcp-applescript). The in-process registry is populated in
        // stages — memory tools register inside installMemory (before
        // installAgent runs), but the four Phase 10-01 self-knowledge
        // tools register inside installSelfKnowledgeTools (which runs
        // AFTER installAgent because it depends on the live
        // audioGraphOwner). A static snapshot at orchestrator
        // construction time would freeze out the self-knowledge tools.
        // The resolver fires per outer-loop iteration in
        // AgentOrchestrator.runTurnLoop, so by the time the user submits
        // their first turn the catalog is fully populated. No per-event
        // cost — one resolver invocation per LLM round-trip.
        let mcpClientLocal = mcpRuntime.client
        let inProcessRegistryRef: InProcessToolRegistry? = self.inProcessToolRegistry
        let toolCatalogResolver: @Sendable () async -> [ToolSchema] = {
            var catalog: [ToolSchema] = []
            // Stdio helpers (get_time / get_clipboard / run_applescript).
            let stdio = await mcpClientLocal.toolCatalog()
            catalog.append(contentsOf: stdio)
            // In-process tools (memory + self-knowledge).
            if let inProc = inProcessRegistryRef {
                let inProcessSchemas = await inProc.toolSchemas()
                catalog.append(contentsOf: inProcessSchemas)
            }
            return catalog
        }
        // B-02 (carry-forward bug, tactical patch outside v1.0 migration):
        // hydrate prior turn history from the `turns` table so multi-turn
        // conversations preserve context. `recentTurnsForSession` returns
        // rows in DESC order; reverse to chronological so the LLM sees
        // user → assistant → user → assistant alternation. Filter to
        // user/assistant only — tool-role rows (if any are written later)
        // do not belong in the prior-history prefix. Cap at 10 turn rows
        // (~5 prior user/assistant pairs) to bound prompt growth.
        let sessionIdString = sessionId.rawValue
        let memoryStoreRef = self.memoryStore
        let historyLogger = self.systemLogger
        let sessionHistoryLookup: AgentOrchestrator.SessionHistoryLookup = {
            guard let store = memoryStoreRef else { return [] }
            do {
                let rows = try await store.recentTurnsForSession(
                    sessionId: sessionIdString, limit: 10
                )
                let chronological = Array(rows.reversed())
                return chronological.compactMap { row in
                    switch row.role {
                    case "user":
                        return AgentOrchestrator.PriorTurn(role: .user, content: row.content)
                    case "assistant":
                        return AgentOrchestrator.PriorTurn(role: .assistant, content: row.content)
                    default:
                        return nil
                    }
                }
            } catch {
                // T-06-05-03: log the error, never the row content.
                historyLogger?.warning("sessionHistoryLookup failed: \(error)")
                return []
            }
        }

        let orchestrator = AgentOrchestrator(
            configStore: configStore,
            providerFactory: providerFactory,
            toolDispatcher: mcpRuntime.dispatcher,
            replayLog: replayLog,
            sessionId: sessionId,
            // Plan 10-02 (SELF-05 / SELF-06) — replaces the hardcoded
            // "You are Jarvis, a personal macOS assistant." literal with
            // ContextBuilder's locked self-aware preamble. The preamble
            // names introspection tools so the model prefers calling them
            // over generic "open System Settings" answers. Per D-12
            // fallback the orchestrator still takes systemPrompt:String at
            // init; per-turn presence enrichment continues to flow through
            // PresenceStateSnapshot.shared (passed below).
            systemPrompt: ContextBuilder.systemPrompt(for: .empty),
            availableTools: [],
            availableToolsResolver: toolCatalogResolver,
            visionRouter: self.visionRouter,
            presenceSnapshot: PresenceStateSnapshot.shared,
            sessionHistoryLookup: sessionHistoryLookup
        )
        self.agentOrchestrator = orchestrator

        // 4. Broadcaster + transcript store (D-05 / D-08 / BLOCKER-1).
        let broadcaster = OrchestratorEventBroadcaster(upstream: orchestrator.events)
        await broadcaster.start()
        self.eventBroadcaster = broadcaster

        // Phase E (2026-05-03): hoist OutboundBatcher construction up out of
        // `installVoice`. Previously the batcher was only built inside
        // installVoice AFTER the OpenWakeWord/Silero models were loaded, so
        // any voice-DAG short-circuit (missing model files in Debug builds)
        // left `self.outboundBatcher == nil` for the whole process. Every
        // `outboundBatcher?.flushAndSend(...)` chained-optional in the .bus
        // subscriber then silently dropped tokenDelta / turnStarted /
        // turnEnded / submitRejected — the chat panel got nothing back from
        // the orchestrator. The batcher only needs the WebviewBridge as a
        // sink (no voice models required), so it belongs here. installVoice
        // now reuses `self.outboundBatcher` rather than constructing its
        // own, keeping the single-sink invariant intact.
        if self.outboundBatcher == nil, let bridge = self.webviewBridge {
            self.outboundBatcher = OutboundBatcher(sink: bridge)
        } else if self.webviewBridge == nil {
            systemLogger?.warning("installAgent: webviewBridge nil — outboundBatcher not constructed; bus forwarder will drop events")
        }

        let transcriptStore = TurnTranscriptStore()
        self.turnTranscriptStore = transcriptStore

        // 5a. Memory subscriber — D-07 protected events.
        //     `lookupTurnContent` reads from the TurnTranscriptStore (BLOCKER-1
        //     fix). Plan 1 feeds the assistant side via the transcript subscriber
        //     below; Plan 4 will feed the user side at submit time.
        let memorySub = await broadcaster.subscribe(priority: .memory, capacity: 256)
        if let coord = self.memoryExtractionCoordinator {
            memoryEventSubscriberTask = Task { [weak self] in
                await coord.start(
                    orchestratorEvents: memorySub.stream,
                    turnContent: { [weak self] turnId in
                        // BLOCKER-1 fix: read from TurnTranscriptStore (the
                        // source of truth populated by the transcript subscriber
                        // and Plan 4's submit-time user-side append) rather
                        // than the Phase-7-era nil stub.
                        if let pair = await self?.turnTranscriptStore?.flushPair(turnId) {
                            // B-02 (carry-forward bug, tactical patch outside
                            // v1.0 migration): persist the completed turn pair
                            // to the `turns` table so subsequent turns'
                            // sessionHistoryLookup can hydrate prior context.
                            // Persistence rides on the existing turnContent
                            // flush path because TurnTranscriptStore.flushPair
                            // is destructive — single-consumer invariant
                            // preserved. Both rows share the turn's
                            // chronological position; we offset assistant by
                            // +1 ms so the DESC + id-tiebreaker ordering in
                            // sessionHistorySQL reconstructs the pair in
                            // user→assistant order.
                            // T-06-05-03: log only the turn id hash and op
                            // outcome; NEVER log row content.
                            if let store = await self?.memoryStore {
                                let sessionIdValue = sessionIdString
                                let now = Int64(Date().timeIntervalSince1970 * 1000)
                                do {
                                    try await store.appendTurn(
                                        sessionId: sessionIdValue,
                                        role: "user",
                                        content: pair.userText,
                                        source: "userText",
                                        createdAt: now
                                    )
                                    try await store.appendTurn(
                                        sessionId: sessionIdValue,
                                        role: "assistant",
                                        content: pair.assistantText,
                                        source: "assistant",
                                        createdAt: now + 1
                                    )
                                } catch {
                                    await self?.systemLogger?.warning(
                                        "B-02 turn-persistence appendTurn failed: \(error)"
                                    )
                                }
                            }
                            return (user: pair.userText, assistant: pair.assistantText)
                        }
                        return nil
                    }
                )
            }
        } else {
            systemLogger?.warning("installAgent: memoryExtractionCoordinator nil — memory dormant")
        }

        // 5b. Transcript collector (BLOCKER-1: assistant side accumulator).
        //     Drains .tokenDelta events into the TurnTranscriptStore so
        //     `flushPair(turnId)` returns the accumulated assistant text by
        //     the time memory's drain processes the matching .turnEnd.
        //     Broadcaster fan-out is synchronous per event so the transcript
        //     subscriber processes every .tokenDelta before the memory
        //     subscriber sees the trailing .turnEnd.
        let transcriptSub = await broadcaster.subscribe(priority: .transcript, capacity: 256)
        transcriptSubscriberTask = Task { [weak self] in
            for await event in transcriptSub.stream {
                if Task.isCancelled { break }
                guard let self else { break }
                if case let .tokenDelta(turnId, text) = event {
                    await self.turnTranscriptStore?.append(
                        turnId: turnId, role: .assistant, deltaText: text
                    )
                }
            }
        }

        // 5c. DevOverlay subscriber — forwards every event into a live
        //     `DevSnapshotEmitter` so the DevOverlay window renders the
        //     real agent state instead of `DevSnapshot.initial`. Wired
        //     2026-05-12 (dev-overlay-end-to-end Slice 2). The pre-fix
        //     drain was a `for await _ in …` to `/dev/null`, which
        //     explains why the panel had been showing zeros since P4.
        //
        //     Provider/model is set eagerly via the same `configStore`
        //     read SelfStateAdapter uses. Lossy under load — DevOverlay is
        //     observational; the emitter's output channel is .dropOldest.
        let devEmitter = DevSnapshotEmitter()
        self.devSnapshotEmitter = devEmitter
        // Populate provider/model header best-effort. The orchestrator
        // can switch providers mid-session; the emitter's setter is the
        // hook to refresh, but for now we read once at install.
        if let configStore = self.configStore {
            let snap = await configStore.perTurn()
            let providerName: String
            let modelName: String
            switch snap.provider {
            case .anthropic:
                providerName = "anthropic"
                modelName = "claude-opus-4-7"
            case .ollama:
                providerName = "ollama"
                modelName = "qwen2.5-coder:32b"
            }
            await devEmitter.setProvider(provider: providerName, modelId: modelName)
        }
        let devSub = await broadcaster.subscribe(priority: .devOverlay, capacity: 32)
        devOverlaySubscriberTask = Task { [devEmitter] in
            for await event in devSub.stream {
                if Task.isCancelled { break }
                await devEmitter.apply(event)
            }
        }

        // 5d. Plan 09-02 / D-16 — frame-attach release subscriber. Watches
        //     for `.turnEnd`; when the turn carried an image (per
        //     `agentOrchestrator.turnHadImage(_:)`), call
        //     `frameAttachController.onAssistantTurnComplete()` to release
        //     the captured frame's in-memory bytes.
        //
        //     The `.frameAttach` priority protects `.turnEnd` (per
        //     OrchestratorEventBroadcaster's protection matrix), so a
        //     saturated subscriber buffer never drops the very event we
        //     gate on. If `frameAttachController` is nil (no replayLog at
        //     vision-install time), the drain harmlessly ignores image
        //     turns — the privacy invariant lives on the producer side.
        let frameSub = await broadcaster.subscribe(priority: .frameAttach, capacity: 64)
        self.frameAttachReleaseTask = Task { [weak self] in
            for await event in frameSub.stream {
                if Task.isCancelled { break }
                guard let self else { break }
                if case let .turnEnd(turnId, _) = event {
                    let hadImage = await self.agentOrchestrator?.turnHadImage(turnId) ?? false
                    if hadImage {
                        await self.frameAttachController?.onAssistantTurnComplete()
                    }
                }
            }
        }

        // 5e. Plan 09-04 — voice event translator subscriber. BLOCKER-2:
        //     per-turn assistant-text accumulator keyed by TurnID; emits to
        //     voiceOrchestratorAdapter ONLY for voice-originated turns
        //     (queried via Plan 2's turnSourceWasVoice). Without this filter,
        //     a text-originated `.turnEnd` would drive VoiceController back
        //     to .idle from .listening — silently breaking voice.
        //
        //     The `.voice` priority protects `.turnEnd` and `.error` per
        //     OrchestratorEventBroadcaster's matrix, so the trigger events
        //     are never dropped under load.
        //
        //     Filtering at .tokenDelta append time keeps `perTurnAssistantText`
        //     bounded by in-flight VOICE turns only — text-only sessions
        //     don't grow the dictionary.
        let voiceSub = await broadcaster.subscribe(priority: .voice, capacity: 64)
        self.voiceEventTranslatorTask = Task { [weak self] in
            var perTurnAssistantText: [TurnID: String] = [:]
            for await event in voiceSub.stream {
                if Task.isCancelled { break }
                guard let self else { break }
                switch event {
                case let .tokenDelta(turnId, text):
                    let isVoice = await self.agentOrchestrator?.turnSourceWasVoice(turnId) ?? false
                    guard isVoice else { continue }
                    perTurnAssistantText[turnId, default: ""] += text
                case let .turnEnd(turnId, _):
                    let isVoice = await self.agentOrchestrator?.turnSourceWasVoice(turnId) ?? false
                    if isVoice {
                        // Flush accumulated assistant text and emit. nil → ""
                        // when the voice turn produced zero token deltas (e.g.
                        // refusal); emitting empty still drives VoiceController
                        // back to .idle, which is the desired terminal state.
                        let finalText = perTurnAssistantText.removeValue(forKey: turnId) ?? ""
                        self.voiceOrchestratorAdapter?.emitTurnEnded(finalText: finalText)
                    } else {
                        // Text-originated turn — drop without emitting.
                        perTurnAssistantText.removeValue(forKey: turnId)
                    }
                case let .error(turnId, _):
                    let isVoice = await self.agentOrchestrator?.turnSourceWasVoice(turnId) ?? false
                    if isVoice {
                        self.voiceOrchestratorAdapter?.emitError()
                        perTurnAssistantText.removeValue(forKey: turnId)
                    }
                default:
                    break
                }
            }
        }

        // 5f. Phase E (BLOCKER-INT-2 from v0.12.0-MILESTONE-AUDIT.md) —
        //     bus-forwarding subscriber. Drains the broadcaster's `.bus`
        //     subscription via `BusForwarder.drain` (lives in AgentCore so
        //     it's unit-testable; full per-branch coverage in
        //     `BusForwarderTests.swift`). The sink below is the App-only
        //     piece — translates BusForwarder's protocol-agnostic enum into
        //     actual `BusOutbound` wire events through OutboundBatcher.
        //
        //     `OutboundBatcher.postToken` coalesces tokens at ~30 Hz
        //     internally; combined with `.bus` priority's drop-eligible
        //     classification of `.tokenDelta`, extreme overload tail-drops
        //     individual deltas instead of back-pressuring the orchestrator.
        //     `flushAndSend` for `turnStarted` / `turnEnded` /
        //     `submitRejected` drains pending tokens first so lifecycle
        //     events never overtake their data.
        let busSub = await broadcaster.subscribe(priority: .bus, capacity: 256)
        self.busSubscriberTask = Task { [weak self] in
            guard let self else { return }
            // Capture the batcher reference at task-start. If the batcher
            // was never constructed (no webviewBridge), drain the stream
            // anyway so events aren't backpressured into the broadcaster.
            if let batcher = self.outboundBatcher {
                let sink = AppBusForwarderSink(batcher: batcher)
                await BusForwarder.drain(events: busSub.stream, sink: sink)
            } else {
                self.systemLogger?.warning(
                    "busSubscriberTask: outboundBatcher nil — events will drain without forwarding"
                )
                for await _ in busSub.stream { if Task.isCancelled { break } }
            }
        }

        systemLogger?.info(
            "installAgent: AgentOrchestrator + broadcaster + transcript store wired (memory + transcript + devOverlay + frameAttach + voice + bus subscribers active)"
        )
    }

    // MARK: - Self-knowledge install

    /// Registers the read-only self-knowledge tools (`list_audio_devices`,
    /// `list_camera_devices`, `get_active_audio_route`, `get_self_state`,
    /// `get_memory_stats`) into the shared `inProcessToolRegistry`. Runs
    /// AFTER `installVoice` so `audioGraphOwner` is live for
    /// `AudioGraphRouteAdapter`.
    ///
    /// Degrade-gracefully policy: tools whose dependencies are nil are
    /// skipped with a single warning rather than dropping the whole
    /// install — `list_audio_devices` + `list_camera_devices` are pure
    /// metadata queries with no captured actor, so they always register.
    ///
    /// Invariants:
    ///   - Every tool registers with `requiresConfirmation: false`
    ///     explicitly (read-only, no side effects). The flag is on the
    ///     tool type itself; the registry doesn't default it. (D-10.)
    ///   - Dispatchers do NOT cache — every call queries fresh state so
    ///     the model never reads a stale snapshot. (D-09.)
    /// (audit trail: Plan 10-01 / SELF-01..04 + D-5/D-6
    /// `get_memory_stats` add.)
    @MainActor
    func installSelfKnowledgeTools() async {
        guard let registry = self.inProcessToolRegistry else {
            systemLogger?.warning(
                "installSelfKnowledgeTools: inProcessToolRegistry nil — memory short-circuited; self-knowledge tools dormant"
            )
            return
        }

        // SELF-01 + SELF-04: pure CoreAudio / AVCaptureDevice queries —
        // no live-actor refs needed.
        await registry.register(
            ListAudioDevicesTool(dispatcher: CoreAudioDeviceListAdapter())
        )
        await registry.register(
            ListCameraDevicesTool(dispatcher: AVCaptureDeviceListAdapter())
        )

        // SELF-02: requires the live AudioGraphOwner. If voice didn't
        // start (no mic, no models, etc.), skip this one so the tool
        // doesn't appear in the registry returning a perpetually-nil
        // route — better to omit than to silently lie.
        if let owner = self.audioGraphOwner {
            await registry.register(
                GetActiveAudioRouteTool(
                    dispatcher: AudioGraphRouteAdapter(owner: owner)
                )
            )
        } else {
            systemLogger?.warning(
                "installSelfKnowledgeTools: audioGraphOwner nil — get_active_audio_route not registered"
            )
        }

        // SELF-03: closure-injected probes hop into the live actors.
        // ProviderIdentity reads from the configStore's per-turn snapshot
        // (the orchestrator's ground truth for which provider it'll route
        // to next). Voice loop state hops into VoiceController. TTS tier
        // and STT backend come from the per-turn config. Wake-word mute
        // is persisted in UserDefaults by `MuteWakeWord`.
        let configStore = self.configStore
        let voiceController = self.voiceController
        let launchInstant = self.launchInstant

        let providerIdentity: @Sendable () async -> SelfStateAdapter.ProviderIdentity = {
            guard let configStore else {
                return (provider: "anthropic", model: "claude-opus-4-7")
            }
            let snap = await configStore.perTurn()
            let providerName: String
            let modelName: String
            switch snap.provider {
            case .anthropic:
                providerName = "anthropic"
                modelName = "claude-opus-4-7"   // CLAUDE.md / RESEARCH-DELTAS D1
            case .ollama:
                providerName = "ollama"
                modelName = "qwen2.5-coder:32b"  // CLAUDE.md known-good local baseline
            }
            return (provider: providerName, model: modelName)
        }
        let voiceState: @Sendable () async -> String? = {
            guard let voiceController else { return nil }
            let s = await voiceController.state
            switch s {
            case .idle:                       return "idle"
            case .listening(let source):
                switch source {
                case .wakeWord: return "listening:wakeWord"
                case .ptt:      return "listening:ptt"
                }
            case .thinking:                   return "thinking"
            case .speaking:                   return "speaking"
            case .reconfiguring(let reason):  return "reconfiguring:\(reason)"
            }
        }
        let ttsTier: @Sendable () async -> String = {
            guard let configStore else { return "tier1" }
            let snap = await configStore.perTurn()
            return snap.tts.tier
        }
        let sttBackend: @Sendable () async -> String = {
            // Returns the canonical backend identifier matching
            // `STTBackendSelector.backendSpeechAnalyzer` /
            // `STTBackendSelector.backendWhisperKit` (snake_case). The
            // pre-2026-05-12 strings ("speechAnalyzer" / "whisperKit"
            // camelCase) did not match the selector's accepted values —
            // any consumer routing through `STTBackendSelector.make`
            // landed in the `unknown backend` default branch.
            // (audit-2026-05-12 P0-2 / P2-1 / Issue #29.)
            guard let configStore else { return STTBackendSelector.backendSpeechAnalyzer }
            let snap = await configStore.perTurn()
            return snap.stt.whisperKitFallback
                ? STTBackendSelector.backendWhisperKit
                : STTBackendSelector.backendSpeechAnalyzer
        }
        let wakeWordMuted: @Sendable () async -> Bool = {
            UserDefaults.standard.bool(forKey: "features.voice.wakeWordMuted")
        }

        let selfState = SelfStateAdapter(
            bundle: .main,
            launchInstant: launchInstant,
            providerIdentity: providerIdentity,
            voiceState: voiceState,
            ttsTier: ttsTier,
            sttBackend: sttBackend,
            wakeWordMuted: wakeWordMuted
        )
        await registry.register(GetSelfStateTool(dispatcher: selfState))

        // D-5/D-6 closure follow-up: register `get_memory_stats` so the model
        // can answer "how many turns do you have?" / "how big is your DB?"
        // questions without us shelling out to sqlite3. After the hard-fail
        // boot policy (this commit), `self.memoryStore` is guaranteed
        // non-nil here — but we keep the guard since `installSelfKnowledgeTools`
        // is reached BEFORE installMemory in the install DAG order is
        // theoretically possible; the warning surfaces the timing bug if so.
        if let store = self.memoryStore {
            let dbURL = configFileURL()
                .deletingLastPathComponent()
                .appendingPathComponent("jarvis.db")
            await registry.register(
                GetMemoryStatsTool(
                    dispatcher: MemoryStatsStoreAdapter(store: store, databaseURL: dbURL)
                )
            )
        } else {
            systemLogger?.warning(
                "installSelfKnowledgeTools: memoryStore nil — get_memory_stats not registered (install-order bug?)"
            )
        }

        let names = await registry.registered().map(\.name).sorted()
        systemLogger?.info(
            "installSelfKnowledgeTools: registered self-knowledge tools — registry now contains \(names)"
        )
    }

    // (StopReason → TurnTerminator mapping moved to
    // `BusForwarder.terminator(for:)` in AgentCore. The App-side translation
    // from the protocol-agnostic `BusForwarder.Terminator` to the wire
    // `Bus.TurnTerminator` lives in `AppBusForwarderSink.swift`.)

    // MARK: - Plan 09-02 phrase-detection helper

    /// D-13 phrase-attach hook for Plan 4's chat handlers. Called from BOTH
    /// `chatSubmit` AND `chatCancelAndSubmit` per WARNING-4 — without that,
    /// barge-in after a phrase-matched submit silently drops the frame.
    ///
    /// On match, calls `frameAttachController.requestAttach(reason:
    /// .phraseDetected(in: text))` BEFORE the orchestrator's `submit(.text(text))`.
    /// The user still has to confirm `[Send]` in the HUD; this just arms the
    /// pending-frame slot so the camera capture is ready.
    @MainActor
    func tryPhraseAttachIfMatch(_ text: String) async {
        // Plan 10-02 disambiguation: qualify with `JarvisVision.` because
        // AgentCore now also exposes a `ContextBuilder` (self-aware system-
        // prompt composer). matchesFrameAttachPhrase lives on Vision's.
        let cb = JarvisVision.ContextBuilder()
        if cb.matchesFrameAttachPhrase(text), let fac = self.frameAttachController {
            await fac.requestAttach(reason: .phraseDetected(in: text))
        }
    }

    // MARK: - Plan 09-04 chat-panel handlers (D-12 + WARNING-4 + BLOCKER-1 user-side)

    /// D-12 — webview chat-panel "Send" button. Submits a fresh turn via
    /// `AgentOrchestrator.submit(.text(text))`. WARNING-4: the phrase-trigger
    /// helper fires BEFORE submit so a phrase-matched send arms the frame
    /// attach slot. BLOCKER-1: appends user text to TurnTranscriptStore
    /// AFTER the orchestrator returns a turnId so MemoryExtractionCoordinator
    /// finds non-nil pair text on the matching `.turnEnd`.
    ///
    /// Track-C 5: if the FrameAttachController has a pending frame
    /// (camera button pressed within the D-14 confirm window, or phrase
    /// trigger armed it on a prior submit), confirm-send it and route
    /// through `submit(.withImages(...))` so the agent's vision dispatch
    /// path picks the frame up.
    @MainActor
    func handleChatSubmit(_ text: String) async {
        guard let orch = self.agentOrchestrator else {
            systemLogger?.warning("handleChatSubmit: agentOrchestrator nil — dropping submission")
            return
        }
        await self.tryPhraseAttachIfMatch(text)
        let outcome: SubmitOutcome
        if let imageBlock = await self.consumePendingFrameIfAny(userText: text) {
            outcome = await orch.submit(.withImages(.text, text: text, images: [imageBlock]))
        } else {
            outcome = await orch.submit(.text(text))
        }
        await self.appendUserTextIfRunning(outcome, text: text)
        await self.handleTextOutcome(outcome)
    }

    /// D-12 — webview chat-panel barge-in. Cancels the in-flight turn (if
    /// any) and submits the new text via `cancelAndSubmit(.text(text))`.
    /// WARNING-4: phrase trigger ALSO fires here — both submit sites carry
    /// the same user-text shape; both must respect "what am I looking at"
    /// detection (without this, barge-in after a phrase-matched send
    /// silently drops the frame).
    ///
    /// Track-C 5: same image-attach handling as `handleChatSubmit`.
    @MainActor
    func handleChatCancelAndSubmit(_ text: String) async {
        guard let orch = self.agentOrchestrator else {
            systemLogger?.warning("handleChatCancelAndSubmit: agentOrchestrator nil — dropping submission")
            return
        }
        await self.tryPhraseAttachIfMatch(text)
        let outcome: SubmitOutcome
        if let imageBlock = await self.consumePendingFrameIfAny(userText: text) {
            outcome = await orch.cancelAndSubmit(.withImages(.text, text: text, images: [imageBlock]))
        } else {
            outcome = await orch.cancelAndSubmit(.text(text))
        }
        await self.appendUserTextIfRunning(outcome, text: text)
        await self.handleTextOutcome(outcome)
    }

    /// Track-C 5: pulls a pending frame out of `FrameAttachController` if
    /// one is armed. Returns the resulting `ImageBlock` for inclusion in
    /// the submit, or nil if nothing was armed (or the controller is not
    /// installed yet — graceful no-op for headless test hosts).
    @MainActor
    private func consumePendingFrameIfAny(userText: String) async -> ImageBlock? {
        guard let fac = self.frameAttachController else { return nil }
        if await fac.hasPendingFrame == false { return nil }
        return await fac.confirmSend(userText: userText)
    }

    /// BLOCKER-1 user-side append helper. Called from BOTH chat handlers
    /// after the orchestrator returns. On `.ran`/`.superseded`, appends the
    /// user text under the turn's id; on `.rejected`, no-op (no turn was
    /// allocated, so MemoryExtractionCoordinator's drain will not look up
    /// pair content for this submission).
    @MainActor
    private func appendUserTextIfRunning(_ outcome: SubmitOutcome, text: String) async {
        let turnId: TurnID
        switch outcome {
        case .ran(let id):
            turnId = id
        case .superseded(_, let newId, _):
            turnId = newId
        case .rejected:
            return
        }
        await self.turnTranscriptStore?.append(turnId: turnId, role: .user, deltaText: text)
    }

    /// D-10 text-path rejection toast. On `.rejected`, sends a
    /// `BusOutbound.submitRejected(reason:)` to the webview using
    /// `RejectReasonCopy.body(for:)` — byte-identical to the voice-path
    /// HUD banner. On `.ran`/`.superseded` returns silently (turnEnd
    /// events flow via the broadcaster).
    @MainActor
    private func handleTextOutcome(_ outcome: SubmitOutcome) async {
        switch outcome {
        case .ran, .superseded:
            return
        case .rejected(let reason):
            let body = RejectReasonCopy.body(for: reason)
            try? await self.webviewBridge?.send(.submitRejected(reason: body))
        }
    }

    // MARK: - Vision install

    /// Constructs and starts the vision subsystem. Spawns the camera
    /// capture session, presence monitor (which owns the single
    /// `PresenceSignalBus`), vision router ladder (T1/T2/T3), and the
    /// frame-attach controller.
    ///
    /// Architectural invariant — VISION-03: `PresenceSignalBus` is
    /// constructed EXACTLY ONCE (by `PresenceMonitor` — only that type
    /// can call the bus's `internal init` per 07-04's design) and shared
    /// by reference between two read-only consumers (`ContextBuilder`
    /// for system-prompt enrichment, `HudStateCoordinator` for the
    /// subtle ring indicator). The bus must have ZERO subscribers in
    /// `JarvisTTS` or any code path reaching
    /// `AgentOrchestrator.runTurn` / `.cancelAndSubmit` — presence is
    /// ambient, not a turn input. Enforced by
    /// `scripts/check-presence-vision-isolation.sh`.
    ///
    /// TCC policy: request camera permission BEFORE `open()` so the
    /// first-launch path either gets the prompt or proceeds gracefully
    /// degraded. The degradation watcher Task is spawned BEFORE the
    /// request so a denial enqueues `.cameraDenied` cleanly.
    /// (D-09 presence-on-by-default after first TCC grant.)
    @MainActor
    private func installVision() async {
        // 1. Camera capture session + degradation stream → HUD banner.
        let capture = CameraCapture()
        captureSession = capture
        let degStream = await capture.degradationStream

        cameraDegradationTask = Task { @MainActor [weak self] in
            for await reason in degStream {
                switch reason {
                case .cameraDenied:
                    self?.bannerCoordinator?.enqueue(.cameraDenied)
                case .midSessionRevoked:
                    self?.bannerCoordinator?.enqueue(.cameraRevoked)
                }
            }
        }

        // 2026-05-06 — TCC camera permission. Mirrors the mic-permission
        // pattern in installVoice. Without an explicit
        // `AVCaptureDevice.requestAccess(for: .video)` call macOS does not
        // surface the camera prompt and `CameraCapture.open()` silently
        // fails as `.cameraDenied`. We request before `open()` so the
        // first-launch path either gets the prompt or we proceed
        // gracefully degraded.
        let camStatus = AVCaptureDevice.authorizationStatus(for: .video)
        switch camStatus {
        case .authorized:
            break
        case .notDetermined:
            systemLogger?.info("installVision: requesting camera permission (.notDetermined)")
            let granted = await AVCaptureDevice.requestAccess(for: .video)
            systemLogger?.info("installVision: camera permission \(granted ? "granted" : "denied")")
        case .denied, .restricted:
            systemLogger?.warning("installVision: camera permission \(String(describing: camStatus)) — vision features dormant")
        @unknown default:
            break
        }

        // Try to open. Failure is non-fatal — banner already enqueued by
        // the degradation watcher above on .cameraDenied.
        do {
            try await capture.open()
        } catch {
            systemLogger?.warning(
                "installVision: CameraCapture.open() failed (\(String(describing: error))) — presence + frame-attach degrade gracefully"
            )
            // Continue — presence/frame-attach scaffolding still wires up so
            // becameAuthorized() can be re-invoked after a TCC grant.
        }

        // 2. PresenceMonitor — constructs PresenceSignalBus internally
        //    (only PresenceMonitor can; the bus init is internal). The
        //    monitor's `bus` property is the SINGLE shared reference.
        let frameStream = capture.frameStream(forPresence: true)
        let monitor = PresenceMonitor(frameStream: frameStream)
        presenceMonitor = monitor
        let bus = monitor.bus
        presenceSignalBus = bus
        await monitor.start()

        // 3. ContextBuilder consumer (D-10 system-prompt enrichment).
        //    Read-only consumer of bus.stream; never produces.
        AppDelegateContextBuilderAdapter.attachPresence(bus.stream)

        // 4. HudStateCoordinator consumer (D-10 subtle ring indicator).
        //    Single-writer invariant preserved — HudStateCoordinator's
        //    resolveAndEmit remains the only HudState writer.
        hudStateCoordinator?.attachPresence(bus.stream)

        // 5. DisablePresence menu-bar toggle (D-12).
        if let menu = menuBarController?.contextMenu {
            disablePresence = DisablePresence(
                presenceMonitor: monitor,
                menuBarMenu: menu
            )
        }

        // 6. VisionRouter (D-16/D-17/D-18 T1/T2/T3 ladder).
        //    T2 (`VllmMlxSidecar` + `VllmMlxProvider`) is not yet wired in
        //    AppDelegate (codesigning + feature-flag + binary-bundling work
        //    is downstream). Track-C 4 replaces the previous silent
        //    `t2Provider: t1` fallback with an explicit `MissingT2Provider`
        //    whose `stream(...)` throws `VisionError.t2ProviderUnavailable`.
        //    Callers MUST gate T2 escalation on `evaluatePostResponse(...,
        //    t2Available: false)`, which routes to `.useT1Result` and never
        //    invokes T2 — so this provider is never actually streamed in
        //    production today. Surfacing the missing wiring as an explicit
        //    error makes a regression debuggable instead of silent.
        let t1 = OllamaProvider(baseURL: URL(string: "http://127.0.0.1:11434")!)
        let t3: any LLMProvider
        let keychainStoreLocal = self.keychainStore
        // Phase E (2026-05-03 audit fix): see installAgent for rationale.
        // Same propagating builder used here so vision turns also surface
        // KeychainError instead of silently sending an empty x-api-key.
        t3 = AnthropicProvider(
            apiKeyProvider: AnthropicAPIKeyProvider.make(keychain: keychainStoreLocal)
        )
        let router = VisionRouter(
            t1Provider: t1,
            t2Provider: MissingT2Provider(),   // Track-C 4 — explicit, not silent
            t3Provider: t3
        )
        visionRouter = router

        // 7. Plan 09-02 / D-15 — FrameAttachController.
        //    Adapters live in App/Vision/AppDelegateFrameAttachAdapters.swift;
        //    they wrap CameraCapture (CaptureSource) + the FrameAttachReplaySink
        //    actor (which itself accepts a ReplayLogProtocol). FrameAttachController's
        //    SOLE-emission-site discard invariant is intact regardless of the
        //    adapters (it lives in packages/Vision/Sources/Vision/FrameAttachController.swift,
        //    enforced by FrameAttachDiscardSiteGrepTests).
        if let replayLog = self.replayLog {
            let captureAdapter = FrameAttachCaptureSourceAdapter(cameraCapture: capture)
            let replayAdapter = FrameAttachReplaySinkAdapter(replayLog: replayLog)
            let visionSink = FrameAttachReplaySink(replayLog: replayAdapter)
            let bridgedSink = FrameAttachControllerReplaySinkBridge(underlying: visionSink)
            let frameAttach = FrameAttachController(
                captureSession: captureAdapter,
                replaySink: bridgedSink
            )
            self.frameAttachController = frameAttach
        } else {
            systemLogger?.warning(
                "installVision: replayLog absent — FrameAttachController not instantiated"
            )
        }

        systemLogger?.info(
            "installVision: presence + VisionRouter + FrameAttachController wired (T2 sidecar deferred)"
        )
    }

    // MARK: - Test-host detection

    /// Detects whether this process is hosting an XCTest bundle. XCTest sets
    /// `XCTestConfigurationFilePath` in the environment before spawning the
    /// host app. Preserved from Plan 03 — the `defaultOnEntitlementFailure`
    /// relies on it so the host app doesn't terminate before tests load.
    static var isRunningAsTestHost: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }

    /// Default handler for `onEntitlementFailure` — silent no-op under XCTest
    /// (so the host app doesn't terminate before the test bundle loads) and
    /// the production NSAlert + terminate path otherwise.
    @MainActor
    static func defaultOnEntitlementFailure() {
        if isRunningAsTestHost { return }
        TCCAlertService.presentHardBlock(
            title: "Jarvis can't start",
            informativeText: """
            A build verification check failed at launch. The app has been \
            stopped to prevent a crash. Reinstall Jarvis or rebuild from source \
            with the correct entitlements.
            """
        )
        NSApp.terminate(nil)
    }

    // MARK: - Installers

    private func installMenuBar() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem = item
        let menu = MenuBarContextMenu.build(
            setupAction: { [weak self] in self?.openWizard(firstLaunch: false) },
            settingsAction: { [weak self] in self?.openSettings() },
            devOverlayToggleAction: { [weak self] in self?.toggleDevOverlay() },
            stateDumpAction: { [weak self] in self?.copyStateDump() },
            statusAction: { [weak self] in self?.openStatusPanel() }
        )
        let controller = MenuBarIconController(statusItem: item, contextMenu: menu)
        controller.setLeftClickAction { [weak self] in self?.toggleHUD() }
        menuBarController = controller
    }

    private func installHUDPanel() {
        let panel = JarvisHUDPanel()
        panel.orderOut(nil)
        hudPanel = panel
    }

    private func installBannerPanel() {
        let panel = HUDBannerPanel()
        panel.orderOut(nil)
        bannerPanel = panel
        bannerCoordinator = HUDBannerCoordinator(panel: panel)
    }

    /// Summons or dismisses the HUD panel. Gated on
    /// `WebviewBridge.handshakeState == .armed` — any other state means
    /// the JS side hasn't acknowledged `hello`, so popping the panel
    /// would show an unresponsive black window. The banner path is the
    /// graceful fallback.
    private func toggleHUD() {
        guard let panel = hudPanel else { return }
        if let bridge = webviewBridge, bridge.handshakeState != .armed {
            bannerCoordinator?.enqueue(BannerContent(
                id: "hud-not-ready",
                priority: 2,
                title: "HUD not ready",
                body: "The bus handshake is still completing. Try again in a moment.",
                action: nil
            ))
            return
        }
        if panel.isSummoned { panel.dismiss() } else { panel.summon() }
    }

    /// XCTest seam — drives `toggleHUD()` without reaching for
    /// `perform(Selector(...))`. Production callers are the menu-bar
    /// left-click action and the hotkey binder.
    func exposedToggleHUD() { toggleHUD() }

    // MARK: - Bus wiring

    /// Wires Swift ↔ JS. Called once during
    /// `applicationWillFinishLaunching` after `installHUDPanel()`. Owns:
    ///
    ///   1. The `WKNavigationDelegate` that fires the handshake on first
    ///      `didFinish`.
    ///   2. The `WebviewBridge` (handshake callbacks: `armed` →
    ///      `coordinator.markReady()` + `onBusArmed`; mismatch/timeout →
    ///      `TCCAlertService.presentHardBlock` + `onHandshakeMismatch`).
    ///   3. The single-writer `HudStateCoordinator` with three dormant
    ///      producer streams (agent / voice / confirmation — later
    ///      subsystems swap them out).
    ///   4. The `onInbound` dispatcher (HUD camera button →
    ///      `requestAttach`; chat panel `submit`/`cancelAndSubmit` →
    ///      agent text path).
    ///   5. Loading the R3F bundle's `index.html` from `webview/` in the
    ///      app bundle. Missing entry HTML is a hard-block (no recovery
    ///      path) except under XCTest, where the bundle resources may be
    ///      absent.
    ///
    /// The `bus-harness.html` entry stays in the bundle for the bus
    /// protocol parity script and dev debugging; production loads
    /// `index.html`.
    /// (audit trail: Plan 02-03 bridge + Plan 03-05 coordinator wiring.)
    private func installBus() {
        guard let panel = hudPanel else {
            systemLogger?.error("installBus called before hudPanel exists")
            return
        }

        // Navigation delegate: fires handshake on first didFinish.
        let navDelegate = BridgeNavigationDelegate { [weak self] in
            self?.webviewBridge?.startHandshake()
        }
        bridgeNavigationDelegate = navDelegate
        panel.webView.navigationDelegate = navDelegate

        let bridge = WebviewBridge(
            webView: panel.webView,
            alertPresenter: { [weak self] title, body in
                TCCAlertService.presentHardBlock(title: title, informativeText: body)
                self?.onHandshakeMismatch()
            }
        )
        webviewBridge = bridge

        // HUD-08 coordinator: single Swift-side writer of HudState. The emit
        // closure bridges App.HudState → Bus.HudState (rawValue round-trip)
        // and dispatches to the webview bridge on the MainActor. `[weak
        // bridge]` avoids a retain cycle with `self` via the bridge.
        let coordinator = HudStateCoordinator(emit: { [weak bridge] appState in
            guard let bridge else { return }
            Task { @MainActor in
                try? await bridge.send(.hudState(busHudState(from: appState)))
            }
        })

        // Dormant producer streams. Phase 4 replaces `agentStream` with the
        // orchestrator's intent emitter; Phase 5 replaces `confirmStream`
        // with the ConfirmationBroker; Phase 6 replaces `voiceStream` with
        // the VoiceController. The continuations are retained on self so the
        // coordinator's subscriber tasks stay live (see property docs).
        let (agentStream, agentCont) = AsyncStream<AgentHudIntent>.makeStream()
        let (voiceStream, voiceCont) = AsyncStream<VoiceHudIntent>.makeStream()
        let (confirmStream, confirmCont) = AsyncStream<ConfirmHudIntent>.makeStream()
        dormantAgentContinuation = agentCont
        dormantVoiceContinuation = voiceCont
        dormantConfirmContinuation = confirmCont
        coordinator.start(agent: agentStream, voice: voiceStream, confirmation: confirmStream)
        hudStateCoordinator = coordinator

        bridge.onHandshakeArmed = { [weak self] in
            self?.systemLogger?.info("bus handshake armed — HUD ready")
            // Promote the HUD off `.booting` as soon as the webview is
            // responsive. Without markReady(), the coordinator stays pinned
            // at `.booting` by the RESEARCH Open Q #4 boot gate.
            self?.hudStateCoordinator?.markReady()
            self?.onBusArmed?()
        }

        // Plan 09-02 / D-15 — inbound dispatch. The HUD camera-icon button
        // posts `BusInbound.frameAttachRequested`; route it into
        // `FrameAttachController.requestAttach(reason: .hudButton)`.
        //
        // Plan 09-04 / D-12 — chat-panel inbound. `chatSubmit` and
        // `chatCancelAndSubmit` route into the AgentOrchestrator's text
        // submit paths; rejection outcomes surface as `submitRejected`
        // toasts via `handleTextOutcome`.
        bridge.onInbound = { [weak self] inbound async throws -> BusReply? in
            guard let self else { return nil }
            switch inbound {
            case .helloAck, .uiReady:
                // helloAck is intercepted inline by WebviewBridge; uiReady is
                // a no-op marker. Both arrive here for consistency.
                return nil
            case .frameAttachRequested:
                await self.frameAttachController?.requestAttach(reason: .hudButton)
                return .success
            case .chatSubmit(let text):
                await self.handleChatSubmit(text)
                return .success
            case .chatCancelAndSubmit(let text):
                await self.handleChatCancelAndSubmit(text)
                return .success
            }
        }

        // Load the R3F bundle. Missing index.html is a hard-block — without
        // it the HUD cannot render anything and there's no recovery path.
        webviewEntryFilename = "index"
        guard let entryURL = Bundle.main.url(
            forResource: webviewEntryFilename,
            withExtension: "html",
            subdirectory: "webview"
        ) else {
            // Under XCTest the bundled resources may be absent from the test
            // host — skip the loadFileURL step so tests can assert bridge +
            // coordinator construction without tripping the hard-block modal
            // (02-03 deviation #5 pattern, preserved).
            if AppDelegate.isRunningAsTestHost {
                systemLogger?.warning(
                    "\(webviewEntryFilename).html not in test bundle — skipping loadFileURL (XCTest)"
                )
                return
            }
            systemLogger?.critical(
                "\(webviewEntryFilename).html missing from bundle — cannot start HUD"
            )
            TCCAlertService.presentHardBlock(
                title: "Jarvis can't start",
                informativeText:
                    "Bundle is missing \(webviewEntryFilename).html. Rebuild Jarvis from source."
            )
            NSApp.terminate(nil)
            return
        }
        let resourcesDir = entryURL.deletingLastPathComponent()
        panel.webView.loadFileURL(entryURL, allowingReadAccessTo: resourcesDir)
    }

    // MARK: - Wizard

    /// `BannerSink` adapter so `InputMonitoringProbe` (Shell) can enqueue onto
    /// the `HUDBannerCoordinator` (App) without Shell depending on App types.
    private final class AdHocBannerSink: InputMonitoringProbe.BannerSink, @unchecked Sendable {
        weak var coordinator: HUDBannerCoordinator?
        init(_ c: HUDBannerCoordinator?) { self.coordinator = c }
        func enqueueInputMonitoringDenied() {
            Task { @MainActor [weak self] in
                self?.coordinator?.enqueue(.inputMonitoringDenied)
            }
        }
    }

    /// CR-03 (SHELL-06) / WR-06: `HotkeyBinder.BannerSink` adapter so Shell
    /// can report a silent nil-token bind failure to the HUD. Separate from
    /// `AdHocBannerSink` because the two sinks implement different Shell
    /// protocols — same wiring pattern, different enqueued banner.
    private final class HotkeyBindFailedSink: HotkeyBinder.BannerSink, @unchecked Sendable {
        weak var coordinator: HUDBannerCoordinator?
        init(_ c: HUDBannerCoordinator?) { self.coordinator = c }
        func enqueueHotkeyBindFailed() {
            Task { @MainActor [weak self] in
                self?.coordinator?.enqueue(.hotkeyBindFailed)
            }
        }
    }

    private func openWizard(firstLaunch: Bool) {
        guard let controller = wizardController else { return }
        let validator = AnthropicKeyValidator()
        controller.open(
            keychain: keychainStore,
            validator: validator,
            onGrantInputMonitoring: { [weak self] in
                guard let self else { return false }
                let probe = InputMonitoringProbe(probe: self.hidProbe)
                return probe.check(sink: AdHocBannerSink(self.bannerCoordinator))
            },
            onComplete: { [weak self] in
                self?.bindHotkeyFromWizard()
            },
            firstLaunch: firstLaunch
        )
    }

    private func openSettings() {
        guard let controller = settingsWindowController else { return }
        let validator = AnthropicKeyValidator()
        controller.open(
            keychain: keychainStore,
            validator: validator,
            onGrantInputMonitoring: { [weak self] in
                guard let self else { return false }
                let probe = InputMonitoringProbe(probe: self.hidProbe)
                return probe.check(sink: AdHocBannerSink(self.bannerCoordinator))
            },
            onHotkeyChanged: { [weak self] _ in
                // The hotkey edit has already written through to
                // `WizardState.hotkey`/UserDefaults; rebind the global
                // monitor so the new shortcut takes effect immediately
                // without requiring a relaunch.
                self?.bindHotkeyFromWizard()
            }
        )
    }

    private func bindHotkeyFromWizard() {
        guard let state = wizardState, let shortcut = state.hotkey else { return }
        // WR-06 / CR-03: wire the hotkey-bind-failed sink so that a silent
        // nil-token return from `addGlobalMonitorForEvents` actually surfaces
        // `BannerContent.hotkeyBindFailed` to the user. Before this, the
        // preset existed but was never enqueued from production code.
        let sink = HotkeyBindFailedSink(bannerCoordinator)
        hotkeyBinder?.bind(
            shortcut,
            inputMonitoringGranted: state.inputMonitoringGranted,
            bindFailedSink: sink
        ) { [weak self] in
            Task { @MainActor [weak self] in self?.toggleHUD() }
        }
    }

    // MARK: - Menu-bar actions

    /// Lazily constructed on first toggle so the panel doesn't allocate
    /// resources during launch. Dependencies (emitter, boot-health,
    /// hud-state reader) are captured at construction; if the user opens
    /// the overlay before `installAgent` has built the emitter, the panel
    /// will still render — it just won't show agent snapshots until the
    /// emitter exists, and the boot-health pane works regardless.
    private var devOverlayWindow: DevOverlayWindow?

    private func toggleDevOverlay() {
        if devOverlayWindow == nil {
            let hudCoordinator = self.hudStateCoordinator
            // HudState lives in the App target; the overlay package only
            // gets a string. Closure-captured weak reference so the
            // overlay never extends the coordinator's lifetime.
            let reader: @MainActor () -> String = { [weak hudCoordinator] in
                hudCoordinator?.currentStateForTests.rawValue ?? "—"
            }
            devOverlayWindow = DevOverlayWindow(
                emitter: devSnapshotEmitter,
                bootHealthOrchestrator: bootHealthOrchestrator,
                hudStateReader: reader
            )
        }
        devOverlayWindow?.toggle()
    }

    /// Copies a debug state snapshot to the system clipboard. Writes ONLY
    /// boolean presence indicators (`apiKeyStored`, `inputMonitoringGranted`,
    /// `hotkeyBound`). The API key VALUE is never fetched into a local
    /// variable or written anywhere — defense in depth against accidental
    /// leakage into a user's pasted bug report.
    /// (audit trail: SEC-01 / T-04-02.)
    private func copyStateDump() {
        var payload: [String: Any] = [:]
        payload["apiKeyStored"] = (try? keychainStore.get(.anthropic)) != nil
        payload["inputMonitoringGranted"] = wizardState?.inputMonitoringGranted ?? false
        payload["hotkeyBound"] = hotkeyBinder?.currentShortcut != nil
        payload["timestamp"] = ISO8601DateFormatter().string(from: Date())
        let json = (try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted]))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(json, forType: .string)
        bannerCoordinator?.enqueue(BannerContent(
            id: "state-dump-copied",
            priority: 99,
            title: "State dump copied to clipboard",
            body: "",
            action: nil
        ))
    }

    // MARK: - Helpers

    private func configFileURL() -> URL {
        let fm = FileManager.default
        let dir: URL
        if let support = try? fm.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ) {
            dir = support.appendingPathComponent("Jarvis", isDirectory: true)
        } else {
            dir = URL(fileURLWithPath:
                (NSHomeDirectory() as NSString)
                    .appendingPathComponent("Library/Application Support/Jarvis"))
        }
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("config.json")
    }
}

// MARK: - Bridge navigation delegate

/// Minimal `WKNavigationDelegate` that fires a single @MainActor closure
/// when the first navigation completes. Used by `installBus()` to trigger
/// `WebviewBridge.startHandshake()` once `bus-harness.html` has loaded.
///
/// The WKNavigationDelegate protocol method is `nonisolated`; we hop back to
/// the main actor via `MainActor.assumeIsolated` — the same Swift 6 pattern
/// `WebviewBridge` uses for `WKScriptMessageHandlerWithReply`.
@MainActor
private final class BridgeNavigationDelegate: NSObject, WKNavigationDelegate {
    let onDidFinish: @MainActor () -> Void
    init(onDidFinish: @escaping @MainActor () -> Void) {
        self.onDidFinish = onDidFinish
    }
    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        MainActor.assumeIsolated { onDidFinish() }
    }
}

// MARK: - Voice subsystem adapters (Plan 06-05)
//
// These thin adapters bridge the Voice package protocol seams to App-target types.
// Plan 09-04 replaced the three Null placeholder adapters with real production
// adapters in App/Voice/{VoiceOrchestratorAdapter,VoiceTTSAdapter,VoiceBusEmitterAdapter}.swift.

/// Bridges `VoiceBannerInterface` → `HUDBannerCoordinator`.
///
/// `HUDBannerCoordinator` is `@MainActor`. The bridge hops to MainActor internally
/// so `VoiceController` (non-MainActor actor) can call `showBanner` / `dismissBanner`.
/// `@unchecked Sendable` + `nonisolated(unsafe)` because coordinator is a `@MainActor`
/// reference; both `showBanner` and `dismissBanner` dispatch to `@MainActor` via Task.
final class AppDelegateBannerAdapter: VoiceBannerInterface, @unchecked Sendable {
    nonisolated(unsafe) private weak var coordinator: HUDBannerCoordinator?
    init(coordinator: HUDBannerCoordinator?) { self.coordinator = coordinator }

    func showBanner(message: String) {
        let coordinator = coordinator
        Task { @MainActor in
            coordinator?.enqueue(BannerContent(
                id: "voice-aec-banner",
                priority: 10,
                title: "Voice Warning",
                body: message,
                action: nil
            ))
        }
    }

    func dismissBanner() {
        let coordinator = coordinator
        Task { @MainActor in
            coordinator?.dismissCurrent()
        }
    }
}

/// Plan 09-04 fallback when no `webviewBridge` is available at installVoice
/// time (early test harness; pre-handshake degenerate launch). The real
/// production path uses `VoiceBusEmitterAdapter` wrapping an `OutboundBatcher`.
struct DormantVoiceBusEmitter: BusOutboundEmitter {
    func postAudio(_ rms: Float) async {
        // Audio-level emissions are dropped when the bridge is unavailable.
    }
}

// MARK: - Memory subsystem adapters (Plan 07-06)

/// Bridges `Memory.MemoryReplaySink` → `Replay.ReplayLog`.
///
/// The Memory module deliberately does not import `Replay.ReplayLog` directly
/// (07-02 design); AppDelegate is the only place that bridges the two. The
/// adapter forwards a recorded `ReplayEvent` from MemoryStore.applyOp into the
/// on-disk replay log. The log records are TurnID-keyed; the orchestrator
/// records `ReplayEvent.memoryMutation` against an Int64 turnId hash, but the
/// replay log indexes on TurnID. This adapter generates a synthetic TurnID
/// stub from the Int64 hash — once AgentOrchestrator wiring lands the real
/// turn-id correlation will be in place.
struct AppDelegateMemoryReplaySink: MemoryReplaySink {
    let replayLog: ReplayLog

    func record(_ event: ReplayEvent, forTriggerTurnId triggerTurnId: Int64) {
        // The replay log's `record(_:for:)` is async; fire-and-forget through
        // a detached Task so the synchronous MemoryReplaySink contract stays
        // intact. The Int64 trigger-turn-id is encoded as a TurnID's UUID
        // string deterministically (FNV-1a hash → reverse stub) so replay
        // queries can correlate later.
        let synthetic = TurnID(rawValue: "memory-trigger-\(triggerTurnId)")
        Task.detached { [replayLog] in
            await replayLog.record(event, for: synthetic)
        }
    }
}
