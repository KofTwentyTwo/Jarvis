import AppKit

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
/// Bootstrap chain (Plan 03 — minimal UI wiring only; Plan 04 will prepend
/// logging bootstrap and append config/keychain/hotkey installs):
///  1. Entitlement hard-block — read `JarvisEntitlementsVerified`; if false,
///     present a critical NSAlert and terminate (RESEARCH.md §Pattern 1).
///  2. Install menu-bar status item + context menu.
///  3. Install the HUD panel (hidden until left-click or hotkey — Plan 04).
///  4. Install the banner panel + coordinator (no banners enqueued yet —
///     Plan 04 wires the trigger conditions).
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Overridable for tests. Default is the production `Bundle.main` probe.
    var entitlementProbe: EntitlementGateProbe = InfoPlistEntitlementGateProbe()

    /// Overridable for tests — called on entitlement failure instead of the
    /// production NSAlert + terminate path. Tests inject a closure that just
    /// sets a boolean so we can assert the path fired without spawning a modal.
    ///
    /// The default is a no-op when launched as an XCTest host (so the host app
    /// does not terminate before the test bundle loads) and the production
    /// NSAlert + terminate path otherwise.
    var onEntitlementFailure: @MainActor () -> Void = AppDelegate.defaultOnEntitlementFailure

    var statusItem: NSStatusItem?
    var menuBarController: MenuBarIconController?
    var hudPanel: JarvisHUDPanel?
    var bannerPanel: HUDBannerPanel?
    var bannerCoordinator: HUDBannerCoordinator?

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Plan 04 prepends: JarvisLogHandlerFactory.bootstrap() here.
        // 1. Entitlement hard-block.
        guard entitlementProbe.isVerified() else {
            onEntitlementFailure()
            return
        }
        // 2. Menu-bar + HUD panel + banner panel install.
        //    Skip AppKit surface install when launched as a test host — the
        //    host app exists only so the test bundle can load against it, and
        //    `applicationWillFinishLaunching` firing with the real probe (which
        //    reads JarvisEntitlementsVerified=false in the unsigned Debug
        //    Info.plist) would fall into the failure path anyway.
        if AppDelegate.isRunningAsTestHost { return }
        installMenuBar()
        installHUDPanel()
        installBannerPanel()
        // Plan 04 appends: ConfigLoader.loadSnapshots(), Keychain.fetch(.anthropic),
        // hotkey install via IOHIDRequestAccess + HotkeyBinder.
    }

    /// Detects whether this process is hosting an XCTest bundle. XCTest sets
    /// `XCTestConfigurationFilePath` in the environment before spawning the
    /// host app.
    static var isRunningAsTestHost: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }

    /// Default handler for `onEntitlementFailure` — silent no-op under XCTest
    /// (so the host app doesn't terminate before the test bundle loads) and
    /// the production NSAlert + terminate path otherwise.
    @MainActor
    static func defaultOnEntitlementFailure() {
        if isRunningAsTestHost { return }
        presentEntitlementFailureAlert()
        NSApp.terminate(nil)
    }

    // MARK: - Installers

    private func installMenuBar() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        self.statusItem = item
        let menu = MenuBarContextMenu.build(
            setupAction: { /* wired Plan 04 — opens wizard */ },
            devOverlayToggleAction: { /* stub: Plan 04 shows "Dev Overlay lands in Phase 4" banner */ },
            stateDumpAction: { /* stub: Plan 04 copies state JSON to clipboard */ }
        )
        let controller = MenuBarIconController(statusItem: item, contextMenu: menu)
        controller.setLeftClickAction { [weak self] in
            self?.toggleHUD()
        }
        self.menuBarController = controller
    }

    private func installHUDPanel() {
        let panel = JarvisHUDPanel()
        panel.orderOut(nil)
        self.hudPanel = panel
    }

    private func installBannerPanel() {
        let panel = HUDBannerPanel()
        panel.orderOut(nil)
        self.bannerPanel = panel
        self.bannerCoordinator = HUDBannerCoordinator(panel: panel)
    }

    private func toggleHUD() {
        guard let panel = hudPanel else { return }
        if panel.isSummoned {
            panel.dismiss()
        } else {
            panel.summon()
        }
    }

    // MARK: - Entitlement failure alert

    /// Critical NSAlert shown when `JarvisEntitlementsVerified` is missing/false.
    /// Copy per UI-SPEC Surface 6 (hard-blocker modal) — informs the user that
    /// the build-time check failed and offers to open the system log.
    static func presentEntitlementFailureAlert() {
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "Jarvis can't start"
        alert.informativeText = """
        A build verification check failed at launch. The app has been \
        stopped to prevent a crash. Reinstall Jarvis or rebuild from source \
        with the correct entitlements.
        """
        alert.addButton(withTitle: "Quit")
        alert.addButton(withTitle: "Show Details")
        let response = alert.runModal()
        if response == .alertSecondButtonReturn {
            let log = URL(fileURLWithPath:
                (NSHomeDirectory() as NSString)
                    .appendingPathComponent("Library/Logs/Jarvis/system.log"))
            NSWorkspace.shared.open(log)
        }
    }
}
