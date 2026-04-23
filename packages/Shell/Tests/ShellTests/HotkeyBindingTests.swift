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

    /// CR-03 (SHELL-06): store that mimics `NSEvent.addGlobalMonitorForEvents`
    /// returning `nil` — the exact OS behaviour when Input Monitoring was
    /// revoked between launches. Local-monitor install still succeeds.
    private final class DeniedGlobalMonitorStore: HotkeyMonitorStore, @unchecked Sendable {
        var localInstalled = 0
        var removed = 0
        func installGlobalMonitor(
            _ shortcut: KeyboardShortcut,
            _ onPress: @escaping @Sendable () -> Void
        ) -> Any? { nil }
        func installLocalMonitor(
            _ shortcut: KeyboardShortcut,
            _ onPress: @escaping @Sendable () -> Void
        ) -> Any? {
            localInstalled += 1
            return "local-\(localInstalled)" as NSString
        }
        func remove(_ token: Any) { removed += 1 }
    }

    /// CR-03 (SHELL-06): counter-recording BannerSink so we can assert the
    /// hotkey-bind-failed banner was enqueued when the OS silently refused.
    private final class RecordingBindFailedSink: HotkeyBinder.BannerSink, @unchecked Sendable {
        var enqueueCount = 0
        func enqueueHotkeyBindFailed() { enqueueCount += 1 }
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

    /// CR-03 (SHELL-06): when `NSEvent.addGlobalMonitorForEvents` silently
    /// returns nil, the binder must NOT pretend the bind succeeded — it must
    /// set `isDegraded = true` and (when a sink is wired) enqueue the
    /// hotkey-bind-failed banner. Local monitor is still installed so the
    /// hotkey works while Jarvis is frontmost.
    func test_nilGlobalTokenMarksDegradedAndNotifiesSink() {
        let store = DeniedGlobalMonitorStore()
        let sink = RecordingBindFailedSink()
        let binder = HotkeyBinder(store: store)
        let shortcut = KeyboardShortcut(keyCode: 38, modifiers: [.command])
        binder.bind(
            shortcut,
            inputMonitoringGranted: true,
            bindFailedSink: sink
        ) { }

        XCTAssertTrue(
            binder.isDegraded,
            "SHELL-06: nil global token must mark binder degraded even when inputMonitoringGranted=true"
        )
        XCTAssertEqual(
            sink.enqueueCount, 1,
            "SHELL-06: nil global token must enqueue BannerContent.hotkeyBindFailed exactly once"
        )
        XCTAssertEqual(
            store.localInstalled, 1,
            "Local monitor must still be installed so the hotkey works while Jarvis is frontmost"
        )
        XCTAssertEqual(binder.currentShortcut, shortcut)
    }

    /// CR-03 (SHELL-06): when Input Monitoring was never granted, the binder
    /// is degraded but the bind-failed sink is NOT called — the OS refused
    /// is a *different* banner (inputMonitoringDenied, priority 2) vs. the
    /// silent-revoke path (hotkeyBindFailed, priority 3).
    func test_deniedInputMonitoringDoesNotEnqueueBindFailed() {
        let store = RecordingMonitorStore()
        let sink = RecordingBindFailedSink()
        let binder = HotkeyBinder(store: store)
        binder.bind(
            KeyboardShortcut(keyCode: 38, modifiers: [.command]),
            inputMonitoringGranted: false,
            bindFailedSink: sink
        ) { }
        XCTAssertTrue(binder.isDegraded)
        XCTAssertEqual(
            sink.enqueueCount, 0,
            "Denied-InputMonitoring path must use the inputMonitoringDenied banner, "
            + "not the hotkeyBindFailed banner"
        )
    }

    /// CR-03 (SHELL-06): when the global monitor installs successfully, the
    /// sink must NOT be called — no spurious banner on the happy path.
    func test_successfulBindDoesNotEnqueueBindFailed() {
        let store = RecordingMonitorStore()
        let sink = RecordingBindFailedSink()
        let binder = HotkeyBinder(store: store)
        binder.bind(
            KeyboardShortcut(keyCode: 38, modifiers: [.command]),
            inputMonitoringGranted: true,
            bindFailedSink: sink
        ) { }
        XCTAssertFalse(binder.isDegraded)
        XCTAssertEqual(sink.enqueueCount, 0)
    }
}
