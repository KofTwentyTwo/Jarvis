import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        // Wiring lands in Plan 03 (logging bootstrap → entitlement check → config → keychain → menu bar → HUD panel → hotkey).
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // P1 scaffold. Empty.
    }
}
