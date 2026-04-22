import AppKit

/// Builds the menu-bar right-click / Ctrl-click menu per UI-SPEC Surface 4 lines 428-436.
/// Action targets are wired by `AppDelegate` (currently in this plan as stubs; Plan 04
/// wires them to the wizard / dev-overlay / state-dump).
@MainActor
public enum MenuBarContextMenu {
    public static func build(
        setupAction: @escaping () -> Void,
        devOverlayToggleAction: @escaping () -> Void,
        stateDumpAction: @escaping () -> Void
    ) -> NSMenu {
        let menu = NSMenu()

        let setup = NSMenuItem(title: "Setup…", action: nil, keyEquivalent: "")
        setup.target = ClosureTarget(action: setupAction)
        setup.action = #selector(ClosureTarget.run)
        menu.addItem(setup)

        let settings = NSMenuItem(title: "Settings…", action: nil, keyEquivalent: "")
        settings.isEnabled = false
        settings.toolTip = "Coming soon"
        menu.addItem(settings)

        menu.addItem(NSMenuItem.separator())

        let devOverlay = NSMenuItem(title: "Show Dev Overlay", action: nil, keyEquivalent: "")
        devOverlay.target = ClosureTarget(action: devOverlayToggleAction)
        devOverlay.action = #selector(ClosureTarget.run)
        menu.addItem(devOverlay)

        let stateDump = NSMenuItem(title: "Copy State Dump", action: nil, keyEquivalent: "")
        stateDump.target = ClosureTarget(action: stateDumpAction)
        stateDump.action = #selector(ClosureTarget.run)
        menu.addItem(stateDump)

        menu.addItem(NSMenuItem.separator())

        let quit = NSMenuItem(
            title: "Quit Jarvis",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        quit.keyEquivalentModifierMask = [.command]
        menu.addItem(quit)

        return menu
    }
}

/// Objective-C-visible trampoline so `NSMenuItem` can call closure-based actions.
/// Strong-ref on the menu item is deliberate: the closure survives the menu's lifetime.
@MainActor
private final class ClosureTarget: NSObject {
    let action: () -> Void
    init(action: @escaping () -> Void) {
        self.action = action
        super.init()
    }
    @objc func run() {
        action()
    }
}
