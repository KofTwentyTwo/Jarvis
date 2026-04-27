import AppKit
import Bus
import Config
import Keychain
import JarvisLogging
import Shell
import Voice           // Plan 06-05: VoiceController + PTT + MuteWakeWord
import WebKit
import Logging   // swift-log — `Logger` here is `Logging.Logger`
import AgentCore       // Plan 05-05: BoundedAsyncChannel for ME-04 closure
import Replay          // Plan 05-05: ReplayEvent type for the orch→replay channel
import JarvisMCP       // CR-02 (REVIEW 05): MCPRuntimeWiring.build for end-to-end ME-04 closure

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

    /// Task spawned in `applicationWillFinishLaunching` that constructs and
    /// starts the voice subsystem. Held strongly so the async setup isn't
    /// cancelled prematurely.
    var voiceInstallTask: Task<Void, Never>?

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
        _ = snapshots  // Phase 2+ wires the ConfigStore to the agent loop.

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

        // 5. Keychain fetch — missing key → banner (priority 1).
        let apiKeyStored: Bool
        do {
            _ = try keychainStore.get(.anthropic)
            apiKeyStored = true
        } catch KeychainError.itemNotFound {
            bannerCoordinator?.enqueue(.keychainEmpty)
            apiKeyStored = false
        } catch {
            systemLogger?.error("Keychain fetch error: \(String(describing: error))")
            apiKeyStored = false
        }

        // 6. Input Monitoring probe — denial enqueues `.inputMonitoringDenied`.
        let inputMonitoringGranted = hidProbe.requestListenEventAccess()
        if !inputMonitoringGranted {
            bannerCoordinator?.enqueue(.inputMonitoringDenied)
        }

        // 7. Hotkey binder — empty at launch; wizard binds a shortcut later.
        hotkeyBinder = HotkeyBinder()

        // 8. Wizard state + first-launch open.
        let state = WizardState(keychain: keychainStore)
        wizardState = state
        wizardController = OnboardingWizardController(state: state)
        if !apiKeyStored {
            openWizard(firstLaunch: true)
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
        Task { @MainActor [weak self] in
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

        // 11. Plan 06-05: install voice subsystem asynchronously.
        //     Model files (ORT sessions, Orpheus MLX weights) may be absent
        //     on first launch — failure is non-fatal (voice degrades gracefully).
        //     The dormantVoiceContinuation is replaced with the real producer
        //     once VoiceController is live and started.
        voiceInstallTask = Task { @MainActor [weak self] in
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
        if let vc = voiceController {
            Task { await vc.shutdown() }
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

        // Construct VoiceController.
        // NullBannerAdapter bridges VoiceBannerInterface → HUDBannerCoordinator.
        // NullOrchestratorAdapter is a placeholder until Phase 7 wires the real orchestrator.
        // NullBusAdapter is a placeholder until Phase 6+Bus wiring is finalized.
        let bannerAdapter = AppDelegateBannerAdapter(coordinator: bannerCoordinator)
        let orchestratorAdapter = NullOrchestratorAdapter()
        let busAdapter = NullBusEmitterAdapter()

        let vc = VoiceController(
            wakeWordStream: wakeWordDAG.wakeWordStream,
            vadFactory: { sileroVAD },
            sttFactory: { STTBackendSelector.make(backend: "speech_analyzer") },
            tts: NullTTSAdapter(),
            orchestrator: orchestratorAdapter,
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
            devOverlayToggleAction: { [weak self] in self?.showDevOverlayStubBanner() },
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

    private func showDevOverlayStubBanner() {
        bannerCoordinator?.enqueue(BannerContent(
            id: "dev-overlay-stub",
            priority: 99,
            title: "Dev Overlay lands in Phase 4",
            body: "The overlay itself is a P4 deliverable.",
            action: nil
        ))
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
// Phase 7 (orchestrator wiring) replaces NullOrchestratorAdapter with a real adapter.

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

/// Placeholder orchestrator adapter. Phase 7 wires the real `AgentOrchestrator`.
actor NullOrchestratorAdapter: VoiceOrchestratorInterface {
    nonisolated let voiceEvents: AsyncStream<VoiceOrchestratorEvent>
    private nonisolated let eventsCont: AsyncStream<VoiceOrchestratorEvent>.Continuation

    init() {
        let (stream, cont) = AsyncStream<VoiceOrchestratorEvent>.makeStream()
        voiceEvents = stream
        eventsCont = cont
    }

    func submit(text: String) async {
        // Phase 7: forward to AgentOrchestrator.submit(TurnInput.voice(text))
    }

    func cancelAndSubmit(text: String) async {
        eventsCont.yield(.cancelled)
        // Phase 7: forward to AgentOrchestrator.cancelAndSubmit(TurnInput.voice(text))
    }
}

/// Placeholder TTS adapter. Phase 7 wires the real `TTSEngineActor`.
actor NullTTSAdapter: VoiceTTSInterface {
    var hasSynthInFlight: Bool { false }

    func synthesize(_ text: String) async {
        // Phase 7: forward to TTSEngineActor.synthesize(_:tier:voice:)
    }

    func cancelTTS() async {
        // Phase 7: forward to TTSEngineActor.cancel()
    }
}

/// Bridges `BusOutboundEmitter` → `OutboundBatcher` from the Bus package.
///
/// `OutboundBatcher.postAudio(_:)` already exists from Phase 2 Bus wiring.
/// This adapter routes the 30 Hz RMS values to the batcher's `postAudio` method.
/// Phase 6+Bus wiring provides the real `OutboundBatcher` instance; for now,
/// this is a no-op until the Bus phase integration is finalized.
struct NullBusEmitterAdapter: BusOutboundEmitter {
    func postAudio(_ rms: Float) async {
        // Phase 7: forward to OutboundBatcher.postAudio(rms) for RingMesh pulse
    }
}
