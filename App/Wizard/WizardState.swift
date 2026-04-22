import SwiftUI
import Keychain
import Shell

public enum WizardStage: String, CaseIterable, Sendable {
    case apiKey, tcc, hotkey, complete
}

/// D-09 stateless re-entry: the wizard re-reads the current resolution state
/// on each open, so re-entering via Setup… doesn't depend on cached in-memory
/// state from a prior launch. `apiKeyStored` is recomputed from Keychain
/// on `refresh()`; `inputMonitoringProbed` and `hotkey` are session-scoped.
@MainActor
public final class WizardState: ObservableObject {
    @Published public var currentStage: WizardStage = .apiKey
    @Published public var apiKeyStored: Bool = false
    @Published public var inputMonitoringProbed: Bool = false
    @Published public var inputMonitoringGranted: Bool = false
    @Published public var hotkey: Shell.KeyboardShortcut?

    private let keychain: any KeychainStore

    public init(keychain: any KeychainStore = SystemKeychainStore()) {
        self.keychain = keychain
        refresh()
    }

    /// Re-read current truth. Sets `currentStage` to the first unresolved
    /// stage so re-entry via Setup… lands the user where they left off.
    public func refresh() {
        apiKeyStored = (try? keychain.get(.anthropic)) != nil
        currentStage = firstUnresolvedStage
    }

    public var firstUnresolvedStage: WizardStage {
        if !apiKeyStored              { return .apiKey }
        if !inputMonitoringProbed     { return .tcc }
        if hotkey == nil              { return .hotkey }
        return .complete
    }
}
