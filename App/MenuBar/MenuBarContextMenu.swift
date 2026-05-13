import AppKit
import ObjectiveC.runtime

/// Builds the menu-bar right-click / Ctrl-click menu per UI-SPEC Surface 4 lines 428-436.
@MainActor
public enum MenuBarContextMenu {
    public static func build(
        setupAction: @escaping () -> Void,
        settingsAction: @escaping () -> Void,
        devOverlayToggleAction: @escaping () -> Void,
        voiceLogToggleAction: @escaping () -> Void,
        stateDumpAction: @escaping () -> Void
    ) -> NSMenu {
        let menu = NSMenu()

        menu.addItem(makeItem(title: "Setup…", action: setupAction))
        // Settings… opens the freeform settings panel
        // (`SettingsWindowController`). The user can change the API key,
        // re-grant Input Monitoring, or rebind the global hotkey from there.
        // Distinct from Setup… (the sequential first-run wizard); both
        // surfaces share the same underlying `WizardState`.
        menu.addItem(makeItem(title: "Settings…", action: settingsAction))

        menu.addItem(NSMenuItem.separator())

        menu.addItem(makeItem(title: "Show Dev Overlay", action: devOverlayToggleAction))
        // Voice Log: opt-in diagnostic window streaming every voice
        // subsystem event in real time. Mirrors DevOverlay's lazy-construct,
        // toggle-show pattern. T-06-05-03: in-memory display only — never
        // routed to OSLog or to disk.
        menu.addItem(makeItem(title: "Voice Log", action: voiceLogToggleAction))
        menu.addItem(makeItem(title: "Copy State Dump", action: stateDumpAction))

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

    /// Build an NSMenuItem with a closure action.
    ///
    /// `NSMenuItem.target` is a `weak` property, so the obvious
    /// `item.target = ClosureTarget(...)` pattern lets the trampoline
    /// deallocate immediately and the menu item silently does nothing
    /// when clicked. We keep the trampoline alive for the menu item's
    /// lifetime via objc_setAssociatedObject on the item itself.
    private static func makeItem(title: String, action: @escaping () -> Void) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let target = ClosureTarget(action: action)
        item.target = target
        item.action = #selector(ClosureTarget.run)
        objc_setAssociatedObject(
            item,
            &MenuBarContextMenu.trampolineKey,
            target,
            .OBJC_ASSOCIATION_RETAIN_NONATOMIC
        )
        return item
    }

    /// Address used as the associated-object key. The address itself is the
    /// key — the value of `trampolineKey` is irrelevant.
    private static var trampolineKey: UInt8 = 0
}

/// Objective-C-visible trampoline so `NSMenuItem` can call closure-based actions.
/// Strong-ref is established by `objc_setAssociatedObject` in `makeItem`.
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
