import AppKit

/// Abstracts NSEvent monitor install/remove so tests can inject a recording
/// fake. Production implementation is `NSEventMonitorStore`.
public protocol HotkeyMonitorStore: Sendable {
    func installGlobalMonitor(
        _ shortcut: KeyboardShortcut,
        _ onPress: @escaping @Sendable () -> Void
    ) -> Any?
    func installLocalMonitor(
        _ shortcut: KeyboardShortcut,
        _ onPress: @escaping @Sendable () -> Void
    ) -> Any?
    func remove(_ token: Any)
}

/// Production monitor store. Wraps `NSEvent.addGlobalMonitorForEvents` and
/// `NSEvent.addLocalMonitorForEvents` — the CLAUDE.md D-06/D-07 hotkey hygiene
/// decision: prefer NSEvent monitors over Carbon `RegisterEventHotKey` or the
/// `HotKey` SPM for plain-modifier keys (fewer TCC surfaces, no full-process
/// key-read risk).
public struct NSEventMonitorStore: HotkeyMonitorStore {
    public init() {}

    public func installGlobalMonitor(
        _ shortcut: KeyboardShortcut,
        _ onPress: @escaping @Sendable () -> Void
    ) -> Any? {
        NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { event in
            if Self.matches(event: event, shortcut: shortcut) { onPress() }
        }
    }

    public func installLocalMonitor(
        _ shortcut: KeyboardShortcut,
        _ onPress: @escaping @Sendable () -> Void
    ) -> Any? {
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if Self.matches(event: event, shortcut: shortcut) {
                onPress()
                return nil
            }
            return event
        }
    }

    public func remove(_ token: Any) {
        NSEvent.removeMonitor(token)
    }

    /// Compare the event's (keyCode, modifier mask) to the stored shortcut,
    /// masking modifiers with `.deviceIndependentFlagsMask` so stray hardware
    /// bits (numeric-pad flag, etc.) don't cause misses.
    private static func matches(event: NSEvent, shortcut: KeyboardShortcut) -> Bool {
        let eventMods = event.modifierFlags
            .intersection(.deviceIndependentFlagsMask).rawValue
        let wantedMods = NSEvent.ModifierFlags(rawValue: shortcut.modifiers)
            .intersection(.deviceIndependentFlagsMask).rawValue
        return event.keyCode == shortcut.keyCode && eventMods == wantedMods
    }
}

/// Binds a single global hotkey. On Input Monitoring grant, installs both a
/// global monitor (fires when another app is frontmost) and a local monitor
/// (fires when Jarvis is frontmost). On denial, falls back to local-only with
/// `isDegraded=true` — per SHELL-06 / D-12 the denial path is NOT a silent
/// no-op. The caller (AppDelegate) surfaces the banner via `InputMonitoringProbe`
/// before calling `bind(..., inputMonitoringGranted: false, ...)`.
///
/// `@MainActor` per S-2 — NSEvent monitor install must happen on the main
/// thread, and this whole type touches AppKit.
@MainActor
public final class HotkeyBinder {
    private let store: any HotkeyMonitorStore
    private var globalToken: Any?
    private var localToken: Any?
    private var boundShortcut: KeyboardShortcut?
    public private(set) var isDegraded: Bool = false

    public init(store: any HotkeyMonitorStore = NSEventMonitorStore()) {
        self.store = store
    }

    /// Currently-bound shortcut, or `nil` if unbound. Ships unset at default
    /// (SHELL-02) — first-launch wizard Stage 3 writes the first value.
    public var currentShortcut: KeyboardShortcut? { boundShortcut }

    /// Bind a shortcut. `inputMonitoringGranted` controls whether the global
    /// monitor is installed. On denial we still install the local monitor so
    /// the hotkey works while Jarvis is frontmost (degraded mode).
    public func bind(
        _ shortcut: KeyboardShortcut,
        inputMonitoringGranted: Bool,
        onPress: @escaping @Sendable () -> Void
    ) {
        unbind()
        boundShortcut = shortcut
        if inputMonitoringGranted {
            globalToken = store.installGlobalMonitor(shortcut, onPress)
            isDegraded = false
        } else {
            isDegraded = true
        }
        // Local monitor is always installed — works regardless of Input
        // Monitoring state so long as Jarvis is frontmost.
        localToken = store.installLocalMonitor(shortcut, onPress)
    }

    /// Remove all installed monitors and reset state.
    public func unbind() {
        if let t = globalToken {
            store.remove(t)
            globalToken = nil
        }
        if let t = localToken {
            store.remove(t)
            localToken = nil
        }
        boundShortcut = nil
        isDegraded = false
    }
}
