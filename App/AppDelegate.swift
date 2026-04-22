import AppKit
import Config
import Keychain
import JarvisLogging
import Shell
import Logging   // swift-log — `Logger` here is `Logging.Logger`

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

    // MARK: - Installed components

    var statusItem: NSStatusItem?
    var menuBarController: MenuBarIconController?
    var hudPanel: JarvisHUDPanel?
    var bannerPanel: HUDBannerPanel?
    var bannerCoordinator: HUDBannerCoordinator?
    var hotkeyBinder: HotkeyBinder?
    var wizardController: OnboardingWizardController?
    var wizardState: WizardState?

    private var systemLogger: Logger?

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
            systemLogger?.critical("Config malformed: \(String(describing: e))")
            TCCAlertService.presentHardBlock(
                title: "Jarvis can't start",
                informativeText: "Your config file couldn't be read. \(String(describing: e)). Details in ~/Library/Logs/Jarvis/system.log."
            )
            NSApp.terminate(nil)
            return
        } catch {
            systemLogger?.critical("Config load failed: \(error.localizedDescription)")
            TCCAlertService.presentHardBlock(
                title: "Jarvis can't start",
                informativeText: "Config load failed: \(error.localizedDescription)"
            )
            NSApp.terminate(nil)
            return
        }
        _ = snapshots  // Phase 2+ wires the ConfigStore to the agent loop.

        // 4. Menu bar + HUD panel + banner panel.
        installMenuBar()
        installHUDPanel()
        installBannerPanel()

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
    }

    func applicationWillTerminate(_ notification: Notification) {
        hotkeyBinder?.unbind()
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
        if panel.isSummoned { panel.dismiss() } else { panel.summon() }
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
        hotkeyBinder?.bind(
            shortcut,
            inputMonitoringGranted: state.inputMonitoringGranted
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
