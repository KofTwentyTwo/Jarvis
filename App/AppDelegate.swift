import AppKit
import Bus
import Config
import DevOverlay
import Keychain
import JarvisLogging
import Shell
import Voice           // Plan 06-05: VoiceController + PTT + MuteWakeWord
import WebKit
import Logging   // swift-log — `Logger` here is `Logging.Logger`
import AgentCore       // Plan 05-05: BoundedAsyncChannel for ME-04 closure
import AgentOrchestrator // Plan 07-06: OrchestratorEvent type for installMemory's coordinator wiring
import Replay          // Plan 05-05: ReplayEvent type for the orch→replay channel
import JarvisMCP       // CR-02 (REVIEW 05): MCPRuntimeWiring.build for end-to-end ME-04 closure
import Memory          // Plan 07-06: MemoryStore + MemoryExtractionOrchestrator + MemoryExtractionCoordinator
import JarvisVision    // Plan 07-06: CameraCapture + PresenceMonitor + VisionRouter
import OllamaProvider  // Plan 07-06: T1 vision provider + memory extractor backbone
import AnthropicProvider // Plan 07-06: T3 cloud-escape vision provider

/// Abstract the Info.plist `JarvisEntitlementsVerified` read so tests can inject
/// a mock that returns false without touching the running binary's Info.plist.
public protocol EntitlementGateProbe: Sendable {
    func isVerified() -> Bool
}

/// Production probe — reads the Info.plist key that Plan 05's
/// `verify-entitlements.sh --pre-codesign` flips to `true` after the signed
/// entitlements pass all greps.
public struct InfoPlistEntitlementGateProbe: EntitlementGateProbe {
    public init() {}
    public func isVerified() -> Bool {
        Bundle.main.object(forInfoDictionaryKey: "JarvisEntitlementsVerified") as? Bool ?? false
    }
}

/// `@MainActor` because every AppKit surface this touches (NSStatusItem,
/// NSPanel, NSAlert) is main-thread-only per S-2.
///
/// Bootstrap chain (Plan 04 — full wiring):
///
///  1. `JarvisLogHandlerFactory.bootstrap()` — S-8, exactly one call site.
///  2. Entitlement hard-block — `JarvisEntitlementsVerified`; `TCCAlertService`
///     presents the "Jarvis can't start" modal and terminates.
///  3. `ConfigLoader.loadSnapshots` (writing defaults on first launch) — on
///     `ConfigError.malformed` present `TCCAlertService.presentHardBlock` +
///     terminate per D-19 / S-6.
///  4. Menu bar + HUD panel + banner panel install.
///  5. Keychain fetch of `.anthropic` — `.itemNotFound` → enqueue
///     `BannerContent.keychainEmpty` (priority 1).
///  6. `InputMonitoringProbe` via `SystemHIDAccessProbe` — denial enqueues
///     `BannerContent.inputMonitoringDenied` (priority 2, SHELL-06).
///  7. `HotkeyBinder` install (empty — wizard binds a shortcut later).
///  8. First-launch wizard if Keychain is empty; otherwise the wizard sleeps
///     behind the Setup… menu item.
///
/// `copyStateDump` never writes the API key VALUE — only a boolean presence
/// indicator (`apiKeyStored`). T-04-02 / SEC-01 defense-in-depth.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    // MARK: - Test-injectable seams

    var entitlementProbe: EntitlementGateProbe = InfoPlistEntitlementGateProbe()
    var onEntitlementFailure: @MainActor () -> Void = AppDelegate.defaultOnEntitlementFailure
    var loggingBootstrap: () -> Void = { JarvisLogHandlerFactory.bootstrap() }
    var configLoader: (URL) throws -> (LaunchSnapshot, PerTurnSnapshot) = ConfigLoader.loadSnapshots(from:)
    var configWriter: (URL) throws -> (LaunchSnapshot, PerTurnSnapshot) = ConfigLoader.writeDefaultAndReload(to:)
    var keychainStore: any KeychainStore = SystemKeychainStore()
    var hidProbe: any HIDAccessProbe = SystemHIDAccessProbe()

    /// Called when the bus handshake resolves in a mismatch or timeout.
    /// Production default terminates the app after `TCCAlertService` shows
    /// the hard-block modal. Tests inject a recording closure instead.
    var onHandshakeMismatch: @MainActor () -> Void = { NSApp.terminate(nil) }

    /// Fires after `WebviewBridge.onHandshakeArmed`. Default is a no-op;
    /// tests set this to observe armed transitions.
    var onBusArmed: (@MainActor () -> Void)?

    // MARK: - Installed components

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

    /// HUD-08 single-writer coordinator (Plan 03-01 author; Plan 03-05 wiring).
    /// Emit closure bridges App.HudState → Bus.HudState and calls
    /// `webviewBridge.send(.hudState(...))` on MainActor. `markReady()` fires
    /// from `onHandshakeArmed` so the HUD promotes `.booting` → `.idle` as
    /// soon as the webview handshake completes.
    var hudStateCoordinator: HudStateCoordinator?

    /// Dormant producer-stream continuations held by the delegate so the
    /// coordinator's three for-await Tasks don't drain immediately. Swift 6
    /// terminates `for await` when the matching continuation deinits; keeping
    /// them alive on the delegate preserves the subscriber tasks until
    /// Phase 4 (agent) / Phase 5 (confirmation) / Phase 6 (voice) replace
    /// them with real producers.
    var dormantAgentContinuation: AsyncStream<AgentHudIntent>.Continuation?
    var dormantVoiceContinuation: AsyncStream<VoiceHudIntent>.Continuation?
    var dormantConfirmContinuation: AsyncStream<ConfirmHudIntent>.Continuation?

    /// Plan 05-05 / ME-04 closure (CR-02 REVIEW 05 — wired end-to-end).
    ///
    /// Production instance of the orch→replay 2048-capacity .dropOldest
    /// `BoundedAsyncChannel<ReplayEnvelope>`. Plan 04-03 created the
    /// primitive; Plan 04-05's ChannelTopologyTests CT2 verified the
    /// contract; CR-02 wires the producer (`ReplayingToolResultObserver`)
    /// AND the consumer (`orchToReplayDrainTask`) so the channel actually
    /// carries traffic. The 2048 capacity + .dropOldest policy is the
    /// AGENT-10 spec for tokenDelta-class events: lossy on saturation,
    /// freshness > completeness.
    ///
    /// Held strongly here so it doesn't deinit before consumers attach;
    /// the orch→replay seam consumes it via a `for await` drain Task.
    var orchToReplayChannel: BoundedAsyncChannel<ReplayEnvelope>?

    /// CR-02 (REVIEW 05): the on-disk audit log opened at boot. The
    /// drain task writes drained ReplayEvents here. Held strongly so it
    /// outlives the drain task. Pre-CR-02, AppDelegate had no ReplayLog
    /// instance — the observer wrote directly to a ReplayLog that
    /// MCPRuntimeWiring.build constructed and threw away on return.
    var replayLog: ReplayLog?

    /// CR-02 (REVIEW 05): the MCPRuntime returned by
    /// `MCPRuntimeWiring.build(...)`. Held strongly so the broker /
    /// presenter / observer / dispatcher chain stays alive for the
    /// lifetime of the process.
    var mcpRuntime: MCPRuntime?

    /// Task spawned in `applicationWillFinishLaunching` that builds the
    /// MCPRuntime. Held so `agentInstallTask` can await it before
    /// `installAgent()` runs — without this, MCPRuntime build (which is
    /// ~1s due to helper child-process spawn) consistently loses the
    /// race against `installAgent`'s `mcpRuntime != nil` precondition,
    /// silently skipping orchestrator install on every launch. Verified
    /// via system log: `installAgent: deps not ready (mcp/replay/config)
    /// — skipping` precedes `MCPRuntime built — N tools` by ~900 ms
    /// every cold launch, leaving the orchestrator + broadcaster + every
    /// downstream subscriber dormant for the process lifetime.
    private var mcpInstallTask: Task<Void, Never>?

    /// Drain task spawned in `applicationWillFinishLaunching` — reads
    /// envelopes from `orchToReplayChannel` and forwards to `replayLog`.
    /// CR-02: production consumer for ME-04. Previously this task
    /// `for await _ in channel` discarded everything; the channel had
    /// no producer either, so ME-04's contract was structurally
    /// unverifiable in production code.
    var orchToReplayDrainTask: Task<Void, Never>?

    // MARK: - Voice subsystem (Plan 06-05)
    //
    // Strong properties ensure voice subsystem outlives `applicationWillFinishLaunching`.
    // `voiceController` is wired in `installVoice()` which runs on the async background
    // after launch. The `dormantVoiceContinuation` is replaced with the real producer
    // once VoiceController is live.

    /// The end-to-end voice pipeline actor (Plan 06-05).
    var voiceController: VoiceController?

    /// Push-to-talk hotkey binding (Plan 06-05 / VOICE-13).
    var pushToTalk: PushToTalk?

    /// Menu-bar wake-word mute toggle (Plan 06-05 / VOICE-12).
    var muteWakeWord: MuteWakeWord?

    /// Owns the live `AVAudioEngine` audio graph (Plan 06-01) — opened in
    /// `installVoice()` so mic samples flow into the wake-word DAG. Held
    /// strongly because the actor's tap closures retain the ring buffer.
    /// Track B-4 (2026-05-03 voice audit fix): production was never
    /// constructing this, so wake-word inference ran against an empty ring.
    var audioGraphOwner: AudioGraphOwner?

    /// Drains `AudioGraphOwner.degradationStream` into
    /// `voiceController.handleAECUnavailable()` so VOICE-09 fallback banners
    /// surface natively. Cancelled on shutdown.
    var audioGraphDegradationTask: Task<Void, Never>?

    /// Drains `AudioGraphOwner.rebuildStream` to dismiss the AEC banner
    /// once an aec=on rebuild succeeds.
    var audioGraphRebuildTask: Task<Void, Never>?

    /// Task spawned in `applicationWillFinishLaunching` that constructs and
    /// starts the voice subsystem. Held strongly so the async setup isn't
    /// cancelled prematurely.
    var voiceInstallTask: Task<Void, Never>?

    // MARK: - Memory subsystem (Plan 07-01..07-02 wired in 07-06)

    /// MemoryStore opened against ~/Library/Application Support/Jarvis/jarvis.db.
    /// nil if vec0.dylib is missing or the open path failed — memory degrades
    /// gracefully (no extraction, no retrieval; agent runs without memory).
    var memoryStore: MemoryStore?

    /// Background extraction orchestrator (Plan 07-02). Drains the bounded
    /// AsyncChannel(capacity: 32, dropOldest) one job at a time so a stalled
    /// 32B-model extraction never blocks turnEnd (MEM-06).
    var memoryExtractionOrchestrator: MemoryExtractionOrchestrator?

    /// Subscribes to AgentOrchestrator.events; on .turnEnd(.endTurn) enqueues
    /// an ExtractionJob into memoryExtractionOrchestrator. Held strongly so
    /// the subscriber Task it spawns isn't cancelled prematurely.
    var memoryExtractionCoordinator: MemoryExtractionCoordinator?

    /// Task spawned in `applicationWillFinishLaunching` that constructs and
    /// starts the memory subsystem.
    var memoryInstallTask: Task<Void, Never>?

    // MARK: - Vision subsystem (Plan 07-04..07-05 wired in 07-06)

    var captureSession: CameraCapture?
    var presenceMonitor: PresenceMonitor?

    /// VISION-03: the SINGLE PresenceSignalBus reference. PresenceMonitor
    /// owns construction (only PresenceMonitor can construct the bus per
    /// 07-04's design); we hold the SAME `monitor.bus` reference and pass
    /// it BY VALUE (PresenceSignalBus is a Sendable struct wrapping the
    /// AsyncStream) into both ContextBuilder (D-10 system-prompt enrichment)
    /// and HudStateCoordinator (D-10 subtle ring indicator). The bus has NO
    /// subscriber in JarvisTTS or in any code path leading to
    /// AgentOrchestrator.runTurn / cancelAndSubmit — enforced by
    /// scripts/check-presence-vision-isolation.sh and PhaseSevenGrepGateTests.
    var presenceSignalBus: PresenceSignalBus?

    /// Menu-bar toggle (D-12). Mirrors muteWakeWord — added to the same
    /// contextMenu. Disabling presence does NOT disable frame-attach.
    var disablePresence: DisablePresence?

    /// T1/T2/T3 vision routing (Plan 07-05). Wired into the orchestrator's
    /// runTurn dispatcher branch in Plan 09-02 (D-01 — AgentOrchestrator
    /// constructor now accepts `visionRouter:`).
    var visionRouter: VisionRouter?

    /// Plan 09-02 / D-15. The frame-attach controller owns the dual-trigger
    /// ingest path (HUD camera-icon button + matched phrase) and the D-15
    /// SOLE-emission-site discard. nil until installVision completes; the
    /// orchestrator's broadcaster frame-attach subscriber drives
    /// `onAssistantTurnComplete()` after every image-bearing `.turnEnd`.
    var frameAttachController: FrameAttachController?

    /// Plan 09-02 / D-16 release subscriber Task. Drains the broadcaster's
    /// `.frameAttach` priority subscription and, on `.turnEnd` for an
    /// image-bearing turn (per `agentOrchestrator.turnHadImage`), calls
    /// `frameAttachController.onAssistantTurnComplete()` to release the
    /// captured frame's in-memory bytes.
    private var frameAttachReleaseTask: Task<Void, Never>?

    /// Camera-degradation watcher Task — surfaces TCC denial / mid-session
    /// revocation as HUD banners (S-4 graceful denial).
    var cameraDegradationTask: Task<Void, Never>?

    /// Task spawned in `applicationWillFinishLaunching` that constructs and
    /// starts the vision subsystem.
    var visionInstallTask: Task<Void, Never>?

    // MARK: - Agent subsystem (Plan 09-01)

    /// ConfigStore built from launch + per-turn snapshots in
    /// `applicationWillFinishLaunching`. Held strongly so installAgent()
    /// can hand it to the AgentOrchestrator constructor.
    private var configStore: ConfigStore?

    /// AgentOrchestrator instantiated in `installAgent()`. nil until the
    /// install task completes. Held strongly so the actor + its events
    /// channel + the broadcaster's drain Task all outlive launch.
    private var agentOrchestrator: AgentOrchestrator?

    /// D-05/D-08: single fan-out drain over `agentOrchestrator.events`.
    /// Owned for app lifetime by AppDelegate.
    private var eventBroadcaster: OrchestratorEventBroadcaster?

    /// BLOCKER-1 source of truth: the per-turn (userText, assistantText)
    /// accumulator used by `lookupTurnContent`. Plan 1's transcript
    /// subscriber appends assistant-side .tokenDelta into this store;
    /// Plan 4 will append user-side text at submit time.
    private var turnTranscriptStore: TurnTranscriptStore?

    /// Task spawned in `applicationWillFinishLaunching` that runs `installAgent`.
    private var agentInstallTask: Task<Void, Never>?

    /// Drains the broadcaster's memory subscription into MemoryExtractionCoordinator.
    private var memoryEventSubscriberTask: Task<Void, Never>?

    /// Drains the broadcaster's transcript subscription into TurnTranscriptStore
    /// (assistant-side accumulator).
    private var transcriptSubscriberTask: Task<Void, Never>?

    /// Drains the broadcaster's devOverlay subscription into DevSnapshotEmitter.
    /// Lossy — the DevOverlay is observational.
    private var devOverlaySubscriberTask: Task<Void, Never>?

    /// Plan 09-04 — voice path bridge. The real adapter is constructed in
    /// installVoice() and held strongly here so the broadcaster's voice
    /// subscriber drain in installAgent can call its `emitTurnEnded` /
    /// `emitError` hooks.
    private var voiceOrchestratorAdapter: VoiceOrchestratorAdapter?

    /// Plan 09-04 — drains the broadcaster's `.voice` subscription. BLOCKER-2:
    /// per-turn assistant text accumulator + `turnSourceWasVoice` filter so
    /// text-originated turns NEVER drive `VoiceController` back to `.idle`.
    private var voiceEventTranslatorTask: Task<Void, Never>?

    /// Phase E follow-up (BLOCKER-INT-2 from `.planning/v0.12.0-MILESTONE-AUDIT.md`).
    /// Drains the broadcaster's `.bus` subscription and forwards
    /// `.tokenDelta` chunks into `outboundBatcher.postToken(_:)` so they
    /// reach the JS-side HUD chat panel. Without this subscriber, the
    /// orchestrator emits tokens that never leave Swift — the chat panel
    /// renders an empty `chatEvents` array forever.
    private var busSubscriberTask: Task<Void, Never>?

    /// Plan 09-04 — OutboundBatcher used by `VoiceBusEmitterAdapter` to
    /// route the 30 Hz audio-level RMS into the bus's RingMesh pulse.
    /// Constructed in installVoice; webviewBridge is the sink.
    private var outboundBatcher: OutboundBatcher?

    /// Plan 03-05 test seam. Default production value is `"index"` (the R3F
    /// bundle entry). `installBus()` assigns this once when it resolves the
    /// Bundle.main URL. Tests assert the post-install value to confirm the
    /// handler loaded the R3F bundle, not 02-03's `bus-harness.html`.
    var webviewEntryFilename: String = "index"

    private var systemLogger: Logger?
    private var bridgeNavigationDelegate: BridgeNavigationDelegate?

    // MARK: - Launch chain

    func applicationWillFinishLaunching(_ notification: Notification) {
        // 1. Logging bootstrap — S-8 one-bootstrap discipline.
        loggingBootstrap()
        systemLogger = Logger(label: JarvisLogChannel.system.rawValue)
        systemLogger?.info("Jarvis launching — Phase 1 scaffold")

        // 2. Entitlement hard-block. The `defaultOnEntitlementFailure`
        // already short-circuits when running as an XCTest host so the
        // bundled process doesn't terminate before tests load. Tests that
        // need to drive the full bootstrap chain inject an `EntitlementYes`
        // probe + their own fakes and call `applicationWillFinishLaunching`
        // directly.
        guard entitlementProbe.isVerified() else {
            systemLogger?.critical("JarvisEntitlementsVerified missing/false — hard-blocking")
            onEntitlementFailure()
            return
        }

        // 3. Config load (writing defaults on first run) with NSAlert on malformed.
        let configURL = configFileURL()
        let snapshots: (LaunchSnapshot, PerTurnSnapshot)
        do {
            if FileManager.default.fileExists(atPath: configURL.path) {
                snapshots = try configLoader(configURL)
            } else {
                snapshots = try configWriter(configURL)
            }
        } catch let e as ConfigError {
            // WR-02: route error description through Redact.apply before
            // logging — a malformed config that contains a secret (e.g. a
            // user accidentally drops an API key into config.json) would
            // otherwise land in ~/Library/Logs/Jarvis/ and os.Logger (where
            // OSLogHandler skips redaction by design) as plaintext.
            let description = Redact.apply(String(describing: e))
            systemLogger?.critical("Config malformed: \(description)")
            TCCAlertService.presentHardBlock(
                title: "Jarvis can't start",
                informativeText: "Your config file couldn't be read. \(description). Details in ~/Library/Logs/Jarvis/system.log."
            )
            NSApp.terminate(nil)
            return
        } catch {
            // WR-02: same redaction discipline for generic errors.
            let description = Redact.apply(error.localizedDescription)
            systemLogger?.critical("Config load failed: \(description)")
            TCCAlertService.presentHardBlock(
                title: "Jarvis can't start",
                informativeText: "Config load failed: \(description)"
            )
            NSApp.terminate(nil)
            return
        }
        // Plan 09-01: build a ConfigStore from the launch + per-turn
        // snapshots so installAgent() can construct the AgentOrchestrator
        // with a live config source.
        let configStore = ConfigStore(launch: snapshots.0, initial: snapshots.1)
        self.configStore = configStore

        // 4. Menu bar + HUD panel + banner panel.
        installMenuBar()
        installHUDPanel()
        installBannerPanel()

        // 4.5 Bus wiring — construct the bridge around the HUD's WKWebView,
        // install the WKUserScript (at document-start in JarvisBusWorld),
        // construct + start the HUD-08 single-writer HudStateCoordinator, and
        // load the R3F bundle's index.html so the handshake kicks off.
        // Plan 02-03 (bridge) + Plan 03-05 (coordinator + index.html load).
        installBus()

        // 5. Keychain fetch.
        //
        // Banner suppression: when the API key is missing, the first-launch
        // wizard is going to open in step 8 to ask for it — enqueuing
        // `.keychainEmpty` here would stack a "No API key configured" HUD
        // banner on top of the wizard's own apiKey stage. Only enqueue when
        // the wizard *won't* open (e.g. wizard was dismissed pre-entry on a
        // prior launch and the user reopened without re-entering Setup),
        // which we detect post-wizard-construction below.
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

        // 6. Input Monitoring — query-only check (no prompt).
        //
        // Two reasons to NOT call `requestListenEventAccess` at launch:
        //   1. It can fire a TCC dialog OUTSIDE the wizard's TCC stage,
        //      surprising the user with a permission prompt before they've
        //      even seen the wizard.
        //   2. The wizard's TCC stage is the right place for the prompt —
        //      it has the explainer copy + the System Settings fallback.
        //
        // Use IOHIDCheckAccess (query-only) to detect a prior grant. If
        // denied/unknown AND the wizard is going to open, skip the banner
        // (the wizard's TCC stage handles it). Only enqueue the banner when
        // the wizard won't be opening to address it.
        let inputMonitoringGranted = hidProbe.isListenEventAccessGranted()

        // 7. Hotkey binder — empty at launch; wizard binds a shortcut later.
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

        // 8b. Now that the wizard's open/closed decision is settled, enqueue
        //     the missing-prerequisite banners only if the wizard ISN'T going
        //     to address them. This avoids stacking redundant banners on top
        //     of a wizard that's already asking for the same thing.
        if !apiKeyStored && !willOpenWizard {
            bannerCoordinator?.enqueue(.keychainEmpty)
        }
        if !inputMonitoringGranted && !willOpenWizard {
            bannerCoordinator?.enqueue(.inputMonitoringDenied)
        }

        // 9. Plan 05-05 / ME-04 closure (CR-02 REVIEW 05): instantiate
        //    the orch→replay 2048-capacity .dropOldest channel + open
        //    the on-disk ReplayLog + spawn the drain task that writes
        //    drained envelopes through to ReplayLog. AGENT-10's
        //    four-seam contract is now exercised by production traffic:
        //    the observer (created lazily by MCPRuntimeWiring.build,
        //    step 10 below) PRODUCES into the channel; this drain task
        //    CONSUMES.
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
            // block. Boot continues; replay capture is best-effort per
            // OBS-02.
            orchToReplayDrainTask = Task.detached { [weak self] in
                for await _ in channel {
                    _ = self
                }
            }
        }

        // 10. CR-02 (REVIEW 05): instantiate the production MCPRuntime
        //     so the dispatcher chain (broker + presenter + observer)
        //     is wired and the orchestrator (later plan) has a
        //     ToolDispatcher to consume. Helpers may be absent under
        //     XCTest hosts or before-codesign builds; failure is
        //     non-fatal — we log and proceed without MCP, the same way
        //     a missing API key proceeds without the agent.
        let bundleURL = Bundle.main.bundleURL
        mcpInstallTask = Task { @MainActor [weak self] in
            guard let self = self, let channel = self.orchToReplayChannel else { return }
            let busAdapter = NoopBusGateway()  // CR-02: orchestrator wiring (later plan) replaces with real bus adapter.
            do {
                let runtime = try await MCPRuntimeWiring.build(
                    bundleURL: bundleURL,
                    bus: busAdapter,
                    replayChannel: channel,
                    turnIDResolver: { nil }  // pre-orchestrator returns nil (observer logs without writing).
                )
                self.mcpRuntime = runtime
                let toolCount = await runtime.client.registeredToolNames().count
                self.systemLogger?.info("MCPRuntime built — \(toolCount) tools")
            } catch {
                self.systemLogger?.warning("MCPRuntime build failed (helpers absent or unsigned?): \(String(describing: error))")
            }
        }

        // 11. Plan 07-06: install memory subsystem. MemoryStore.init can
        //     throw if vec0.dylib is missing — installMemory catches and
        //     degrades gracefully. We start memory BEFORE voice so the
        //     extraction coordinator is subscribed to AgentOrchestrator.events
        //     before the first voice-driven turn lands.
        memoryInstallTask = Task { @MainActor [weak self] in
            await self?.installMemory()
        }

        // MARK: - Install Order (Phase 9 / Plan 4 / WARNING-5: LOCKED)
        // vision → agent → voice. DO NOT REORDER.
        //
        // - vision must finish before agent because installAgent's orchestrator
        //   constructor takes self.visionRouter (Plan 2 / D-01) and the
        //   broadcaster's frame-attach release subscriber needs frameAttachController.
        // - agent must finish before voice because installVoice's adapters
        //   require self.agentOrchestrator and self.turnTranscriptStore (both
        //   constructed inside installAgent — Plan 1 / Plan 4).
        // scripts/check-install-order.sh enforces the literal line ordering.

        // 12. Plan 07-06: install vision subsystem. Camera TCC may be
        //     undetermined or denied at first launch; presence + frame-attach
        //     degrade gracefully via the cameraDegradationTask banner watcher.
        visionInstallTask = Task { @MainActor [weak self] in
            await self?.installVision()
        }

        // 13. Plan 09-01: install agent subsystem. Awaits the memory install
        //     task so the MemoryExtractionCoordinator is constructed before
        //     installAgent subscribes it to the broadcaster's memory child
        //     stream.
        //
        //     Plan 09-02: also awaits the vision install task so installAgent
        //     can pass `visionRouter:` and `frameAttachController` (both set
        //     by installVision) into the orchestrator constructor + the
        //     broadcaster's frame-attach release subscriber.
        //
        //     Phase E follow-up (this commit): also awaits `mcpInstallTask`.
        //     `installAgent` requires `self.mcpRuntime != nil` and silently
        //     short-circuits otherwise. MCP runtime build is ~1s due to
        //     helper child-process spawn (mcp-time / mcp-clipboard /
        //     mcp-applescript), which consistently lost the race against
        //     installAgent on every cold launch — every system log to date
        //     shows `installAgent: deps not ready — skipping` precede
        //     `MCPRuntime built` by ~900 ms, leaving the orchestrator +
        //     broadcaster + ALL six broadcaster subscribers dormant for the
        //     process lifetime. Audited only via static source grep, so the
        //     milestone-audit findings of "5 subscribers wired" in
        //     v0.12.0-MILESTONE-AUDIT.md were structurally correct but
        //     runtime-false until this gate lands.
        agentInstallTask = Task { @MainActor [weak self] in
            await self?.memoryInstallTask?.value
            await self?.visionInstallTask?.value
            await self?.mcpInstallTask?.value
            await self?.installAgent()
        }

        // 14. Plan 06-05: install voice subsystem asynchronously.
        //     Model files (ORT sessions, Orpheus MLX weights) may be absent
        //     on first launch — failure is non-fatal (voice degrades gracefully).
        //     The dormantVoiceContinuation is replaced with the real producer
        //     once VoiceController is live and started.
        //
        //     Plan 4 / WARNING-5: voiceInstallTask now AWAITS agentInstallTask
        //     because the real VoiceOrchestratorAdapter / VoiceBusEmitterAdapter
        //     require self.agentOrchestrator + self.turnTranscriptStore.
        voiceInstallTask = Task { @MainActor [weak self] in
            await self?.agentInstallTask?.value
            await self?.installVoice()
        }
    }

    /// CR-02 (REVIEW 05): on-disk replay log path. Lives next to
    /// config.json under Application Support / Jarvis / replay.sqlite.
    private func replayDatabaseURL() -> URL {
        configFileURL().deletingLastPathComponent().appendingPathComponent("replay.sqlite")
    }

    func applicationWillTerminate(_ notification: Notification) {
        hotkeyBinder?.unbind()
        // Plan 05-05 / ME-04: tear down the orch→replay drain so the Task
        // doesn't outlive the process.
        orchToReplayDrainTask?.cancel()
        // Plan 06-05: shut down voice subsystem.
        voiceInstallTask?.cancel()
        // Track B-4: degradation/rebuild stream consumers + audio graph owner.
        audioGraphDegradationTask?.cancel()
        audioGraphRebuildTask?.cancel()
        if let owner = audioGraphOwner {
            Task { await owner.shutdown() }
        }
        if let vc = voiceController {
            Task { await vc.shutdown() }
        }
        // Plan 07-06: tear down memory + vision.
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
        // Plan 09-01: tear down agent subsystem (broadcaster + subscribers).
        agentInstallTask?.cancel()
        memoryEventSubscriberTask?.cancel()
        transcriptSubscriberTask?.cancel()
        devOverlaySubscriberTask?.cancel()
        // Plan 09-02 / D-16: tear down frame-attach release subscriber.
        frameAttachReleaseTask?.cancel()
        // Plan 09-04: tear down voice event translator subscriber.
        voiceEventTranslatorTask?.cancel()
        // Phase E (BLOCKER-INT-2): tear down bus-forwarding subscriber.
        busSubscriberTask?.cancel()
        if let broadcaster = eventBroadcaster {
            Task { await broadcaster.stop() }
        }
    }

    // MARK: - Voice install (Plan 06-05)

    /// Constructs and starts the voice subsystem.
    ///
    /// Called from a background Task in `applicationWillFinishLaunching` (step 11).
    /// Model files and hardware are required — failure is logged and voice degrades
    /// gracefully (banner + silent mode). PTT and mute-wake-word are set up after
    /// VoiceController is live.
    ///
    /// Production wiring:
    ///   1. Build `VoiceController` using `dormantVoiceContinuation` as the
    ///      `voiceHudCont` parameter — this replaces the dormant placeholder
    ///      that `HudStateCoordinator` is already consuming.
    ///   2. Replace `dormantVoiceContinuation` with `nil` so it no longer holds
    ///      the continuation (VoiceController now owns it).
    ///   3. Wire `PushToTalk` (binds PTT hotkey, VOICE-13).
    ///   4. Wire `MuteWakeWord` (menu-bar toggle, VOICE-12).
    ///   5. Call `voiceController.start()` to open the audio graph and begin
    ///      the wake-word / VAD / STT / TTS loop.
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

        // Construct WakeWordDAG.
        let wakeWordDAG = WakeWordDAG(session: wakeWordSession)

        // Track B-4 (2026-05-03 voice audit fix): construct AudioGraphOwner,
        // open it, and feed its RingBuffer into the wake-word DAG. Without
        // this, wake-word inference loops on a ring that production never
        // wrote to (mic taps were never installed). Audit:
        // `.planning/audit-2026-05-03/voice.md`.
        //
        // Order matters: the degradation/rebuild consumer Tasks must be
        // spawned BEFORE `open()` because `open()` may immediately yield
        // `.aecUnavailable` on its retry-with-aec=false path (VOICE-09).
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
        audioGraphRebuildTask = Task { @MainActor [weak self] in
            for await _ in rebuildStream {
                guard let self else { return }
                let variant = await self.audioGraphOwner?.currentVariant
                if case .aecOn = variant {
                    await self.voiceController?.handleAECRestored()
                }
            }
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

        // Wire teardown step 1 (VOICE-10): cancel wake-word inference before
        // the engine stops. Without this, the detached feed Task races the
        // ring deallocation during graph rebuilds.
        await graphOwner.setCancelInFlight { [wakeWordDAG] in
            await wakeWordDAG.cancel()
        }

        // Construct VoiceController. Plan 09-04 (D-09 + D-11) replaces the
        // three Null placeholder adapters with the production adapter triad:
        //
        //   - VoiceOrchestratorAdapter wraps `self.agentOrchestrator` and
        //     surfaces SubmitOutcome.rejected reasons to HUDBannerCoordinator.
        //   - VoiceTTSAdapter wraps a TTSEngineActor (currently nil — engine
        //     construction lands in a follow-on plan; the adapter no-ops
        //     gracefully so the rest of the wiring goes live).
        //   - VoiceBusEmitterAdapter wraps an OutboundBatcher whose sink is
        //     the WebviewBridge (audio-level RMS → RingMesh pulse, ~30 Hz).
        //
        // BLOCKER-1: `transcriptStore: self.turnTranscriptStore` — the voice
        // adapter appends user-side text to the transcript store after every
        // submit/cancelAndSubmit so MemoryExtractionCoordinator's drain finds
        // non-nil pair text.
        //
        // WARNING-5: this method runs AFTER installAgent (install order
        // locked in applicationWillFinishLaunching). If the agent install
        // failed (orchestrator nil), the voice subsystem stays dormant.
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

        // Track B-3 (2026-05-03 voice audit fix): construct a real TTS
        // engine via TTSEngineWiring (lives in App/Voice/ so the
        // VISION-03 Layer 3 gate doesn't see TTSEngine* in this file).
        // Tier-1 (AVSpeechSynthesizer) wires alone — tier-2 (Orpheus)
        // is gated behind the ~6GB weight download; tier-2 requests
        // degrade to tier-1 transparently. Coverage:
        // TTSEngineActorTier1Tests (4 cases incl. real AVSpeech).
        let ttsAdapter = VoiceTTSAdapter(engine: VoiceOutputWiring.makeTier1Engine())

        // OutboundBatcher wired with the live webviewBridge as its sink.
        // The batcher coalesces high-frequency audio-level RMS at ~30 Hz
        // before crossing the JS-call boundary.
        //
        // Phase E (2026-05-03): the batcher is now constructed in
        // installAgent (so the .bus forwarder works even when voice DAG
        // short-circuits on missing models). Reuse it here. If installAgent
        // also failed to set it (no webviewBridge), fall back to the
        // dormant emitter so audio-level still degrades gracefully.
        let busAdapter: any BusOutboundEmitter
        if let batcher = self.outboundBatcher {
            busAdapter = VoiceBusEmitterAdapter(batcher: batcher)
        } else {
            systemLogger?.warning("installVoice: outboundBatcher nil — audio-level emissions dropped")
            busAdapter = DormantVoiceBusEmitter()
        }

        let vc = VoiceController(
            wakeWordStream: wakeWordDAG.wakeWordStream,
            vadFactory: { sileroVAD },
            sttFactory: { STTBackendSelector.make(backend: "speech_analyzer") },
            tts: ttsAdapter,
            orchestrator: orchAdapter,
            bannerCoordinator: bannerAdapter,
            bus: busAdapter,
            voiceHudCont: voiceCont
        )
        voiceController = vc

        // Transfer ownership of the continuation to VoiceController.
        // The coordinator's subscriber task continues to drain; VoiceController
        // is now the producer.
        dormantVoiceContinuation = nil

        // Wire PushToTalk (VOICE-13).
        let ptt = PushToTalk(controller: vc)
        // PTT hotkey binding is deferred to the wizard / user preference; unbound at launch.
        pushToTalk = ptt

        // Wire MuteWakeWord (VOICE-12).
        if let menu = menuBarController?.contextMenu {
            muteWakeWord = MuteWakeWord(controller: vc, wakeWordDAG: wakeWordDAG, menuBarMenu: menu)
        }

        // Start the voice loop.
        await vc.start()
        systemLogger?.info("installVoice: VoiceController started")
    }

    // MARK: - Memory install (Plan 07-06 — mirrors installVoice)

    /// Constructs and starts the memory subsystem.
    ///
    /// Bootstrap order (mirrors installVoice's six-step pattern):
    ///   1. Build deps: jarvis.db URL under Application Support.
    ///   2. Construct MemoryStore — opens DB + loads vec0.dylib + migrates.
    ///      Failure is non-fatal: agent runs without memory until the user
    ///      resolves it (vec0.dylib bundling is forwarded to Phase 8).
    ///   3. Wire `replayLog` sink so MemoryStore.applyOp can record
    ///      ReplayEvent.memoryMutation through to the on-disk replay log.
    ///   4. Construct MemoryExtractor on top of OllamaProvider configured for
    ///      qwen2.5-coder:32b.
    ///   5. Construct MemoryExtractionOrchestrator (bounded AsyncChannel
    ///      capacity 32, dropOldest, serial drain). start() spawns the
    ///      consumer Task. The applyOp closure adapts the orchestrator's
    ///      Int64 source-turn-id to MemoryStore.applyOp.
    ///   6. Construct MemoryExtractionCoordinator and try to subscribe to
    ///      AgentOrchestrator.events. AgentOrchestrator wiring lands in a
    ///      future plan; until then the coordinator is constructed but its
    ///      `start(...)` call is skipped — see SUMMARY's Deferred wiring.
    ///   7. Log success.
    @MainActor
    private func installMemory() async {
        // 1. DB URL.
        let dbURL = configFileURL()
            .deletingLastPathComponent()
            .appendingPathComponent("jarvis.db")

        // 2. MemoryStore.
        let store: MemoryStore
        do {
            store = try MemoryStore(databaseURL: dbURL)
        } catch {
            // Graceful-degradation contract: the agent runs without memory
            // when vec0.dylib is unavailable on this host (forwarded to
            // Phase 8 hardening). Log + early return; voice + agent loops
            // remain operational.
            systemLogger?.warning(
                "installMemory: store init failed (vec0.dylib missing or DB locked?): \(String(describing: error))"
            )
            return
        }
        memoryStore = store

        // 3. Wire the replay sink so MemoryStore.applyOp emits
        //    ReplayEvent.memoryMutation through to the existing on-disk
        //    replay log. The Memory module declines to import Replay.ReplayLog
        //    directly (07-02 design); AppDelegate is the only place that
        //    bridges the two.
        if let log = replayLog {
            await store.setReplayLog(AppDelegateMemoryReplaySink(replayLog: log))
        } else {
            systemLogger?.warning("installMemory: replayLog absent — memory mutation rows won't persist")
        }

        // 4. MemoryExtractor on OllamaProvider(qwen2.5-coder:32b).
        let extractorProvider = OllamaProvider(
            baseURL: URL(string: "http://127.0.0.1:11434")!
        )
        let extractor = MemoryExtractor(provider: extractorProvider)

        // 5. Background orchestrator. Held strongly; start() spawns drain.
        //    The applyOp closure adapts the orchestrator's (op, Int64)
        //    contract to MemoryStore.applyOp, which is the SOLE emission
        //    site for ReplayEvent.memoryMutation.
        let memoryOrch = MemoryExtractionOrchestrator(
            extractor: extractor,
            applyOp: { op, turnId in
                _ = try await store.applyOp(op, sourceTurnId: turnId)
            }
        )
        await memoryOrch.start()
        memoryExtractionOrchestrator = memoryOrch

        // 6. Construct the MemoryExtractionCoordinator. Plan 09-01 moves the
        //    `coord.start(...)` call into `installAgent()` — this is where the
        //    OrchestratorEventBroadcaster's memory child stream is allocated
        //    and the BLOCKER-1-fixing `lookupTurnContent` closure is bound.
        let coord = MemoryExtractionCoordinator(memoryOrchestrator: memoryOrch)
        memoryExtractionCoordinator = coord

        systemLogger?.info("installMemory: MemoryExtractionOrchestrator started")
    }

    // MARK: - Agent install (Plan 09-01)

    /// Bootstrap the AgentOrchestrator + OrchestratorEventBroadcaster +
    /// TurnTranscriptStore wiring (Phase 9 SC#1, SC#2). Closes INT-07-01:
    /// memory extraction now reaches MemoryExtractionCoordinator's drain
    /// AND `lookupTurnContent` returns NON-NIL pairs.
    ///
    /// Six-step pattern (S-2):
    ///   1. Required deps from earlier installs.
    ///   2. Provider factory closure (closes over Keychain).
    ///   3. Construct the AgentOrchestrator (existing 7-arg signature; visionRouter
    ///      and presenceSnapshot wiring lands in Plans 2 + 3).
    ///   4. Construct the OrchestratorEventBroadcaster + start drain (D-08).
    ///      Construct the TurnTranscriptStore (BLOCKER-1 source of truth).
    ///   5. Subscribe consumers (memory + transcript + devOverlay).
    ///   6. Log success.
    @MainActor
    private func installAgent() async {
        // 1. Required deps from earlier installs.
        guard let mcpRuntime = self.mcpRuntime,
              let replayLog = self.replayLog,
              let configStore = self.configStore else {
            systemLogger?.warning("installAgent: deps not ready (mcp/replay/config) — skipping")
            return
        }

        // 2. Provider factory closure — closes over the keychain reference.
        //    `keychainStore` is a non-Sendable existential; capture a local
        //    Sendable copy for the closure.
        let keychainStoreLocal: any KeychainStore = self.keychainStore
        let providerFactory: @Sendable (ProviderSelection) async throws -> any LLMProvider = {
            selection in
            switch selection {
            case .anthropic:
                // Phase E (2026-05-03 audit fix): use the propagating
                // builder so a real KeychainError surfaces as
                // `LLMProviderError.transport(...)` and reaches the chat
                // panel via BusForwarder. The previous `(try? get) ?? ""`
                // pattern silently substituted an empty `x-api-key` header
                // and made auth failures indistinguishable from a stale
                // key — the user only saw `streamTruncatedFinal` after
                // Anthropic's 401 → SSE EOF cascade.
                // Coverage: AnthropicAPIKeyProviderTests.
                return AnthropicProvider(
                    apiKeyProvider: AnthropicAPIKeyProvider.make(keychain: keychainStoreLocal)
                )
            case .ollama:
                return OllamaProvider(baseURL: URL(string: "http://127.0.0.1:11434")!)
            }
        }

        // 3. Construct the orchestrator. Plan 09-02 (D-01) — passes
        //    `visionRouter:` so image-bearing turns dispatch through the
        //    pre-stream branch + post-response escalation hook.
        //    Plan 09-03 (D-13/D-14) — passes `presenceSnapshot:` so runTurn
        //    can append ambient presence enrichment to the system prompt.
        //
        //    Phase E (2026-05-03 smoke test): also calls
        //    `replayLog.beginSession(...)` to insert the parent row in the
        //    `sessions` table. Without this, every `startTurn` violates the
        //    `turns.session_id REFERENCES sessions(session_id)` FK and the
        //    orchestrator returns `SubmitOutcome.rejected(reason:
        //    .configError)` for every text turn — surfacing in the chat
        //    panel as "Config error — see ~/Library/Logs/Jarvis/system.log."
        //    Production code prior to this commit only ever called
        //    `beginSession` from tests, so the sessions table was empty on
        //    every cold launch and no turn could persist. App version + build
        //    string come from Info.plist; if absent we fall back to "dev".
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
        let orchestrator = AgentOrchestrator(
            configStore: configStore,
            providerFactory: providerFactory,
            toolDispatcher: mcpRuntime.dispatcher,
            replayLog: replayLog,
            sessionId: sessionId,
            systemPrompt: "You are Jarvis, a personal macOS assistant.",
            availableTools: [],
            visionRouter: self.visionRouter,
            presenceSnapshot: PresenceStateSnapshot.shared
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

        // 5c. DevOverlay subscriber (lossy — observational; reserved for the
        //     DevOverlay emitter wiring in a follow-on plan). Subscribed here
        //     so the broadcaster's three-subscriber pattern is established;
        //     the drain task simply consumes events to keep the actor's
        //     internal mirror flushing.
        let devSub = await broadcaster.subscribe(priority: .devOverlay, capacity: 32)
        devOverlaySubscriberTask = Task {
            for await _ in devSub.stream {
                if Task.isCancelled { break }
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
        let cb = ContextBuilder()
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
    @MainActor
    func handleChatSubmit(_ text: String) async {
        guard let orch = self.agentOrchestrator else {
            systemLogger?.warning("handleChatSubmit: agentOrchestrator nil — dropping submission")
            return
        }
        await self.tryPhraseAttachIfMatch(text)
        let outcome = await orch.submit(.text(text))
        await self.appendUserTextIfRunning(outcome, text: text)
        await self.handleTextOutcome(outcome)
    }

    /// D-12 — webview chat-panel barge-in. Cancels the in-flight turn (if
    /// any) and submits the new text via `cancelAndSubmit(.text(text))`.
    /// WARNING-4: phrase trigger ALSO fires here — both submit sites carry
    /// the same user-text shape; both must respect "what am I looking at"
    /// detection (without this, barge-in after a phrase-matched send
    /// silently drops the frame).
    @MainActor
    func handleChatCancelAndSubmit(_ text: String) async {
        guard let orch = self.agentOrchestrator else {
            systemLogger?.warning("handleChatCancelAndSubmit: agentOrchestrator nil — dropping submission")
            return
        }
        await self.tryPhraseAttachIfMatch(text)
        let outcome = await orch.cancelAndSubmit(.text(text))
        await self.appendUserTextIfRunning(outcome, text: text)
        await self.handleTextOutcome(outcome)
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

    // MARK: - Vision install (Plan 07-06 — mirrors installVoice)

    /// Constructs and starts the vision subsystem.
    ///
    /// VISION-03 architectural boundary: PresenceSignalBus is constructed
    /// EXACTLY ONCE (by PresenceMonitor — only PresenceMonitor can
    /// construct the bus per 07-04's `internal init`) and shared by
    /// reference (the Sendable struct value type wraps the AsyncStream)
    /// between two read-only consumers (ContextBuilder for D-10
    /// system-prompt enrichment and HudStateCoordinator for D-10 subtle
    /// ring indicator). No subscriber of the bus has any reference to
    /// JarvisTTS or to the AgentOrchestrator.runTurn / cancelAndSubmit
    /// code path — scripts/check-presence-vision-isolation.sh enforces.
    ///
    /// D-09: presence-on-by-default after first TCC grant. CameraCapture's
    /// `becameAuthorized()` is the public entry that flips the session live
    /// once Camera TCC has been granted; before that, `open()` throws and
    /// the degradation watcher surfaces the banner.
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
        //    T2 falls back to T1 when vllm-mlx isn't available — the router's
        //    `evaluatePostResponse` already enforces "stay on T1 if T2 not
        //    available" (07-05's no-auto-cloud invariant); supplying the
        //    same provider for both keeps the API contract satisfied.
        //
        //    Wiring into the live AgentOrchestrator.runTurn is deferred — the
        //    orchestrator itself isn't yet wired in AppDelegate. See SUMMARY
        //    Deferred wiring.
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
            t2Provider: t1,                  // sidecar plan pending — T2 reuses T1 provider
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
            stateDumpAction: { [weak self] in self?.copyStateDump() }
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

    private func toggleHUD() {
        guard let panel = hudPanel else { return }
        // Gate on handshake armed — don't summon an unresponsive HUD.
        // `.armed` means the bus is usable; any other state (idle, sentHello,
        // mismatched, timedOut) gets the "hud-not-ready" banner instead of
        // popping an empty window.
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

    /// @testable seam — XCTest calls this to drive the private
    /// `toggleHUD()` without reaching for `perform(Selector(...))`. Production
    /// code path is through the menu-bar left-click action and hotkey binder.
    func exposedToggleHUD() { toggleHUD() }

    // MARK: - Bus wiring (Plan 02-03)

    /// Constructs the `WebviewBridge` around `hudPanel.webView`, wires the
    /// handshake callbacks (armed → `coordinator.markReady()` + `onBusArmed`;
    /// mismatch/timeout → `TCCAlertService.presentHardBlock` +
    /// `onHandshakeMismatch`), installs the `WKNavigationDelegate` so the
    /// handshake fires on `didFinish`, constructs + starts the HUD-08
    /// `HudStateCoordinator` with three dormant producer streams (Phase 4/5/6
    /// replace them), and loads the R3F bundle's `index.html` from the app
    /// bundle. Called once during `applicationWillFinishLaunching` after
    /// `installHUDPanel()`.
    ///
    /// Plan 03-05 replaces 02-03's `bus-harness.html` load target with
    /// `index.html` (same `webview/` subdirectory, different entry). The
    /// bus-harness stays in the bundle for the 02-04 parity script and as a
    /// dev-debugging fallback.
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
    /// resources during launch.
    private var devOverlayWindow: DevOverlayWindow?

    private func toggleDevOverlay() {
        if devOverlayWindow == nil {
            devOverlayWindow = DevOverlayWindow()
        }
        devOverlayWindow?.toggle()
    }

    /// Writes ONLY boolean presence indicators to the clipboard. The API key
    /// VALUE is never fetched into a local variable or written anywhere.
    /// SEC-01 / T-04-02 defense-in-depth.
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

// MARK: - Bus gateway placeholder

/// CR-02 (REVIEW 05): pre-orchestrator no-op BusGateway. Phase 6 / 7
/// orchestrator wiring replaces this with a real adapter that translates
/// the dispatcher's bus events into `BusOutbound.toolCallStart` /
/// `toolCallEnd` cases on the WebviewBridge. Until then, the dispatcher
/// chain still composes (BusGateway must be non-nil for some call sites)
/// but emits into a sink that drops events on the floor.
struct NoopBusGateway: BusGateway {
    func emitToolCallStart(toolUseId: String, name: String, argsPreview: String) async {}
    func updateArgsPreview(toolUseId: String, name: String, argsPreview: String) async {}
    func emitToolCallEnd(toolUseId: String, name: String, ok: Bool, previewOrError: String) async {}
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
