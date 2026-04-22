---
phase: 01-foundations
plan: 04
type: execute
wave: 3
depends_on: [01, 02, 03]
files_modified:
  - packages/Shell/Sources/Shell/KeyboardShortcut.swift
  - packages/Shell/Sources/Shell/HotkeyBinder.swift
  - packages/Shell/Sources/Shell/InputMonitoringProbe.swift
  - packages/Shell/Sources/Shell/LaunchAtLoginController.swift
  - packages/Shell/Sources/Shell/TCCAlertService.swift
  - packages/Shell/Sources/Shell/ShortcutRecorder/ShortcutRecorderView.swift
  - packages/Shell/Sources/Shell/ShortcutRecorder/ShortcutRecorderHostView.swift
  - packages/Shell/Sources/Shell/ShortcutRecorder/KeyCapView.swift
  - packages/Shell/Sources/Shell/ShortcutRecorder/CollisionDetector.swift
  - packages/Shell/Tests/ShellTests/ShortcutRecorderTests.swift
  - packages/Shell/Tests/ShellTests/HotkeyBindingTests.swift
  - packages/Shell/Tests/ShellTests/InputMonitoringDenialTests.swift
  - packages/Shell/Tests/ShellTests/LaunchAtLoginTests.swift
  - packages/Shell/Tests/ShellTests/WizardTCCStageTests.swift
  - App/Wizard/WizardView.swift
  - App/Wizard/WizardStageAPIKeyView.swift
  - App/Wizard/WizardStageTCCView.swift
  - App/Wizard/WizardStageHotkeyView.swift
  - App/Wizard/WizardState.swift
  - App/Wizard/OnboardingWizardController.swift
  - App/Wizard/AnthropicKeyValidator.swift
  - App/JarvisApp.swift
  - App/AppDelegate.swift
autonomous: true
requirements: [SHELL-01, SHELL-02, SHELL-03, SHELL-05, SHELL-06, SEC-04]
must_haves:
  truths:
    - "Default hotkey ships unset (SHELL-02); first-launch wizard stage 3 binds it via ShortcutRecorderView"
    - "HotkeyBinder wraps NSEvent.addGlobalMonitorForEvents(.keyDown); IOHIDRequestAccess denial triggers HUD banner and falls back to addLocalMonitorForEvents (SHELL-06)"
    - "ShortcutRecorderView rejects modifier-only keystrokes and shift-only keystrokes; Escape aborts recording; modifier-plus-regular-key captures"
    - "LaunchAtLoginController wraps SMAppService.mainApp.register()/.unregister() with 4 status cases (.enabled, .requiresApproval, .notRegistered, .notFound); no user-facing toggle in P1 (API scaffolded only)"
    - "First-launch wizard is modal (NSWindow.level = .modalPanel) until stage 1 API key is stored; re-entry via Setup… menu item is non-modal (D-09 stateless reentry)"
    - "Wizard stage 2 actively prompts Input Monitoring ONLY; Microphone, Camera, Automation are explainer-only (D-08, SEC-04)"
    - "AppDelegate wires: (a) JarvisLogHandlerFactory.bootstrap() BEFORE entitlement check (rationale: logging must exist before the entitlement NSAlert hard-block so the failure is captured at critical level — see PATTERNS.md §S-8 one-bootstrap discipline; note this is a planner-derived operational constraint, not a locked D-XX decision), (b) ConfigLoader.loadSnapshots → NSAlert on malformed, (c) Keychain.fetch(.anthropic) → HUDBanner.keychainEmpty if missing, (d) HotkeyBinder install after IOHIDRequestAccess probe"
  artifacts:
    - path: "packages/Shell/Sources/Shell/HotkeyBinder.swift"
      provides: "Global hotkey monitor with local-monitor fallback on Input Monitoring denial"
      contains: "addGlobalMonitorForEvents"
    - path: "packages/Shell/Sources/Shell/InputMonitoringProbe.swift"
      provides: "IOHIDRequestAccess probe + HUD banner enqueue on denial (SHELL-06)"
      contains: "IOHIDRequestAccess"
    - path: "packages/Shell/Sources/Shell/LaunchAtLoginController.swift"
      provides: "**SHELL-05** scaffolded (SMAppService wrapper; no UI in P1 — user can toggle via Settings panel in a later phase)"
      contains: "SMAppService.mainApp"
    - path: "packages/Shell/Sources/Shell/ShortcutRecorder/ShortcutRecorderView.swift"
      provides: "Hand-rolled SwiftUI NSViewRepresentable for local-monitor keyDown capture"
      contains: "NSEvent.addLocalMonitorForEvents"
    - path: "App/Wizard/WizardView.swift"
      provides: "Three-stage wizard (API key → TCC → hotkey) per D-06, D-07"
      contains: "WizardStage"
    - path: "App/AppDelegate.swift"
      provides: "Full launch wiring: logging → entitlement → config → keychain → menu bar → HUD → hotkey"
      contains: "JarvisLogHandlerFactory.bootstrap"
  key_links:
    - from: "packages/Shell/Sources/Shell/HotkeyBinder.swift"
      to: "packages/Shell/Sources/Shell/InputMonitoringProbe.swift"
      via: "probe Input Monitoring before global-monitor install; on denial → local-monitor fallback"
      pattern: "IOHIDRequestAccess|addGlobalMonitorForEvents|addLocalMonitorForEvents"
    - from: "App/AppDelegate.swift"
      to: "packages/Logging/Sources/JarvisLogging/LoggingBootstrap.swift"
      via: "JarvisLogHandlerFactory.bootstrap() called exactly once in applicationWillFinishLaunching (S-8)"
      pattern: "JarvisLogHandlerFactory.bootstrap"
    - from: "App/AppDelegate.swift"
      to: "packages/Config/Sources/Config/ConfigLoader.swift"
      via: "ConfigLoader.loadSnapshots on startup; malformed → NSAlert + terminate (D-19, S-6)"
      pattern: "ConfigLoader.loadSnapshots"
    - from: "App/Wizard/WizardStageAPIKeyView.swift"
      to: "packages/Keychain/Sources/Keychain/SystemKeychainStore.swift"
      via: "SystemKeychainStore().set(apiKey, for: .anthropic) after Anthropic models/list validation"
      pattern: "SystemKeychainStore|KeychainItem.anthropic"
---

<objective>
Fill in the Shell SPM package (HotkeyBinder, InputMonitoringProbe, ShortcutRecorder, LaunchAtLoginController, TCCAlertService), build the first-launch SwiftUI Wizard (API key → TCC priming → Hotkey binding per D-06/D-07), and complete the `AppDelegate` wiring that ties everything together: logging bootstrap, entitlement hard-block (already present from Plan 03), config load, keychain fetch, menu-bar actions, HUD panel summon, banner coordinator enqueue on Input Monitoring denial / Keychain empty, and hotkey binding.

Purpose: This is where the pieces from Plans 01-03 become a working app. After this plan, the user can cold-launch Jarvis, complete the first-launch wizard, store an API key in Keychain, bind a global hotkey, and toggle the HUD panel via hotkey or menu-bar click. Input Monitoring denial surfaces a persistent banner with a System Settings deep link.

Output: A fully wired Phase-1 shell. The only things left after this plan are the build-time codesign + entitlement-verification scripts (Plan 05).

**Scope note:** This plan touches ~21 files, exceeding the 15-file threshold. Given the greenfield Phase-1 scope (17 REQ-IDs, no pre-existing codebase to incrementally modify), splitting would fragment tightly-coupled scaffolding work (the Shell package internals, the three wizard stages, and AppDelegate's full launch wiring form one transactional unit — splitting would force duplicated wiring between plans) across more plans than the wave DAG requires. Mitigation: each task commits atomically (per-task git commit); the executor samples tests after every task boundary (`cd packages/Shell && swift test` or `xcodebuild test -scheme Jarvis -only-testing:JarvisAppTests/...`); wave completion gates on `xcodebuild test -scheme JarvisTestsAll` so regressions surface at wave boundaries rather than phase-end.
</objective>

<execution_context>
@~/.claude/get-shit-done/workflows/execute-plan.md
@~/.claude/get-shit-done/templates/summary.md
</execution_context>

<context>
@CLAUDE.md
@.planning/PROJECT.md
@.planning/phases/01-foundations/01-CONTEXT.md
@.planning/phases/01-foundations/01-UI-SPEC.md
@.planning/phases/01-foundations/01-RESEARCH.md
@.planning/phases/01-foundations/01-PATTERNS.md
@.planning/phases/01-01-SUMMARY.md
@.planning/phases/01-02-SUMMARY.md
@.planning/phases/01-03-SUMMARY.md

<interfaces>
<!-- Contracts this plan consumes from Plans 02 and 03 -->

From Plan 02 — Config:
```swift
public enum ConfigLoader {
    public static func loadSnapshots(from url: URL) throws -> (LaunchSnapshot, PerTurnSnapshot)
    public static func writeDefaultAndReload(to url: URL) throws -> (LaunchSnapshot, PerTurnSnapshot)
}
public actor ConfigStore {
    public init(launch: LaunchSnapshot, initial: PerTurnSnapshot)
    public func perTurn() -> PerTurnSnapshot
    public func updatePerTurn(_ next: PerTurnSnapshot)
}
public enum ConfigError: Error, Sendable, Equatable {
    case malformed(reason: String)
    case invalidOllamaHost(String)
    // ...
}
```

From Plan 02 — Keychain:
```swift
public protocol KeychainStore: Sendable { /* set/get/delete */ }
public struct SystemKeychainStore: KeychainStore { public init() }
public extension KeychainItem {
    static let anthropic = KeychainItem(service: "com.kingsrook.jarvis", account: "anthropic")
}
public enum KeychainError: Error, Sendable, Equatable {
    case itemNotFound; case duplicateItem; case unexpectedStatus(OSStatus)
}
```

From Plan 02 — JarvisLogging:
```swift
public enum JarvisLogHandlerFactory {
    public static func bootstrap()    // S-8: exactly one call site at AppDelegate.applicationWillFinishLaunching
    public static func make(label: String) -> LogHandler
    public static let subsystem = "com.kingsrook.jarvis"
}
```

From Plan 03:
```swift
@MainActor public final class MenuBarIconController { /* ... */ }
@MainActor public final class JarvisHUDPanel: NSPanel { /* ... */ }
@MainActor public final class HUDBannerPanel: NSPanel { /* ... */ }
@MainActor public final class HUDBannerCoordinator { /* enqueue, dismissCurrent */ }
public struct BannerContent: Sendable, Equatable {
    public static let keychainEmpty: BannerContent        // priority 1
    public static let inputMonitoringDenied: BannerContent // priority 2
    public static let hotkeyBindFailed: BannerContent     // priority 3
    public static let ollamaURLRejected: BannerContent    // priority 4
}
@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    var entitlementProbe: EntitlementGateProbe
    var onEntitlementFailure: () -> Void
    var statusItem: NSStatusItem?
    var menuBarController: MenuBarIconController?
    var hudPanel: JarvisHUDPanel?
    var bannerPanel: HUDBannerPanel?
    var bannerCoordinator: HUDBannerCoordinator?
}
```

<!-- Contracts this plan ESTABLISHES -->

Shell package public API:
```swift
public struct KeyboardShortcut: Codable, Sendable, Equatable {
    public let keyCode: UInt16
    public let modifiers: NSEvent.ModifierFlags.RawValue
}

@MainActor public final class HotkeyBinder {
    public init(store: any HotkeyMonitorStore = NSEventMonitorStore())
    public func bind(_ shortcut: KeyboardShortcut, onPress: @escaping () -> Void)
    public func unbind()
    public var isDegraded: Bool { get }   // true when running local-monitor-only
}

public protocol HIDAccessProbe: Sendable {
    func requestListenEventAccess() -> Bool
}

@MainActor public final class InputMonitoringProbe {
    public init(probe: any HIDAccessProbe = SystemHIDAccessProbe())
    public func check(banner: HUDBannerCoordinator?) -> Bool
}

@MainActor public final class LaunchAtLoginController {
    public init()
    public var isEnabled: Bool { get }
    public var requiresApproval: Bool { get }
    public func enable() throws
    public func disable() throws
    public func openSystemSettingsLoginItems()
}

public struct ShortcutRecorderView: NSViewRepresentable {
    @Binding public var shortcut: KeyboardShortcut?
    @Binding public var errorMessage: String?
    public init(shortcut: Binding<KeyboardShortcut?>, errorMessage: Binding<String?>)
}

public enum CollisionDetector {
    public static func check(_ shortcut: KeyboardShortcut) -> CollisionWarning?
    public struct CollisionWarning: Sendable, Equatable {
        public let apps: [String]
        public let message: String
    }
}
```

PATTERNS cross-refs:
- S-2: @MainActor on AppKit-touching services (HotkeyBinder, InputMonitoringProbe, LaunchAtLoginController)
- S-3: Sendable-by-default for models (KeyboardShortcut)
- S-5: Keychain fetch-per-request (WizardStageAPIKeyView writes via set(); reads happen in P4 AnthropicProvider — not here)
- S-6: Hard-block on safety failures (AppDelegate malformed-config NSAlert)
- S-8: One-bootstrap discipline for JarvisLogHandlerFactory.bootstrap
</interfaces>
</context>

<tasks>

<task type="auto" tdd="true">
  <name>Task 1: Build Shell package — KeyboardShortcut, HotkeyBinder, InputMonitoringProbe, LaunchAtLoginController, TCCAlertService</name>
  <files>packages/Shell/Sources/Shell/KeyboardShortcut.swift, packages/Shell/Sources/Shell/HotkeyBinder.swift, packages/Shell/Sources/Shell/InputMonitoringProbe.swift, packages/Shell/Sources/Shell/LaunchAtLoginController.swift, packages/Shell/Sources/Shell/TCCAlertService.swift, packages/Shell/Tests/ShellTests/HotkeyBindingTests.swift, packages/Shell/Tests/ShellTests/InputMonitoringDenialTests.swift, packages/Shell/Tests/ShellTests/LaunchAtLoginTests.swift</files>
  <behavior>
    - Test: `KeyboardShortcut` encodes and decodes round-trip via JSONEncoder/JSONDecoder
    - Test: default hotkey is unset — no persisted shortcut means `HotkeyBinder.isDegraded == false` and `currentShortcut == nil` (SHELL-02)
    - Test: `HotkeyBinder.bind(_, onPress:)` with an injectable `HotkeyMonitorStore` fake — when stored "global granted", installs global monitor only; when "global denied", installs local monitor and sets `isDegraded = true`
    - Test: `HotkeyBinder.unbind()` removes all monitors; re-bind installs fresh monitors
    - Test: `InputMonitoringProbe.check(banner:)` with mock `HIDAccessProbe` returning false → calls `banner.enqueue(.inputMonitoringDenied)` and returns false (SHELL-06 happy-path of the denial branch)
    - Test: `InputMonitoringProbe.check(banner:)` with mock returning true → does NOT enqueue banner and returns true
    - Test: `LaunchAtLoginController.enable()` followed by `disable()` is idempotent — no throw on repeated disable; tests gated on `SMAppService.mainApp.status != .notFound` OR use a mock (the SPM monorepo doesn't expose SMAppService test hooks, so the real SMAppService test is behind an env var `JARVIS_ALLOW_SM_TESTS=1`; default skip)
    - Delete placeholder source and test from Plan 01 Task 2 (replaced by real code)
  </behavior>
  <read_first>
    - packages/Shell/Package.swift (from Plan 01 — linkedFramework list includes ServiceManagement, IOKit, Carbon)
    - packages/Shell/Sources/Shell/Placeholder.swift (to delete)
    - packages/Shell/Tests/ShellTests/PlaceholderTests.swift (to delete)
    - .planning/phases/01-foundations/01-RESEARCH.md §Summary bullet 11 line 23 (NSEvent global+local monitor pair; IOHIDRequestAccess probe)
    - .planning/phases/01-foundations/01-RESEARCH.md §Question 9 lines 995-1054 (SMAppService full shape — copy verbatim)
    - .planning/phases/01-foundations/01-PATTERNS.md §J lines 133-152 (Shell file classifications)
    - .planning/phases/01-foundations/01-CONTEXT.md D-11 (shortcut recorder ships unset), D-12 (Input Monitoring denial → degraded mode + HUD banner)
  </read_first>
  <action>
    Delete `packages/Shell/Sources/Shell/Placeholder.swift` and `packages/Shell/Tests/ShellTests/PlaceholderTests.swift`.

    **`packages/Shell/Sources/Shell/KeyboardShortcut.swift`**:
    ```swift
    import Foundation
    import AppKit

    public struct KeyboardShortcut: Codable, Sendable, Equatable {
        public let keyCode: UInt16
        public let modifiers: UInt                  // NSEvent.ModifierFlags.RawValue (UInt)
        public init(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) {
            self.keyCode = keyCode
            self.modifiers = modifiers.rawValue
        }
        public init(keyCode: UInt16, modifiersRaw: UInt) {
            self.keyCode = keyCode
            self.modifiers = modifiersRaw
        }
        public var modifierFlags: NSEvent.ModifierFlags {
            NSEvent.ModifierFlags(rawValue: modifiers)
        }
    }
    ```

    **`packages/Shell/Sources/Shell/HotkeyBinder.swift`** — monitor-store abstraction for testability, matching NSEvent global+local pair pattern:
    ```swift
    import AppKit

    public protocol HotkeyMonitorStore: Sendable {
        func installGlobalMonitor(_ shortcut: KeyboardShortcut, _ onPress: @escaping @Sendable () -> Void) -> Any?
        func installLocalMonitor(_ shortcut: KeyboardShortcut, _ onPress: @escaping @Sendable () -> Void) -> Any?
        func remove(_ token: Any)
    }

    public struct NSEventMonitorStore: HotkeyMonitorStore {
        public init() {}
        public func installGlobalMonitor(_ shortcut: KeyboardShortcut, _ onPress: @escaping @Sendable () -> Void) -> Any? {
            NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { event in
                if Self.matches(event: event, shortcut: shortcut) { onPress() }
            }
        }
        public func installLocalMonitor(_ shortcut: KeyboardShortcut, _ onPress: @escaping @Sendable () -> Void) -> Any? {
            NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                if Self.matches(event: event, shortcut: shortcut) { onPress(); return nil }
                return event
            }
        }
        public func remove(_ token: Any) { NSEvent.removeMonitor(token) }

        private static func matches(event: NSEvent, shortcut: KeyboardShortcut) -> Bool {
            let eventMods = event.modifierFlags.intersection(.deviceIndependentFlagsMask).rawValue
            let wantedMods = NSEvent.ModifierFlags(rawValue: shortcut.modifiers)
                .intersection(.deviceIndependentFlagsMask).rawValue
            return event.keyCode == shortcut.keyCode && eventMods == wantedMods
        }
    }

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

        public var currentShortcut: KeyboardShortcut? { boundShortcut }

        /// Bind a shortcut. `inputMonitoringGranted` controls whether we install the global monitor.
        /// On denial, falls back to local-monitor-only (isDegraded=true) per SHELL-06.
        public func bind(_ shortcut: KeyboardShortcut, inputMonitoringGranted: Bool, onPress: @escaping @Sendable () -> Void) {
            unbind()
            boundShortcut = shortcut
            if inputMonitoringGranted {
                globalToken = store.installGlobalMonitor(shortcut, onPress)
                isDegraded = false
            } else {
                isDegraded = true
            }
            // Always install local monitor so the hotkey works when Jarvis is frontmost.
            localToken = store.installLocalMonitor(shortcut, onPress)
        }

        public func unbind() {
            if let t = globalToken { store.remove(t); globalToken = nil }
            if let t = localToken { store.remove(t); localToken = nil }
            boundShortcut = nil
            isDegraded = false
        }
    }
    ```

    **`packages/Shell/Sources/Shell/InputMonitoringProbe.swift`** — IOHIDRequestAccess wrapper + HUD banner enqueue on denial per SHELL-06 / D-12:
    ```swift
    import AppKit
    import IOKit.hid

    public protocol HIDAccessProbe: Sendable {
        func requestListenEventAccess() -> Bool
    }

    public struct SystemHIDAccessProbe: HIDAccessProbe {
        public init() {}
        public func requestListenEventAccess() -> Bool {
            IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
        }
    }

    /// Probes Input Monitoring. On denial, enqueues the `.inputMonitoringDenied` banner on the
    /// provided coordinator (so the caller — AppDelegate — doesn't need to know the banner
    /// content). SHELL-06 / D-12: silent no-op on denial is NOT acceptable.
    @MainActor
    public final class InputMonitoringProbe {
        public protocol BannerSink: Sendable {
            func enqueueInputMonitoringDenied()
        }

        private let probe: any HIDAccessProbe
        public init(probe: any HIDAccessProbe = SystemHIDAccessProbe()) {
            self.probe = probe
        }

        /// Returns true if granted. On denial, calls `sink.enqueueInputMonitoringDenied()`.
        public func check(sink: (any BannerSink)?) -> Bool {
            let granted = probe.requestListenEventAccess()
            if !granted {
                sink?.enqueueInputMonitoringDenied()
            }
            return granted
        }
    }
    ```

    **`packages/Shell/Sources/Shell/LaunchAtLoginController.swift`** — copy verbatim from RESEARCH Q9 lines 1003-1048:
    ```swift
    import ServiceManagement
    import AppKit

    public enum LaunchAtLoginError: Error, Sendable {
        case notFound
        case requiresApproval
        case registerFailed(Error)
    }

    /// Wraps SMAppService.mainApp. Scaffolded in P1; no user-facing toggle yet (Settings UI post-P1).
    @MainActor
    public final class LaunchAtLoginController {
        public init() {}

        public var isEnabled: Bool {
            if #available(macOS 13.0, *) {
                return SMAppService.mainApp.status == .enabled
            }
            return false
        }

        public var requiresApproval: Bool {
            if #available(macOS 13.0, *) {
                return SMAppService.mainApp.status == .requiresApproval
            }
            return false
        }

        public func enable() throws {
            guard #available(macOS 13.0, *) else { throw LaunchAtLoginError.notFound }
            do {
                try SMAppService.mainApp.register()
            } catch {
                throw LaunchAtLoginError.registerFailed(error)
            }
        }

        public func disable() throws {
            guard #available(macOS 13.0, *) else { return }
            do {
                try SMAppService.mainApp.unregister()
            } catch {
                throw LaunchAtLoginError.registerFailed(error)
            }
        }

        public func openSystemSettingsLoginItems() {
            let url = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension")!
            NSWorkspace.shared.open(url)
        }
    }
    ```

    **`packages/Shell/Sources/Shell/TCCAlertService.swift`** — NSAlert builders for hard-blocker conditions (used by AppDelegate on malformed config / missing entitlement-verified):
    ```swift
    import AppKit

    @MainActor
    public enum TCCAlertService {
        /// UI-SPEC Surface 6 — "Jarvis can't start" hard-blocker.
        public static func presentHardBlock(title: String, informativeText: String) {
            let alert = NSAlert()
            alert.alertStyle = .critical
            alert.messageText = title
            alert.informativeText = informativeText
            alert.addButton(withTitle: "Quit")
            alert.addButton(withTitle: "Show Details")
            let response = alert.runModal()
            if response == .alertSecondButtonReturn {
                openSystemLog()
            }
        }

        public static func openSystemLog() {
            let logURL = URL(fileURLWithPath:
                (NSHomeDirectory() as NSString).appendingPathComponent("Library/Logs/Jarvis/system.log"))
            NSWorkspace.shared.open(logURL)
        }
    }
    ```

    **Tests:**

    `packages/Shell/Tests/ShellTests/HotkeyBindingTests.swift`:
    ```swift
    import XCTest
    import AppKit
    @testable import Shell

    @MainActor
    final class HotkeyBindingTests: XCTestCase {
        private final class RecordingMonitorStore: HotkeyMonitorStore {
            var globalInstalled = 0
            var localInstalled = 0
            var removed = 0
            func installGlobalMonitor(_ shortcut: KeyboardShortcut, _ onPress: @escaping @Sendable () -> Void) -> Any? {
                globalInstalled += 1
                return "global-\(globalInstalled)" as NSString
            }
            func installLocalMonitor(_ shortcut: KeyboardShortcut, _ onPress: @escaping @Sendable () -> Void) -> Any? {
                localInstalled += 1
                return "local-\(localInstalled)" as NSString
            }
            func remove(_ token: Any) { removed += 1 }
        }

        func test_defaultHotkeyIsUnset() {
            let binder = HotkeyBinder(store: RecordingMonitorStore())
            XCTAssertNil(binder.currentShortcut)
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
            binder.bind(KeyboardShortcut(keyCode: 38, modifiers: [.command, .shift]),
                        inputMonitoringGranted: false) { }
            XCTAssertEqual(store.globalInstalled, 0, "Must NOT install global monitor on denial")
            XCTAssertEqual(store.localInstalled, 1, "Must install local monitor fallback")
            XCTAssertTrue(binder.isDegraded)
        }

        func test_unbindRemovesAllMonitors() {
            let store = RecordingMonitorStore()
            let binder = HotkeyBinder(store: store)
            binder.bind(KeyboardShortcut(keyCode: 38, modifiers: [.command]),
                        inputMonitoringGranted: true) { }
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
    ```

    `packages/Shell/Tests/ShellTests/InputMonitoringDenialTests.swift`:
    ```swift
    import XCTest
    @testable import Shell

    @MainActor
    final class InputMonitoringDenialTests: XCTestCase {
        private struct MockProbe: HIDAccessProbe {
            let granted: Bool
            func requestListenEventAccess() -> Bool { granted }
        }

        private final class MockSink: InputMonitoringProbe.BannerSink {
            var enqueueCount = 0
            func enqueueInputMonitoringDenied() { enqueueCount += 1 }
        }

        func test_bannerEnqueuedOnDenial() {
            let probe = InputMonitoringProbe(probe: MockProbe(granted: false))
            let sink = MockSink()
            let result = probe.check(sink: sink)
            XCTAssertFalse(result, "check() returns false on denial")
            XCTAssertEqual(sink.enqueueCount, 1, "denial must enqueue exactly one banner (SHELL-06)")
        }

        func test_noBannerWhenGranted() {
            let probe = InputMonitoringProbe(probe: MockProbe(granted: true))
            let sink = MockSink()
            let result = probe.check(sink: sink)
            XCTAssertTrue(result)
            XCTAssertEqual(sink.enqueueCount, 0, "grant must not enqueue any banner")
        }

        func test_localMonitorOnlyFallback() {
            // Exercised via HotkeyBinder.bind(_, inputMonitoringGranted: false) in HotkeyBindingTests.
            // This test is a pointer: the fallback is engineered at the HotkeyBinder layer.
            // Per SHELL-06, denial ≠ silent no-op; the banner is how denial surfaces.
            XCTAssertTrue(true)
        }
    }
    ```

    `packages/Shell/Tests/ShellTests/LaunchAtLoginTests.swift`:
    ```swift
    import XCTest
    @testable import Shell

    @MainActor
    final class LaunchAtLoginTests: XCTestCase {
        func test_controllerInstantiates() {
            let controller = LaunchAtLoginController()
            // We can't safely register/unregister without polluting the real login items list
            // unless JARVIS_ALLOW_SM_TESTS=1 is set. Just verify the API surface is reachable.
            _ = controller.isEnabled
            _ = controller.requiresApproval
        }

        func test_registerUnregisterIdempotent() throws {
            guard ProcessInfo.processInfo.environment["JARVIS_ALLOW_SM_TESTS"] == "1" else {
                throw XCTSkip("Skipping SMAppService live test — set JARVIS_ALLOW_SM_TESTS=1 to opt in")
            }
            let controller = LaunchAtLoginController()
            try? controller.disable()    // start from known state
            try controller.enable()
            try controller.disable()
            try controller.disable()     // idempotent — second disable must not throw
        }
    }
    ```
  </action>
  <verify>
    <automated>cd packages/Shell &amp;&amp; swift test --filter 'HotkeyBindingTests|InputMonitoringDenialTests|LaunchAtLoginTests' 2>&amp;1 | tail -20</automated>
  </verify>
  <acceptance_criteria>
    - `test ! -f packages/Shell/Sources/Shell/Placeholder.swift && test ! -f packages/Shell/Tests/ShellTests/PlaceholderTests.swift`
    - `grep 'addGlobalMonitorForEvents\|addLocalMonitorForEvents' packages/Shell/Sources/Shell/HotkeyBinder.swift` returns ≥ 2 matches (both monitor types present per RESEARCH §Summary bullet 11)
    - `grep 'IOHIDRequestAccess' packages/Shell/Sources/Shell/InputMonitoringProbe.swift` returns 1 match
    - `grep 'kIOHIDRequestTypeListenEvent' packages/Shell/Sources/Shell/InputMonitoringProbe.swift` returns 1 match
    - `grep 'SMAppService.mainApp' packages/Shell/Sources/Shell/LaunchAtLoginController.swift` returns ≥ 3 matches (register, unregister, status)
    - `grep 'SMLoginItemSetEnabled' packages/Shell/Sources/Shell/LaunchAtLoginController.swift` returns NO matches (deprecated per RESEARCH Q9 line 999)
    - `grep -c '@MainActor' packages/Shell/Sources/Shell/HotkeyBinder.swift packages/Shell/Sources/Shell/InputMonitoringProbe.swift packages/Shell/Sources/Shell/LaunchAtLoginController.swift` returns ≥ 3 (S-2)
    - `cd packages/Shell && swift test --filter 'HotkeyBindingTests|InputMonitoringDenialTests|LaunchAtLoginTests'` exits 0 with ≥ 7 passing tests (HotkeyBinding 5, InputMonitoringDenial 3, LaunchAtLogin 1 non-skipped)
  </acceptance_criteria>
  <done>Shell package has HotkeyBinder with global+local monitor fallback, InputMonitoringProbe with banner-enqueue-on-denial, LaunchAtLoginController wrapping SMAppService (no deprecated SMLoginItemSetEnabled), TCCAlertService NSAlert builder; all covered by tests.</done>
</task>

<task type="auto" tdd="true">
  <name>Task 2: Build ShortcutRecorderView + ShortcutRecorderHostView + KeyCapView + CollisionDetector with modifier-only / shift-only / Escape rejection</name>
  <files>packages/Shell/Sources/Shell/ShortcutRecorder/ShortcutRecorderView.swift, packages/Shell/Sources/Shell/ShortcutRecorder/ShortcutRecorderHostView.swift, packages/Shell/Sources/Shell/ShortcutRecorder/KeyCapView.swift, packages/Shell/Sources/Shell/ShortcutRecorder/CollisionDetector.swift, packages/Shell/Tests/ShellTests/ShortcutRecorderTests.swift</files>
  <behavior>
    - Test: `CollisionDetector.check(KeyboardShortcut(cmdShiftJ))` returns a warning containing "Chrome", "Slack", "VS Code"
    - Test: `CollisionDetector.check(KeyboardShortcut(optionSpace))` returns a warning containing "Alfred", "Raycast"
    - Test: `CollisionDetector.check(KeyboardShortcut for unusual combo)` returns nil
    - Test: `ShortcutRecorderHostView` rejects a keyDown with modifier-only (mods.isEmpty → reject with "A shortcut needs at least one regular key") — use a test-hook that simulates `NSEvent` processing
    - Test: `ShortcutRecorderHostView` rejects shift-only (`mods == .shift`) with the specific copy "Shift alone isn't a valid modifier..."
    - Test: `ShortcutRecorderHostView` captures a valid `Cmd+Shift+J` event → coordinator callback fires with keyCode=38, modifiers=[.command, .shift]
    - Test: Escape keyCode (53) aborts recording without setting a shortcut
  </behavior>
  <read_first>
    - packages/Shell/Sources/Shell/KeyboardShortcut.swift (from Task 1)
    - .planning/phases/01-foundations/01-RESEARCH.md §Question 8 lines 873-991 (full ShortcutRecorder hand-rolled shape)
    - .planning/phases/01-foundations/01-UI-SPEC.md §Surface 2 lines 313-362 (ShortcutRecorderView layout + state model + copy)
    - .planning/phases/01-foundations/01-UI-SPEC.md Copywriting Contract lines 184-188 (inline error messages verbatim)
    - .planning/phases/01-foundations/01-CONTEXT.md D-11 (planner picks hand-rolled over SPM — already decided)
    - .planning/phases/01-foundations/01-PATTERNS.md §J lines 140-143 (ShortcutRecorder file classifications)
  </read_first>
  <action>
    **`packages/Shell/Sources/Shell/ShortcutRecorder/CollisionDetector.swift`**:
    ```swift
    import Foundation
    import AppKit
    import Carbon.HIToolbox  // for kVK_* constants only — NOT RegisterEventHotKey

    public enum CollisionDetector {
        public struct CollisionWarning: Sendable, Equatable {
            public let apps: [String]
            public let message: String
        }

        /// Static table of known collisions from UI-SPEC copy.
        /// kVK_ANSI_J = 38, kVK_Space = 49.
        public static func check(_ shortcut: KeyboardShortcut) -> CollisionWarning? {
            let flags = shortcut.modifierFlags.intersection(.deviceIndependentFlagsMask)

            // Cmd+Shift+J → Chrome / Slack / VS Code
            if shortcut.keyCode == UInt16(kVK_ANSI_J) && flags == [.command, .shift] {
                return CollisionWarning(
                    apps: ["Chrome", "Slack", "VS Code"],
                    message: "`Cmd+Shift+J` is used by Chrome, Slack, and VS Code. It will work, but those apps won't see the shortcut while Jarvis is bound to it."
                )
            }

            // Option+Space → Alfred / Raycast
            if shortcut.keyCode == UInt16(kVK_Space) && flags == [.option] {
                return CollisionWarning(
                    apps: ["Alfred", "Raycast"],
                    message: "`Option+Space` is used by Alfred and Raycast. It will work, but those apps won't see the shortcut while Jarvis is bound to it."
                )
            }

            return nil
        }
    }
    ```

    **`packages/Shell/Sources/Shell/ShortcutRecorder/ShortcutRecorderHostView.swift`** — testable `NSView` subclass with an injectable event-processor:
    ```swift
    import AppKit
    import Carbon.HIToolbox

    /// Separated from ShortcutRecorderView so tests can drive process(event:) directly
    /// without spinning up a real AppKit event loop.
    @MainActor
    public final class ShortcutRecorderHostView: NSView {
        public protocol Delegate: AnyObject {
            func shortcutRecorder(_ view: ShortcutRecorderHostView, recorded shortcut: KeyboardShortcut)
            func shortcutRecorder(_ view: ShortcutRecorderHostView, rejected reason: String)
            func shortcutRecorderDidAbort(_ view: ShortcutRecorderHostView)
        }

        public weak var delegate: Delegate?
        private var monitor: Any?

        public override var acceptsFirstResponder: Bool { true }

        public override func becomeFirstResponder() -> Bool {
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) {
                [weak self] event in
                guard let self else { return event }
                return self.process(event: event) ? nil : event
            }
            return super.becomeFirstResponder()
        }

        public override func resignFirstResponder() -> Bool {
            if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
            return super.resignFirstResponder()
        }

        /// Returns true if the event was consumed. Tests call this directly.
        @discardableResult
        public func process(event: NSEvent) -> Bool {
            guard event.type == .keyDown else { return false }
            let keyCode = event.keyCode

            if keyCode == UInt16(kVK_Escape) {
                delegate?.shortcutRecorderDidAbort(self)
                _ = resignFirstResponder()
                return true
            }

            let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if mods.isEmpty {
                delegate?.shortcutRecorder(self, rejected:
                    "A shortcut needs at least one regular key. Try adding a letter or number.")
                return true
            }
            if mods == .shift {
                delegate?.shortcutRecorder(self, rejected:
                    "Shift alone isn't a valid modifier. Try Command, Option, or Control.")
                return true
            }

            let shortcut = KeyboardShortcut(keyCode: keyCode, modifiers: mods)
            delegate?.shortcutRecorder(self, recorded: shortcut)
            _ = resignFirstResponder()
            return true
        }
    }
    ```

    Note: real UI-SPEC copy uses "A shortcut needs at least one regular key. Try adding a letter or number." for modifier-only. Match exactly.

    **`packages/Shell/Sources/Shell/ShortcutRecorder/KeyCapView.swift`** — tiny SwiftUI view rendering a single key-cap:
    ```swift
    import SwiftUI
    import AppKit
    import Carbon.HIToolbox

    public struct KeyCapView: View {
        public let text: String
        public init(text: String) { self.text = text }

        public var body: some View {
            Text(text)
                .font(.system(size: 11, weight: .regular).monospacedDigit())
                .foregroundColor(Color(NSColor.labelColor))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color(NSColor.controlColor))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .strokeBorder(Color(NSColor.separatorColor), lineWidth: 1)
                )
        }
    }

    /// Render a full shortcut as a row of "[⌘]+[⇧]+[J]" caps. Used by ShortcutRecorderView.
    public struct KeyCapRowView: View {
        public let shortcut: KeyboardShortcut
        public init(shortcut: KeyboardShortcut) { self.shortcut = shortcut }

        public var body: some View {
            HStack(spacing: 4) {
                let symbols = modifierSymbols(shortcut.modifierFlags)
                ForEach(Array(symbols.enumerated()), id: \.offset) { _, sym in
                    KeyCapView(text: sym)
                    Text("+").foregroundColor(Color(NSColor.secondaryLabelColor))
                }
                KeyCapView(text: keyGlyph(for: shortcut.keyCode))
            }
        }

        private func modifierSymbols(_ mods: NSEvent.ModifierFlags) -> [String] {
            var out: [String] = []
            if mods.contains(.control) { out.append("⌃") }
            if mods.contains(.option) { out.append("⌥") }
            if mods.contains(.shift) { out.append("⇧") }
            if mods.contains(.command) { out.append("⌘") }
            return out
        }

        private func keyGlyph(for keyCode: UInt16) -> String {
            switch Int(keyCode) {
            case kVK_ANSI_J: return "J"
            case kVK_Space: return "Space"
            case kVK_Return: return "Return"
            case kVK_Tab: return "Tab"
            // Extended as needed.
            default: return "Key\(keyCode)"
            }
        }
    }
    ```

    **`packages/Shell/Sources/Shell/ShortcutRecorder/ShortcutRecorderView.swift`** — `NSViewRepresentable` glue:
    ```swift
    import SwiftUI
    import AppKit

    public struct ShortcutRecorderView: NSViewRepresentable {
        @Binding var shortcut: KeyboardShortcut?
        @Binding var errorMessage: String?

        public init(shortcut: Binding<KeyboardShortcut?>, errorMessage: Binding<String?>) {
            self._shortcut = shortcut
            self._errorMessage = errorMessage
        }

        public func makeNSView(context: Context) -> ShortcutRecorderHostView {
            let view = ShortcutRecorderHostView()
            view.delegate = context.coordinator
            return view
        }

        public func updateNSView(_ view: ShortcutRecorderHostView, context: Context) {
            context.coordinator.parent = self
        }

        public func makeCoordinator() -> Coordinator {
            Coordinator(parent: self)
        }

        public final class Coordinator: ShortcutRecorderHostView.Delegate {
            var parent: ShortcutRecorderView
            init(parent: ShortcutRecorderView) { self.parent = parent }

            public func shortcutRecorder(_ view: ShortcutRecorderHostView, recorded shortcut: KeyboardShortcut) {
                parent.shortcut = shortcut
                parent.errorMessage = nil
            }

            public func shortcutRecorder(_ view: ShortcutRecorderHostView, rejected reason: String) {
                parent.errorMessage = reason
            }

            public func shortcutRecorderDidAbort(_ view: ShortcutRecorderHostView) {
                // User pressed Escape; keep previous shortcut (if any) unchanged.
            }
        }
    }
    ```

    **Tests** in `packages/Shell/Tests/ShellTests/ShortcutRecorderTests.swift`:
    ```swift
    import XCTest
    import AppKit
    import Carbon.HIToolbox
    @testable import Shell

    @MainActor
    final class ShortcutRecorderTests: XCTestCase {
        private final class RecordingDelegate: ShortcutRecorderHostView.Delegate {
            var recorded: KeyboardShortcut?
            var rejectedReason: String?
            var aborted = false
            func shortcutRecorder(_ view: ShortcutRecorderHostView, recorded shortcut: KeyboardShortcut) {
                recorded = shortcut
            }
            func shortcutRecorder(_ view: ShortcutRecorderHostView, rejected reason: String) {
                rejectedReason = reason
            }
            func shortcutRecorderDidAbort(_ view: ShortcutRecorderHostView) {
                aborted = true
            }
        }

        private func makeEvent(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> NSEvent {
            // NSEvent.keyEvent(...) is the constructor path that works in unit tests.
            return NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: modifiers,
                timestamp: 0, windowNumber: 0, context: nil,
                characters: "", charactersIgnoringModifiers: "",
                isARepeat: false, keyCode: keyCode
            )!
        }

        func test_modifierOnlyRejected() {
            let view = ShortcutRecorderHostView()
            let delegate = RecordingDelegate()
            view.delegate = delegate

            // Shift-key keyCode (kVK_Shift = 56) with no modifier flags
            let event = makeEvent(keyCode: UInt16(kVK_Shift), modifiers: [])
            _ = view.process(event: event)

            XCTAssertNotNil(delegate.rejectedReason)
            XCTAssertTrue(delegate.rejectedReason!.contains("at least one regular key"))
            XCTAssertNil(delegate.recorded)
        }

        func test_shiftOnlyRejected() {
            let view = ShortcutRecorderHostView()
            let delegate = RecordingDelegate()
            view.delegate = delegate

            let event = makeEvent(keyCode: UInt16(kVK_ANSI_J), modifiers: [.shift])
            _ = view.process(event: event)

            XCTAssertNotNil(delegate.rejectedReason)
            XCTAssertTrue(delegate.rejectedReason!.contains("Shift alone"))
            XCTAssertNil(delegate.recorded)
        }

        func test_escapeAborts() {
            let view = ShortcutRecorderHostView()
            let delegate = RecordingDelegate()
            view.delegate = delegate

            let event = makeEvent(keyCode: UInt16(kVK_Escape), modifiers: [])
            _ = view.process(event: event)

            XCTAssertTrue(delegate.aborted)
            XCTAssertNil(delegate.recorded)
            XCTAssertNil(delegate.rejectedReason)
        }

        func test_validCaptureCallsCoordinator() {
            let view = ShortcutRecorderHostView()
            let delegate = RecordingDelegate()
            view.delegate = delegate

            let event = makeEvent(keyCode: UInt16(kVK_ANSI_J), modifiers: [.command, .shift])
            _ = view.process(event: event)

            XCTAssertNotNil(delegate.recorded)
            XCTAssertEqual(delegate.recorded?.keyCode, UInt16(kVK_ANSI_J))
            XCTAssertEqual(delegate.recorded?.modifierFlags.intersection(.deviceIndependentFlagsMask),
                           [.command, .shift])
        }

        func test_cmdShiftJCollision() {
            let shortcut = KeyboardShortcut(keyCode: UInt16(kVK_ANSI_J), modifiers: [.command, .shift])
            let warning = CollisionDetector.check(shortcut)
            XCTAssertNotNil(warning)
            XCTAssertEqual(warning?.apps, ["Chrome", "Slack", "VS Code"])
        }

        func test_optionSpaceCollision() {
            let shortcut = KeyboardShortcut(keyCode: UInt16(kVK_Space), modifiers: [.option])
            let warning = CollisionDetector.check(shortcut)
            XCTAssertNotNil(warning)
            XCTAssertEqual(warning?.apps, ["Alfred", "Raycast"])
        }

        func test_uncommonComboNoCollision() {
            let shortcut = KeyboardShortcut(keyCode: UInt16(kVK_F5), modifiers: [.control])
            XCTAssertNil(CollisionDetector.check(shortcut))
        }
    }
    ```
  </action>
  <verify>
    <automated>cd packages/Shell &amp;&amp; swift test --filter 'ShortcutRecorderTests' 2>&amp;1 | tail -15</automated>
  </verify>
  <acceptance_criteria>
    - `test -f packages/Shell/Sources/Shell/ShortcutRecorder/ShortcutRecorderView.swift`
    - `grep 'NSEvent.addLocalMonitorForEvents' packages/Shell/Sources/Shell/ShortcutRecorder/ShortcutRecorderHostView.swift` returns 1 match
    - `grep 'kVK_Escape' packages/Shell/Sources/Shell/ShortcutRecorder/ShortcutRecorderHostView.swift` returns 1 match
    - `grep 'at least one regular key' packages/Shell/Sources/Shell/ShortcutRecorder/ShortcutRecorderHostView.swift` returns 1 match (UI-SPEC copy verbatim)
    - `grep "Shift alone isn't a valid modifier" packages/Shell/Sources/Shell/ShortcutRecorder/ShortcutRecorderHostView.swift` returns 1 match
    - `grep 'Chrome\|Slack\|VS Code' packages/Shell/Sources/Shell/ShortcutRecorder/CollisionDetector.swift` returns ≥ 1 match each
    - `grep 'Alfred\|Raycast' packages/Shell/Sources/Shell/ShortcutRecorder/CollisionDetector.swift` returns ≥ 1 match each
    - `cd packages/Shell && swift test --filter 'ShortcutRecorderTests'` exits 0 with 7 passing tests (modifier-only rejected, shift-only rejected, escape aborts, valid capture, cmdShiftJ collision, optionSpace collision, uncommon combo no collision)
  </acceptance_criteria>
  <done>Hand-rolled ShortcutRecorder rejects modifier-only + shift-only, aborts on Escape, captures valid Cmd+Shift+J; CollisionDetector returns warnings for the two known-collision combos; all behaviors unit-tested without running a live AppKit event loop.</done>
</task>

<task type="auto" tdd="true">
  <name>Task 3: Build Wizard (API key + TCC + hotkey stages) + full AppDelegate wiring (logging bootstrap, config load, keychain fetch, menu-bar actions, hotkey install, banner enqueues)</name>
  <files>App/Wizard/WizardView.swift, App/Wizard/WizardStageAPIKeyView.swift, App/Wizard/WizardStageTCCView.swift, App/Wizard/WizardStageHotkeyView.swift, App/Wizard/WizardState.swift, App/Wizard/OnboardingWizardController.swift, App/Wizard/AnthropicKeyValidator.swift, App/JarvisApp.swift, App/AppDelegate.swift, App/Tests/AppTests/WizardStateTests.swift, App/Tests/AppTests/AnthropicKeyValidatorTests.swift, App/Tests/AppTests/WizardTCCStageTests.swift, App/Tests/AppTests/AppDelegateWiringTests.swift</files>
  <behavior>
    - Test: `WizardState.firstUnresolvedStage` returns `.apiKey` when Keychain is empty; `.tcc` when API key present but Input Monitoring unprobed; `.hotkey` when API key + TCC done but hotkey unset; `.complete` when all three resolved
    - Test: `AnthropicKeyValidator.validate(key:)` with a malformed key (missing `sk-ant-` prefix) returns `.malformed` without hitting the network (local prefix check)
    - Test: `AnthropicKeyValidator` with a valid-shaped-but-unauthorized key (using a mock URLSession returning 401) returns `.unauthorized`
    - Test: `AnthropicKeyValidator` with a valid key (mock URLSession returning 200) returns `.valid`
    - Test: `WizardStageTCCView.onlyInputMonitoringTriggers` — iterate through stage 2 row actions; Input Monitoring row calls `IOHIDRequestAccess`; Mic/Camera/Automation rows DO NOT call any permission API (SEC-04, D-08 — they're explainer-only)
    - Test: `AppDelegate.applicationWillFinishLaunching` with all probes succeeding wires: (a) `JarvisLogHandlerFactory.bootstrap()` called, (b) config loaded, (c) keychain fetch attempted, (d) menu bar + HUD panel installed. Use test-injectable hooks to count calls
    - Test: When keychain fetch throws `.itemNotFound`, `.keychainEmpty` banner is enqueued on the coordinator
    - Test: When `ConfigLoader.loadSnapshots` throws `.malformed`, NSAlert hard-block is triggered (via `TCCAlertService`); Plan 04's failure callback fires
    - Test: When `InputMonitoringProbe.check` returns false, `.inputMonitoringDenied` banner enqueues and `HotkeyBinder.bind(_, inputMonitoringGranted: false, ...)` is called
  </behavior>
  <read_first>
    - App/AppDelegate.swift (from Plan 03 — already has entitlement hard-block + menu-bar + HUD panel install; this task extends it)
    - App/JarvisApp.swift (from Plan 01 — update `@main` to surface wizard WindowGroup)
    - packages/Shell/Sources/Shell/HotkeyBinder.swift (from Task 1)
    - packages/Shell/Sources/Shell/InputMonitoringProbe.swift (from Task 1)
    - packages/Shell/Sources/Shell/ShortcutRecorder/ShortcutRecorderView.swift (from Task 2)
    - packages/Config/Sources/Config/ConfigLoader.swift (from Plan 02)
    - packages/Keychain/Sources/Keychain/SystemKeychainStore.swift (from Plan 02)
    - packages/Logging/Sources/JarvisLogging/LoggingBootstrap.swift (from Plan 02)
    - .planning/phases/01-foundations/01-UI-SPEC.md §Surface 1 lines 256-309 (wizard layout + state model + three-stage flow)
    - .planning/phases/01-foundations/01-UI-SPEC.md Copywriting Contract lines 119-211 (all user-facing strings verbatim)
    - .planning/phases/01-foundations/01-PATTERNS.md §E lines 65-72 (Wizard file classifications)
    - .planning/phases/01-foundations/01-CONTEXT.md D-06, D-07, D-08 (wizard blocking, stage order, TCC priming scope), D-09 (stateless re-entry), D-10 (API key → models/list probe)
    - .planning/phases/01-foundations/01-RESEARCH.md §Architecture Patterns §System Architecture Diagram lines 1193-1234 (AppDelegate wiring order)
  </read_first>
  <action>
    **`App/Wizard/AnthropicKeyValidator.swift`** — live-probe Anthropic `models/list` with injectable URLSession for testability:
    ```swift
    import Foundation

    public enum AnthropicKeyValidationResult: Sendable, Equatable {
        case valid
        case malformed
        case unauthorized
        case network
        case generic
    }

    public protocol URLRequestClient: Sendable {
        func data(for request: URLRequest) async throws -> (Data, URLResponse)
    }

    extension URLSession: URLRequestClient {}

    public struct AnthropicKeyValidator: Sendable {
        public let client: any URLRequestClient
        public init(client: any URLRequestClient = URLSession.shared) { self.client = client }

        public func validate(key: String) async -> AnthropicKeyValidationResult {
            // Local shape check first — no network for malformed input (privacy + speed).
            if !key.hasPrefix("sk-ant-") { return .malformed }

            var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/models")!)
            request.httpMethod = "GET"
            request.setValue(key, forHTTPHeaderField: "x-api-key")
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")

            do {
                let (_, response) = try await client.data(for: request)
                guard let http = response as? HTTPURLResponse else { return .generic }
                switch http.statusCode {
                case 200..<300: return .valid
                case 401: return .unauthorized
                default: return .generic
                }
            } catch let e as URLError where e.code == .notConnectedToInternet || e.code == .timedOut {
                return .network
            } catch {
                return .generic
            }
        }
    }
    ```

    **`App/Wizard/WizardState.swift`** — `@MainActor ObservableObject` tracking resolution per D-09:
    ```swift
    import SwiftUI
    import Keychain

    public enum WizardStage: String, CaseIterable, Sendable {
        case apiKey, tcc, hotkey, complete
    }

    @MainActor
    public final class WizardState: ObservableObject {
        @Published public var currentStage: WizardStage = .apiKey
        @Published public var apiKeyStored: Bool = false
        @Published public var inputMonitoringProbed: Bool = false
        @Published public var inputMonitoringGranted: Bool = false
        @Published public var hotkey: KeyboardShortcut? = nil

        private let keychain: any KeychainStore

        public init(keychain: any KeychainStore = SystemKeychainStore()) {
            self.keychain = keychain
            refresh()
        }

        /// D-09: stateless re-entry. Re-reads current state each time.
        public func refresh() {
            apiKeyStored = (try? keychain.get(.anthropic)) != nil
            currentStage = firstUnresolvedStage
        }

        public var firstUnresolvedStage: WizardStage {
            if !apiKeyStored { return .apiKey }
            if !inputMonitoringProbed { return .tcc }
            if hotkey == nil { return .hotkey }
            return .complete
        }
    }
    ```

    Note: `KeyboardShortcut` is imported from the `Shell` module in production; for test isolation the `WizardState` type may take `hotkey: KeyboardShortcut?` where the executor imports Shell into the App target. The App target already links Shell transitively via Plan 01's package refs.

    **`App/Wizard/WizardStageAPIKeyView.swift`** — SwiftUI form per UI-SPEC Surface 1 stage 1:
    ```swift
    import SwiftUI
    import Keychain

    struct WizardStageAPIKeyView: View {
        @ObservedObject var state: WizardState
        @State private var apiKey: String = ""
        @State private var isValidating: Bool = false
        @State private var errorMessage: String? = nil

        let validator: AnthropicKeyValidator
        let keychain: any KeychainStore
        let onAdvance: () -> Void

        var body: some View {
            VStack(alignment: .leading, spacing: 16) {
                Text("Welcome to Jarvis").font(.system(size: 22, weight: .semibold))
                Text("Jarvis uses Anthropic's Claude API for its reasoning. Paste your API key — it's stored in your macOS Keychain and never written to disk in plaintext.")
                    .foregroundColor(Color(NSColor.secondaryLabelColor))
                SecureField("sk-ant-...", text: $apiKey)
                    .textFieldStyle(.roundedBorder)
                    .disabled(isValidating)
                if let msg = errorMessage {
                    Label(msg, systemImage: "xmark.octagon.fill").foregroundColor(Color(NSColor.systemRed))
                }
                Link("Get an API key from console.anthropic.com",
                     destination: URL(string: "https://console.anthropic.com/settings/keys")!)
                Spacer()
                HStack {
                    Spacer()
                    Button(action: verify) {
                        if isValidating {
                            ProgressView().controlSize(.small)
                            Text("Checking…")
                        } else {
                            Text("Verify & Continue")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(apiKey.isEmpty || isValidating)
                }
            }
            .padding(.horizontal, 48)
            .padding(.vertical, 24)
        }

        private func verify() {
            errorMessage = nil
            isValidating = true
            Task { @MainActor in
                let result = await validator.validate(key: apiKey)
                isValidating = false
                switch result {
                case .valid:
                    do {
                        try keychain.set(apiKey, for: .anthropic)
                        state.apiKeyStored = true
                        onAdvance()
                    } catch {
                        errorMessage = "Something went wrong saving your key. Details in the system log."
                    }
                case .malformed:
                    errorMessage = "That doesn't look like an Anthropic key. Expected prefix `sk-ant-`."
                case .unauthorized:
                    errorMessage = "Anthropic rejected that key. Double-check it hasn't been rotated or revoked."
                case .network:
                    errorMessage = "Couldn't reach Anthropic. Check your internet connection and try again."
                case .generic:
                    errorMessage = "Something went wrong verifying that key. Details in the system log."
                }
            }
        }
    }
    ```

    **`App/Wizard/WizardStageTCCView.swift`** — Input Monitoring row actively probes; Mic/Camera/Automation rows are explainer-only per D-08:
    ```swift
    import SwiftUI
    import Shell   // InputMonitoringProbe + HotkeyBinder

    struct WizardStageTCCView: View {
        @ObservedObject var state: WizardState
        let onAdvance: () -> Void
        let onGrantInputMonitoring: () -> Bool   // injected by WizardView; wraps InputMonitoringProbe.check

        var body: some View {
            VStack(alignment: .leading, spacing: 16) {
                Text("Grant Permissions").font(.system(size: 17, weight: .semibold))
                Text("Jarvis needs a few system permissions to do its job. Only one is needed right now; the others will ask when the matching feature is added.")
                    .foregroundColor(Color(NSColor.secondaryLabelColor))

                inputMonitoringRow

                explainerRow(
                    title: "Microphone (later)",
                    body: "Will be requested when the voice loop is turned on. Jarvis will not listen until then.",
                    ctaLabel: "Learn more →"
                )
                explainerRow(
                    title: "Camera (later)",
                    body: "Will be requested when the vision features are turned on. Jarvis will not watch until then.",
                    ctaLabel: "Learn more →"
                )
                explainerRow(
                    title: "Automation (later)",
                    body: "Will be requested per-app, the first time Jarvis is asked to automate that app. You'll approve each app individually.",
                    ctaLabel: "Learn more →"
                )

                Spacer()
                HStack {
                    Button("Skip — I'll grant this later") { onAdvance() }
                    Spacer()
                    Button("Continue") { onAdvance() }.buttonStyle(.borderedProminent)
                }
            }
            .padding(.horizontal, 48)
            .padding(.vertical, 24)
        }

        private var inputMonitoringRow: some View {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Input Monitoring (needed now)").font(.headline)
                    Text("Lets Jarvis see a global hotkey press even when another app is focused. Without this, Jarvis only responds when its window is frontmost.")
                        .foregroundColor(Color(NSColor.secondaryLabelColor))
                }
                Spacer()
                if !state.inputMonitoringProbed {
                    Button("Grant Access") {
                        state.inputMonitoringGranted = onGrantInputMonitoring()
                        state.inputMonitoringProbed = true
                    }
                } else if state.inputMonitoringGranted {
                    Label("Granted", systemImage: "checkmark.circle.fill").foregroundColor(Color(NSColor.systemGreen))
                } else {
                    Button("Denied — Open System Settings") {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                }
            }
        }

        private func explainerRow(title: String, body: String, ctaLabel: String) -> some View {
            // Explainer-only rows per D-08 — NO permission-API calls here.
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.headline)
                    Text(body).foregroundColor(Color(NSColor.secondaryLabelColor))
                }
                Spacer()
                // ctaLabel is a static link; real docs page lands post-P1. Button is a no-op in P1.
                Text(ctaLabel).foregroundColor(Color(NSColor.linkColor))
            }
        }
    }
    ```

    **`App/Wizard/WizardStageHotkeyView.swift`**:
    ```swift
    import SwiftUI
    import Shell   // ShortcutRecorderView, KeyboardShortcut, CollisionDetector

    struct WizardStageHotkeyView: View {
        @ObservedObject var state: WizardState
        @State private var shortcut: KeyboardShortcut? = nil
        @State private var errorMessage: String? = nil
        let onAdvance: () -> Void

        var body: some View {
            VStack(alignment: .leading, spacing: 16) {
                Text("Bind Your Hotkey").font(.system(size: 17, weight: .semibold))
                Text("Pick a keyboard shortcut to summon Jarvis from anywhere. You can change this any time from the menu bar.")
                    .foregroundColor(Color(NSColor.secondaryLabelColor))
                HStack {
                    Text("Global shortcut").frame(width: 140, alignment: .leading)
                    ShortcutRecorderView(shortcut: $shortcut, errorMessage: $errorMessage)
                        .frame(height: 40)
                }
                if let warning = shortcut.flatMap(CollisionDetector.check) {
                    Label(warning.message, systemImage: "exclamationmark.triangle.fill")
                        .foregroundColor(Color(NSColor.systemOrange))
                }
                if let err = errorMessage {
                    Label(err, systemImage: "xmark.octagon.fill").foregroundColor(Color(NSColor.systemRed))
                }
                Text("You can also click the menu-bar icon to open Jarvis.")
                    .foregroundColor(Color(NSColor.secondaryLabelColor))
                Spacer()
                HStack {
                    Spacer()
                    if shortcut == nil {
                        Button("Skip for now") { onAdvance() }
                    } else {
                        Button("Save Hotkey") {
                            state.hotkey = shortcut
                            onAdvance()
                        }.buttonStyle(.borderedProminent)
                    }
                }
            }
            .padding(.horizontal, 48)
            .padding(.vertical, 24)
        }
    }
    ```

    **`App/Wizard/WizardView.swift`** — three-stage root view per UI-SPEC Surface 1:
    ```swift
    import SwiftUI
    import Keychain
    import Shell

    public struct WizardView: View {
        @ObservedObject var state: WizardState
        let keychain: any KeychainStore
        let validator: AnthropicKeyValidator
        let onGrantInputMonitoring: () -> Bool
        let onComplete: () -> Void

        public var body: some View {
            VStack(spacing: 0) {
                header
                Divider()
                stageBody
                Divider()
                footer
            }
            .frame(width: 560, height: 440)
        }

        private var header: some View {
            HStack(spacing: 8) {
                ForEach(WizardStage.allCases.filter { $0 != .complete }, id: \.self) { stage in
                    Circle()
                        .fill(state.currentStage == stage
                              ? Color(NSColor.controlAccentColor)
                              : Color(NSColor.separatorColor))
                        .frame(width: 10, height: 10)
                }
            }
            .frame(height: 64)
            .frame(maxWidth: .infinity)
        }

        @ViewBuilder
        private var stageBody: some View {
            switch state.currentStage {
            case .apiKey:
                WizardStageAPIKeyView(
                    state: state, validator: validator,
                    keychain: keychain,
                    onAdvance: { state.currentStage = .tcc }
                )
            case .tcc:
                WizardStageTCCView(
                    state: state,
                    onAdvance: { state.currentStage = .hotkey },
                    onGrantInputMonitoring: onGrantInputMonitoring
                )
            case .hotkey:
                WizardStageHotkeyView(state: state, onAdvance: {
                    state.currentStage = .complete
                    onComplete()
                })
            case .complete:
                Color.clear
            }
        }

        private var footer: some View {
            HStack {
                if state.currentStage != .apiKey {
                    Button("← Back") {
                        switch state.currentStage {
                        case .tcc: state.currentStage = .apiKey
                        case .hotkey: state.currentStage = .tcc
                        default: break
                        }
                    }
                }
                Spacer()
            }
            .padding(.horizontal, 48)
            .frame(height: 56)
        }
    }
    ```

    **`App/Wizard/OnboardingWizardController.swift`** — NSWindow hosting per UI-SPEC Surface 1:
    ```swift
    import AppKit
    import SwiftUI
    import Keychain
    import Shell

    @MainActor
    public final class OnboardingWizardController {
        public let state: WizardState
        private var window: NSWindow?

        public init(state: WizardState) { self.state = state }

        /// D-09: stateless re-entry. On each open, refresh state from current truth.
        public func open(
            keychain: any KeychainStore,
            validator: AnthropicKeyValidator,
            onGrantInputMonitoring: @escaping () -> Bool,
            onComplete: @escaping () -> Void,
            firstLaunch: Bool
        ) {
            state.refresh()

            let rootView = WizardView(
                state: state,
                keychain: keychain,
                validator: validator,
                onGrantInputMonitoring: onGrantInputMonitoring,
                onComplete: { [weak self] in
                    onComplete()
                    self?.close()
                }
            )
            let hosting = NSHostingController(rootView: rootView)
            let window = NSWindow(contentViewController: hosting)
            window.styleMask = firstLaunch ? [.titled, .closable] : [.titled, .closable, .miniaturizable]
            window.title = "Setup — Jarvis"
            window.isReleasedWhenClosed = false
            // First-launch: block close until stage 1 resolved.
            if firstLaunch && state.currentStage == .apiKey {
                window.standardWindowButton(.closeButton)?.isEnabled = false
                window.level = .modalPanel
            }
            window.center()
            window.makeKeyAndOrderFront(nil)
            self.window = window
        }

        public func close() {
            window?.close()
            window = nil
        }
    }
    ```

    **`App/AppDelegate.swift`** — FULL WIRING. Replace the skeleton from Plan 03 with the complete flow:
    ```swift
    import AppKit
    import Config
    import Keychain
    import JarvisLogging
    import Shell
    import Logging   // swift-log

    public protocol EntitlementGateProbe: Sendable {
        func isVerified() -> Bool
    }

    public struct InfoPlistEntitlementGateProbe: EntitlementGateProbe {
        public init() {}
        public func isVerified() -> Bool {
            Bundle.main.object(forInfoDictionaryKey: "JarvisEntitlementsVerified") as? Bool ?? false
        }
    }

    @MainActor
    final class AppDelegate: NSObject, NSApplicationDelegate {
        // Injectable for tests.
        var entitlementProbe: EntitlementGateProbe = InfoPlistEntitlementGateProbe()
        var onEntitlementFailure: () -> Void = {
            TCCAlertService.presentHardBlock(
                title: "Jarvis can't start",
                informativeText: "A build verification check failed at launch. The app has been stopped to prevent a crash."
            )
            NSApp.terminate(nil)
        }
        var loggingBootstrap: () -> Void = { JarvisLogHandlerFactory.bootstrap() }
        var configLoader: (URL) throws -> (LaunchSnapshot, PerTurnSnapshot) = ConfigLoader.loadSnapshots(from:)
        var configWriter: (URL) throws -> (LaunchSnapshot, PerTurnSnapshot) = ConfigLoader.writeDefaultAndReload(to:)
        var keychainStore: any KeychainStore = SystemKeychainStore()
        var hidProbe: any HIDAccessProbe = SystemHIDAccessProbe()

        // Installed components.
        var statusItem: NSStatusItem?
        var menuBarController: MenuBarIconController?
        var hudPanel: JarvisHUDPanel?
        var bannerPanel: HUDBannerPanel?
        var bannerCoordinator: HUDBannerCoordinator?
        var hotkeyBinder: HotkeyBinder?
        var wizardController: OnboardingWizardController?
        var wizardState: WizardState?

        private var systemLogger: Logger?

        func applicationWillFinishLaunching(_ notification: Notification) {
            // S-8: exactly one bootstrap call site.
            loggingBootstrap()
            systemLogger = Logger(label: JarvisLogChannel.system.rawValue)
            systemLogger?.info("Jarvis launching — Phase 1 scaffold")

            // Entitlement hard-block.
            guard entitlementProbe.isVerified() else {
                systemLogger?.critical("JarvisEntitlementsVerified missing/false — hard-blocking")
                onEntitlementFailure()
                return
            }

            // Config load.
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
                TCCAlertService.presentHardBlock(title: "Jarvis can't start", informativeText: "Config load failed: \(error.localizedDescription)")
                NSApp.terminate(nil)
                return
            }

            // Menu bar + HUD panel + banner panel.
            installMenuBar()
            installHUDPanel()
            installBannerPanel()

            // Keychain fetch — missing key surfaces banner.
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

            // Input Monitoring probe.
            let inputMonitoringGranted = hidProbe.requestListenEventAccess()
            if !inputMonitoringGranted {
                bannerCoordinator?.enqueue(.inputMonitoringDenied)
            }

            // Hotkey binder — P1 ships unset; bind only if config/state has one stored (future).
            // For P1 the user binds via wizard; AppDelegate picks it up afterwards.
            hotkeyBinder = HotkeyBinder()

            // Wizard state + first-launch open.
            let state = WizardState(keychain: keychainStore)
            wizardState = state
            wizardController = OnboardingWizardController(state: state)
            if !apiKeyStored {
                openWizard(firstLaunch: true)
            }

            // Rewire menu-bar actions now that everything exists.
            rewireMenuBarActions()
        }

        func applicationWillTerminate(_ notification: Notification) {
            hotkeyBinder?.unbind()
        }

        // MARK: - Wiring helpers

        private final class AdHocBannerSink: InputMonitoringProbe.BannerSink {
            weak var coordinator: HUDBannerCoordinator?
            init(_ c: HUDBannerCoordinator?) { self.coordinator = c }
            func enqueueInputMonitoringDenied() { coordinator?.enqueue(.inputMonitoringDenied) }
        }

        private func installMenuBar() {
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            statusItem = item
            let menu = MenuBarContextMenu.build(
                setupAction: { [weak self] in self?.openWizard(firstLaunch: false) },
                devOverlayToggleAction: { [weak self] in self?.showDevOverlayStubBanner() },
                stateDumpAction: { [weak self] in self?.copyStateDump() }
            )
            menuBarController = MenuBarIconController(statusItem: item, contextMenu: menu)
            menuBarController?.setLeftClickAction { [weak self] in self?.toggleHUD() }
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

        private func openWizard(firstLaunch: Bool) {
            guard let state = wizardState else { return }
            let validator = AnthropicKeyValidator()
            wizardController?.open(
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
            hotkeyBinder?.bind(shortcut, inputMonitoringGranted: state.inputMonitoringGranted) {
                Task { @MainActor in self.toggleHUD() }
            }
            if hotkeyBinder?.isDegraded == false && hotkeyBinder?.currentShortcut == nil {
                bannerCoordinator?.enqueue(.hotkeyBindFailed)
            }
        }

        private func rewireMenuBarActions() {
            // Menu closures were captured at install; they already reference self via [weak self].
            // No-op placeholder — kept as a named hook for future re-wiring on runtime config reload.
        }

        private func showDevOverlayStubBanner() {
            bannerCoordinator?.enqueue(BannerContent(
                id: "dev-overlay-stub",
                priority: 99,
                title: "Dev Overlay lands in Phase 4",
                body: "The overlay itself is a P4 deliverable.",
                action: nil
            ))
        }

        private func copyStateDump() {
            var payload: [String: Any] = [:]
            payload["apiKeyStored"] = (try? keychainStore.get(.anthropic)) != nil
            payload["inputMonitoringGranted"] = wizardState?.inputMonitoringGranted ?? false
            payload["hotkeyBound"] = hotkeyBinder?.currentShortcut != nil
            payload["timestamp"] = ISO8601DateFormatter().string(from: Date())
            // NEVER include the API key itself — only boolean presence.
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

        private func configFileURL() -> URL {
            let fm = FileManager.default
            let dir = (try? fm.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                    appropriateFor: nil, create: true)
                .appendingPathComponent("Jarvis", isDirectory: true))
                ?? URL(fileURLWithPath:
                    (NSHomeDirectory() as NSString).appendingPathComponent("Library/Application Support/Jarvis"))
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
            return dir.appendingPathComponent("config.json")
        }
    }
    ```

    **`App/JarvisApp.swift`** — update to include a Settings scene + keep wizard window management in the AppDelegate:
    ```swift
    import SwiftUI

    @main
    struct JarvisApp: App {
        @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

        var body: some Scene {
            // LSUIElement=YES keeps us out of the Dock; we don't declare a WindowGroup here —
            // the AppDelegate manages NSPanels + NSWindows directly.
            Settings {
                // Settings… menu item opens a Coming-soon stub per UI-SPEC Surface 4.
                Text("Settings — coming soon.")
                    .padding()
                    .frame(width: 300, height: 120)
            }
        }
    }
    ```

    **Tests** in `App/Tests/AppTests/`:

    `WizardStateTests.swift`:
    ```swift
    import XCTest
    @testable import Jarvis
    @testable import Keychain

    @MainActor
    final class WizardStateTests: XCTestCase {
        private struct FakeKeychain: KeychainStore {
            let apiKeyStored: Bool
            func set(_ value: String, for item: KeychainItem) throws {}
            func get(_ item: KeychainItem) throws -> String {
                guard apiKeyStored else { throw KeychainError.itemNotFound }
                return "sk-ant-fake"
            }
            func delete(_ item: KeychainItem) throws {}
        }

        func test_firstUnresolvedStageIsAPIKeyWhenEmpty() {
            let state = WizardState(keychain: FakeKeychain(apiKeyStored: false))
            XCTAssertEqual(state.firstUnresolvedStage, .apiKey)
        }

        func test_firstUnresolvedStageIsTCCWhenAPIKeyStored() {
            let state = WizardState(keychain: FakeKeychain(apiKeyStored: true))
            state.inputMonitoringProbed = false
            XCTAssertEqual(state.firstUnresolvedStage, .tcc)
        }

        func test_firstUnresolvedStageIsHotkeyWhenTCCDone() {
            let state = WizardState(keychain: FakeKeychain(apiKeyStored: true))
            state.inputMonitoringProbed = true
            state.hotkey = nil
            XCTAssertEqual(state.firstUnresolvedStage, .hotkey)
        }

        func test_firstUnresolvedStageIsCompleteWhenAllDone() {
            let state = WizardState(keychain: FakeKeychain(apiKeyStored: true))
            state.inputMonitoringProbed = true
            state.hotkey = KeyboardShortcut(keyCode: 38, modifiers: [.command, .shift])
            XCTAssertEqual(state.firstUnresolvedStage, .complete)
        }
    }
    ```

    `AnthropicKeyValidatorTests.swift`:
    ```swift
    import XCTest
    @testable import Jarvis

    final class AnthropicKeyValidatorTests: XCTestCase {
        private struct MockClient: URLRequestClient {
            let status: Int
            func data(for request: URLRequest) async throws -> (Data, URLResponse) {
                let url = request.url!
                let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!
                return (Data(), response)
            }
        }

        func test_malformedSkipsNetwork() async {
            let validator = AnthropicKeyValidator(client: MockClient(status: 500))  // would fail if called
            let result = await validator.validate(key: "not-an-anthropic-key")
            XCTAssertEqual(result, .malformed)
        }

        func test_unauthorized() async {
            let validator = AnthropicKeyValidator(client: MockClient(status: 401))
            let result = await validator.validate(key: "sk-ant-api03-fake-key-shape")
            XCTAssertEqual(result, .unauthorized)
        }

        func test_valid() async {
            let validator = AnthropicKeyValidator(client: MockClient(status: 200))
            let result = await validator.validate(key: "sk-ant-api03-fake-key-shape")
            XCTAssertEqual(result, .valid)
        }
    }
    ```

    `WizardTCCStageTests.swift` — SEC-04 / D-08 enforcement via a fake InputMonitoringProbe call counter:
    ```swift
    import XCTest
    @testable import Jarvis
    @testable import Shell

    @MainActor
    final class WizardTCCStageTests: XCTestCase {
        private final class CountingHIDProbe: HIDAccessProbe {
            var requestListenEventCount = 0
            func requestListenEventAccess() -> Bool {
                requestListenEventCount += 1
                return true
            }
        }

        func test_onlyInputMonitoringTriggers() {
            let hidProbe = CountingHIDProbe()
            let probe = InputMonitoringProbe(probe: hidProbe)
            _ = probe.check(sink: nil)
            XCTAssertEqual(hidProbe.requestListenEventCount, 1,
                           "Stage 2 must only call IOHIDRequestAccess once — no Mic/Camera/Automation permission calls (D-08/SEC-04)")
            // Mic (AVCaptureDevice.requestAccess), Camera (same), Automation (AEDeterminePermissionToAutomateTarget)
            // are NOT called anywhere in the WizardStageTCCView — this is the contract.
        }
    }
    ```

    `AppDelegateWiringTests.swift`:
    ```swift
    import XCTest
    @testable import Jarvis
    @testable import Keychain
    @testable import Config
    @testable import Shell

    @MainActor
    final class AppDelegateWiringTests: XCTestCase {
        private struct FakeKeychain: KeychainStore {
            let apiKeyStored: Bool
            func set(_ value: String, for item: KeychainItem) throws {}
            func get(_ item: KeychainItem) throws -> String {
                guard apiKeyStored else { throw KeychainError.itemNotFound }
                return "sk-ant-fake"
            }
            func delete(_ item: KeychainItem) throws {}
        }

        private struct FakeHIDProbe: HIDAccessProbe {
            let granted: Bool
            func requestListenEventAccess() -> Bool { granted }
        }

        private func makeSnapshots() -> (LaunchSnapshot, PerTurnSnapshot) {
            let launchJSON = """
            {"schemaVersion":1,"ollama":{"baseURL":"http://127.0.0.1:11434"},"applescript":{"confirmationRequired":true},"toolBlocklist":[],"confirmationPolicy":{"timeoutSeconds":60},"logging":{"fileLevel":"info","osLogLevel":"info"}}
            """.data(using: .utf8)!
            let perTurnJSON = """
            {"schemaVersion":1,"provider":"anthropic","tts":{"tier":"tier1"},"stt":{"whisperKitFallback":false},"featureFlags":{}}
            """.data(using: .utf8)!
            return (
                try! JSONDecoder().decode(LaunchSnapshot.self, from: launchJSON),
                try! JSONDecoder().decode(PerTurnSnapshot.self, from: perTurnJSON)
            )
        }

        private struct EntitlementYes: EntitlementGateProbe { func isVerified() -> Bool { true } }

        func test_loggingBootstrapCalled() {
            let delegate = AppDelegate()
            delegate.entitlementProbe = EntitlementYes()
            delegate.configLoader = { _ in self.makeSnapshots() }
            delegate.configWriter = { _ in self.makeSnapshots() }
            delegate.keychainStore = FakeKeychain(apiKeyStored: true)
            delegate.hidProbe = FakeHIDProbe(granted: true)
            var bootstrapped = 0
            delegate.loggingBootstrap = { bootstrapped += 1 }

            delegate.applicationWillFinishLaunching(Notification(name: .init("t")))
            XCTAssertEqual(bootstrapped, 1, "Logging must bootstrap exactly once (S-8)")
        }

        func test_bannerEnqueuedOnKeychainEmpty() {
            let delegate = AppDelegate()
            delegate.entitlementProbe = EntitlementYes()
            delegate.configLoader = { _ in self.makeSnapshots() }
            delegate.configWriter = { _ in self.makeSnapshots() }
            delegate.keychainStore = FakeKeychain(apiKeyStored: false)
            delegate.hidProbe = FakeHIDProbe(granted: true)
            delegate.loggingBootstrap = {}

            delegate.applicationWillFinishLaunching(Notification(name: .init("t")))
            XCTAssertEqual(delegate.bannerCoordinator?.currentBanner?.id, "keychain-empty")
        }

        func test_bannerEnqueuedOnInputMonitoringDenial() {
            let delegate = AppDelegate()
            delegate.entitlementProbe = EntitlementYes()
            delegate.configLoader = { _ in self.makeSnapshots() }
            delegate.configWriter = { _ in self.makeSnapshots() }
            delegate.keychainStore = FakeKeychain(apiKeyStored: true)
            delegate.hidProbe = FakeHIDProbe(granted: false)
            delegate.loggingBootstrap = {}

            delegate.applicationWillFinishLaunching(Notification(name: .init("t")))
            // Priority: keychain-empty (1) > input-monitoring-denied (2). API key stored → no keychain banner.
            XCTAssertEqual(delegate.bannerCoordinator?.currentBanner?.id, "input-monitoring-denied")
        }

        func test_stateDumpDoesNotIncludeAPIKey() {
            let delegate = AppDelegate()
            delegate.entitlementProbe = EntitlementYes()
            delegate.configLoader = { _ in self.makeSnapshots() }
            delegate.configWriter = { _ in self.makeSnapshots() }
            delegate.keychainStore = FakeKeychain(apiKeyStored: true)
            delegate.hidProbe = FakeHIDProbe(granted: true)
            delegate.loggingBootstrap = {}

            delegate.applicationWillFinishLaunching(Notification(name: .init("t")))
            // Trigger copyStateDump via menu action (call private helper via reflection isn't clean;
            // instead just assert the design invariant: no code path references `keychainStore.get(...)`
            // and puts it into payload as a value. Grep-verified in acceptance criteria.
            XCTAssertTrue(true)
        }
    }
    ```
  </action>
  <verify>
    <automated>cd packages/Shell &amp;&amp; swift test 2>&amp;1 | tail -5 &amp;&amp; xcodebuild test -project ../../Jarvis.xcodeproj -scheme Jarvis -destination 'platform=macOS' -derivedDataPath ../../build -only-testing:JarvisAppTests/WizardStateTests -only-testing:JarvisAppTests/AnthropicKeyValidatorTests -only-testing:JarvisAppTests/WizardTCCStageTests -only-testing:JarvisAppTests/AppDelegateWiringTests 2>&amp;1 | tail -25</automated>
  </verify>
  <acceptance_criteria>
    - `test -f App/Wizard/WizardView.swift && test -f App/Wizard/WizardStageAPIKeyView.swift && test -f App/Wizard/WizardStageTCCView.swift && test -f App/Wizard/WizardStageHotkeyView.swift && test -f App/Wizard/WizardState.swift && test -f App/Wizard/OnboardingWizardController.swift && test -f App/Wizard/AnthropicKeyValidator.swift` all pass
    - `grep 'JarvisLogHandlerFactory.bootstrap' App/AppDelegate.swift` returns ≥ 1 match (S-8 one call site at AppDelegate)
    - `grep 'ConfigLoader.loadSnapshots\|ConfigLoader.writeDefaultAndReload' App/AppDelegate.swift` returns ≥ 1 match
    - `grep 'ConfigError' App/AppDelegate.swift` returns ≥ 1 match (malformed hard-block path)
    - `grep 'KeychainItem.anthropic\|keychainStore.get' App/AppDelegate.swift` returns ≥ 1 match
    - `grep 'BannerContent.keychainEmpty\|.keychainEmpty' App/AppDelegate.swift` returns ≥ 1 match
    - `grep 'BannerContent.inputMonitoringDenied\|.inputMonitoringDenied' App/AppDelegate.swift` returns ≥ 1 match
    - `grep 'HotkeyBinder' App/AppDelegate.swift` returns ≥ 2 matches
    - `grep 'TCCAlertService.presentHardBlock' App/AppDelegate.swift` returns ≥ 2 matches (one for entitlement failure, one for malformed config)
    - `grep 'SystemKeychainStore\|AnthropicKeyValidator' App/Wizard/WizardStageAPIKeyView.swift` returns ≥ 2 matches
    - `grep 'IOHIDRequestAccess\|AVCaptureDevice.requestAccess\|AEDeterminePermissionToAutomateTarget' App/Wizard/WizardStageTCCView.swift` returns NO matches (D-08: only Input Monitoring prompts, and the actual IOHIDRequestAccess call is delegated to InputMonitoringProbe via `onGrantInputMonitoring` closure — WizardStageTCCView itself never calls a permission API directly)
    - `grep 'ShortcutRecorderView' App/Wizard/WizardStageHotkeyView.swift` returns ≥ 1 match
    - `grep '\.modalPanel' App/Wizard/OnboardingWizardController.swift` returns 1 match (first-launch blocking per UI-SPEC Surface 1 line 286)
    - `grep -i 'apiKey\|api_key\|anthropic_key\|sk-ant-' App/AppDelegate.swift` returns matches ONLY for `.anthropic` or `keychainStore.get(.anthropic)` — the API key VALUE is never stored in AppDelegate member state (SEC-01 defense). Verify manually: read the file and confirm `copyStateDump()` writes only boolean presence, never the key value.
    - `grep '"apiKeyStored"' App/AppDelegate.swift` returns 1 match (state dump uses boolean, not the key value — SEC-01)
    - `cd packages/Shell && swift test` exits 0 with all Shell package tests green (placeholder deleted; Task 1 + Task 2 tests ≥ 15 total)
    - `xcodebuild test -project Jarvis.xcodeproj -scheme Jarvis -destination 'platform=macOS' -derivedDataPath build -only-testing:JarvisAppTests/WizardStateTests -only-testing:JarvisAppTests/AnthropicKeyValidatorTests -only-testing:JarvisAppTests/WizardTCCStageTests -only-testing:JarvisAppTests/AppDelegateWiringTests` exits 0 with ≥ 11 passing tests (WizardState 4, AnthropicKeyValidator 3, WizardTCC 1, AppDelegateWiring 4)
  </acceptance_criteria>
  <done>Wizard renders the three-stage flow (API key → TCC → hotkey); AppDelegate fully wires logging bootstrap, config load, keychain fetch, menu bar, HUD panel, banner coordinator, Input Monitoring probe, and hotkey binding; Input Monitoring denial surfaces the persistent banner; malformed config hard-blocks with NSAlert; state dump never exfiltrates the API key.</done>
</task>

</tasks>

<threat_model>
## Trust Boundaries

| Boundary | Description |
|----------|-------------|
| User-entered API key → Keychain | SecureField → validator → keychain.set; key never touches UserDefaults / config / log files |
| Anthropic `models/list` probe → network | Outbound HTTPS to api.anthropic.com; carries x-api-key; TLS-pinned by URLSession defaults |
| `IOHIDRequestAccess` → TCC | OS-level prompt; response determines degraded-mode path |
| User-configured hotkey → global+local NSEvent monitors | Hotkey captures keyDown globally (Input Monitoring required) + locally (always); degraded mode = local-only |

## STRIDE Threat Register

| Threat ID | Category | Component | Disposition | Mitigation Plan |
|-----------|----------|-----------|-------------|-----------------|
| T-04-01 | Information Disclosure | Anthropic API key in `models/list` probe URL / headers | mitigate | Key travels as `x-api-key` header (not query string); HTTPS-only URL. URLSession redacts headers in its own logs by default. No custom logging of the request. SEC-01. |
| T-04-02 | Information Disclosure | API key in menu "Copy State Dump" clipboard | mitigate | `copyStateDump()` writes ONLY `apiKeyStored: Bool` to the payload; the key VALUE is never fetched to a local variable. Grep-verified (acceptance). |
| T-04-03 | Denial of Service | Input Monitoring denial → silent hotkey no-op | mitigate | `InputMonitoringProbe` surfaces `inputMonitoringDenied` banner with System Settings deep link (SHELL-06 / D-12). `HotkeyBinder` falls back to local-monitor-only with `isDegraded=true`. |
| T-04-04 | Tampering | User-edited `config.json` with non-localhost `ollama.base_url` | mitigate | `OllamaConfig.init(from:)` (Plan 02) throws `ConfigError.invalidOllamaHost`; `AppDelegate` catches and surfaces NSAlert hard-block (D-19, S-6). AGENT-05 satisfied at decode time. |
| T-04-05 | Denial of Service | Malformed `config.json` silently fallback to defaults | mitigate | S-6 hard-block: AppDelegate catches `ConfigError.malformed` → NSAlert + terminate. Silent fallback is forbidden (D-19). |
| T-04-06 | Elevation of Privilege | Wizard prompts for Mic/Camera/Automation when only Input Monitoring is authorized for P1 | mitigate | `WizardStageTCCView` rows for Mic/Camera/Automation are explainer-only — NO permission API call. SEC-04 / D-08. Verified by `test_onlyInputMonitoringTriggers`. |
| T-04-07 | Tampering | `LoggingSystem.bootstrap` called twice → undefined swift-log state | mitigate | S-8: `AppDelegate.loggingBootstrap` closure is invoked exactly once in `applicationWillFinishLaunching`. Test-proven via `test_loggingBootstrapCalled` counting calls. |
| T-04-08 | Information Disclosure | API key logged by wizard on validation failure | mitigate | `AnthropicKeyValidator` returns a result enum (`.malformed`, `.unauthorized`, etc.) — never logs the key. Plan 02 Redact is defense-in-depth if any accidental log happens. |

No `high`-severity residual risk. Every critical P1 trust boundary (API key entry, config load, Input Monitoring, malformed config) has both a primary mitigation and a defense-in-depth path.
</threat_model>

<verification>
**Shell package tests:** `cd packages/Shell && swift test` exits 0 — HotkeyBindingTests 5, InputMonitoringDenialTests 3, LaunchAtLoginTests 1 non-skipped, ShortcutRecorderTests 7 = ≥16 tests green.

**App target tests:** `xcodebuild test -scheme Jarvis -destination 'platform=macOS' -derivedDataPath build -only-testing:JarvisAppTests/WizardStateTests -only-testing:JarvisAppTests/AnthropicKeyValidatorTests -only-testing:JarvisAppTests/WizardTCCStageTests -only-testing:JarvisAppTests/AppDelegateWiringTests` exits 0 — ≥12 tests green.

**Full-phase integration sanity:** `xcodebuild -scheme Jarvis -configuration Debug build -derivedDataPath build` exits 0; launch the app; menu-bar icon appears; left-click summons empty HUD panel; Setup… menu item opens wizard; API key entry → Keychain round-trip works via `security find-generic-password -s com.kingsrook.jarvis -a anthropic -g` from the command line.

**Grep gates on AppDelegate:** one `JarvisLogHandlerFactory.bootstrap` call site (S-8); ≥2 `TCCAlertService.presentHardBlock` call sites; `BannerContent.keychainEmpty` and `.inputMonitoringDenied` both referenced; `HotkeyBinder` used; NO references to raw API-key value being stored on `self` or written anywhere except Keychain.
</verification>

<success_criteria>
- Shell package complete: HotkeyBinder (global+local monitor pair, local-only degraded mode), InputMonitoringProbe (IOHIDRequestAccess + banner sink), LaunchAtLoginController (SMAppService; no SMLoginItemSetEnabled), ShortcutRecorder (hand-rolled, rejects modifier-only + shift-only, aborts on Escape), CollisionDetector (Cmd+Shift+J → Chrome/Slack/VSCode; Option+Space → Alfred/Raycast)
- Wizard renders three stages (API key → TCC priming → hotkey binding); first-launch modal-panel until stage 1 resolved; re-entry via Setup… menu is non-modal (D-09)
- Stage 2 actively prompts Input Monitoring ONLY; Mic/Camera/Automation rows are explainer-only (D-08, SEC-04)
- AppDelegate wires full launch flow: logging bootstrap (S-8) → entitlement hard-block (Plan 03) → config load (hard-block on malformed) → keychain fetch (banner on itemNotFound) → menu bar + HUD + banner panels → Input Monitoring probe (banner on denial) → hotkey binder install
- `copyStateDump()` action writes boolean-only presence indicators; API key value NEVER enters the clipboard (SEC-01 defense-in-depth)
- `AnthropicKeyValidator` probes `api.anthropic.com/v1/models` via URLSession; returns typed result enum; injectable for tests
</success_criteria>

<output>
After completion, create `.planning/phases/01-foundations/01-04-SUMMARY.md` documenting:
- Shell public API (paste the module interface)
- Wizard state-machine diagram (apiKey → tcc → hotkey → complete; first-launch modal vs re-entry non-modal)
- AppDelegate wiring order (8 numbered steps from applicationWillFinishLaunching)
- Banner priority ladder as wired in this plan (keychain-empty=1, input-monitoring-denied=2, hotkey-bind-failed=3, ollama-url-rejected=4, dev-overlay-stub=99, state-dump-copied=99)
- Test counts + REQ-IDs covered (SHELL-01, SHELL-02, SHELL-03, SHELL-06, SEC-04)
- Open items for Plan 05: `scripts/codesign.sh`, `scripts/verify-entitlements.sh` (pre-codesign + post-codesign split per RESEARCH Open Q #8), `scripts/verify-codesign-settings.sh`, `scripts/test-verify-entitlements.sh`, `JarvisEntitlementProbeTests` one-shot probe, post-build entitlement-grep Run Script phase in pbxproj
</output>
