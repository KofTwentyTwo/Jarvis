import SwiftUI
import Keychain
import Shell

public enum WizardStage: String, CaseIterable, Sendable {
    case apiKey, tcc, hotkey, complete
}

/// D-09 stateless re-entry: the wizard re-reads the current resolution state
/// on each open from the actual system sources of truth, so re-entering via
/// Setup… or relaunching after a System-Settings grant doesn't depend on
/// stale in-memory state.
///
/// Sources of truth on `refresh()`:
///   - `apiKeyStored`              ← Keychain (`KeychainItem.anthropic`)
///   - `inputMonitoringGranted`    ← `IOHIDCheckAccess` (query-only, no prompt)
///   - `hotkey`                    ← UserDefaults (`hotkey.json`)
///
/// `inputMonitoringProbed` is a UI-only flag that toggles to true once the
/// user has clicked "Grant Access" within this session, so the wizard can
/// distinguish "haven't asked yet" from "asked, denied, here's the link to
/// System Settings". On a fresh session it starts false but is upgraded to
/// true immediately if `inputMonitoringGranted` is already true (no point
/// asking again — the user has already granted in a prior session).
@MainActor
public final class WizardState: ObservableObject {
    @Published public var currentStage: WizardStage = .apiKey
    @Published public var apiKeyStored: Bool = false
    @Published public var inputMonitoringProbed: Bool = false
    @Published public var inputMonitoringGranted: Bool = false
    @Published public var hotkey: Shell.KeyboardShortcut? {
        didSet { persistHotkey(hotkey) }
    }

    private let keychain: any KeychainStore
    private let hidProbe: any HIDAccessProbe
    private let userDefaults: UserDefaults

    /// UserDefaults key for the persisted hotkey. JSON-encoded blob under
    /// the standard registered domain so it survives quit/reopen.
    private static let hotkeyDefaultsKey = "Jarvis.hotkey"

    public init(
        keychain: any KeychainStore = SystemKeychainStore(),
        hidProbe: any HIDAccessProbe = SystemHIDAccessProbe(),
        userDefaults: UserDefaults = .standard
    ) {
        self.keychain = keychain
        self.hidProbe = hidProbe
        self.userDefaults = userDefaults
        refresh()
    }

    /// Re-read current truth. Sets `currentStage` to the first unresolved
    /// stage so re-entry via Setup… or a quit/reopen lands the user where
    /// they left off — including landing past TCC if they granted in
    /// System Settings between sessions, or past Hotkey if they bound one
    /// in a prior session.
    public func refresh() {
        apiKeyStored = (try? keychain.get(.anthropic)) != nil

        // Query-only TCC check — never prompts. If the user previously
        // granted (in this session or a prior one, including via System
        // Settings), this returns true and we can skip the TCC stage.
        inputMonitoringGranted = hidProbe.isListenEventAccessGranted()
        // If already granted, treat as "probed" so the wizard skips straight
        // to the next unresolved stage instead of asking again.
        if inputMonitoringGranted {
            inputMonitoringProbed = true
        }

        hotkey = loadPersistedHotkey()

        currentStage = firstUnresolvedStage
    }

    public var firstUnresolvedStage: WizardStage {
        if !apiKeyStored              { return .apiKey }
        if !inputMonitoringGranted    { return .tcc }
        if hotkey == nil              { return .hotkey }
        return .complete
    }

    // MARK: - Hotkey persistence

    private func loadPersistedHotkey() -> Shell.KeyboardShortcut? {
        guard let data = userDefaults.data(forKey: Self.hotkeyDefaultsKey) else {
            return nil
        }
        return try? JSONDecoder().decode(Shell.KeyboardShortcut.self, from: data)
    }

    private func persistHotkey(_ shortcut: Shell.KeyboardShortcut?) {
        guard let shortcut else {
            userDefaults.removeObject(forKey: Self.hotkeyDefaultsKey)
            return
        }
        if let data = try? JSONEncoder().encode(shortcut) {
            userDefaults.set(data, forKey: Self.hotkeyDefaultsKey)
        }
    }
}
