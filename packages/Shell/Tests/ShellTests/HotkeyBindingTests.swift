import XCTest
import AppKit
@testable import Shell

@MainActor
final class HotkeyBindingTests: XCTestCase {
    /// `@unchecked Sendable`: counters are `var` (required by the Sendable
    /// protocol), but every interaction in these @MainActor-bound tests happens
    /// on the main thread, so there's no actual data race. Test-fixture-only
    /// escape hatch, not production code.
    private final class RecordingMonitorStore: HotkeyMonitorStore, @unchecked Sendable {
        var globalInstalled = 0
        var localInstalled = 0
        var removed = 0

        func installGlobalMonitor(
            _ shortcut: KeyboardShortcut,
            _ onPress: @escaping @Sendable () -> Void
        ) -> Any? {
            globalInstalled += 1
            return "global-\(globalInstalled)" as NSString
        }

        func installLocalMonitor(
            _ shortcut: KeyboardShortcut,
            _ onPress: @escaping @Sendable () -> Void
        ) -> Any? {
            localInstalled += 1
            return "local-\(localInstalled)" as NSString
        }

        func remove(_ token: Any) {
            removed += 1
        }
    }

    func test_defaultHotkeyIsUnset() {
        let binder = HotkeyBinder(store: RecordingMonitorStore())
        XCTAssertNil(binder.currentShortcut, "SHELL-02: default hotkey ships unset")
        XCTAssertFalse(binder.isDegraded)
    }

    func test_bindInstallsGlobalAndLocalWhenGranted() {
        let store = RecordingMonitorStore()
        let binder = HotkeyBinder(store: store)
        let shortcut = KeyboardShortcut(keyCode: 38, modifiers: [.command, .shift]) // J
        binder.bind(shortcut, inputMonitoringGranted: true) { }
        XCTAssertEqual(store.globalInstalled, 1)
        XCTAssertEqual(store.localInstalled, 1)
        XCTAssertFalse(binder.isDegraded)
        XCTAssertEqual(binder.currentShortcut, shortcut)
    }

    func test_bindInstallsLocalOnlyWhenDenied() {
        let store = RecordingMonitorStore()
        let binder = HotkeyBinder(store: store)
        binder.bind(
            KeyboardShortcut(keyCode: 38, modifiers: [.command, .shift]),
            inputMonitoringGranted: false
        ) { }
        XCTAssertEqual(store.globalInstalled, 0, "Must NOT install global monitor on denial")
        XCTAssertEqual(store.localInstalled, 1, "Must install local monitor fallback")
        XCTAssertTrue(binder.isDegraded)
    }

    func test_unbindRemovesAllMonitors() {
        let store = RecordingMonitorStore()
        let binder = HotkeyBinder(store: store)
        binder.bind(
            KeyboardShortcut(keyCode: 38, modifiers: [.command]),
            inputMonitoringGranted: true
        ) { }
        binder.unbind()
        XCTAssertEqual(store.removed, 2, "unbind must remove both global and local tokens")
        XCTAssertNil(binder.currentShortcut)
    }

    func test_keyboardShortcutCodableRoundTrip() throws {
        let original = KeyboardShortcut(keyCode: 49 /* space */, modifiers: [.option])
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(KeyboardShortcut.self, from: data)
        XCTAssertEqual(decoded, original)
    }
}
