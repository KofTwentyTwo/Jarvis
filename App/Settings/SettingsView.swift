import SwiftUI
import Keychain
import Shell
import Config

/// Local-first LLM routing (Task 9 / spec §6): three-way picker that maps
/// to `{provider, escalationEnabled}` pairs on `PerTurnSnapshot`.
///
/// | Mode             | provider   | escalationEnabled        |
/// |------------------|------------|--------------------------|
/// | Local-first      | .ollama    | true                     |
/// | Anthropic only   | .anthropic | false (moot, pinned)     |
/// | Ollama only      | .ollama    | false                    |
///
/// `escalationEnabled` is "moot" for `.anthropic` because escalation is
/// an Ollama→Anthropic-only fallback path; we normalize it to `false` so
/// the persisted state is unambiguous.
enum ProviderMode: String, CaseIterable, Identifiable {
    case localFirst
    case anthropicOnly
    case ollamaOnly

    var id: String { rawValue }

    var label: String {
        switch self {
        case .localFirst: return "Local-first (recommended)"
        case .anthropicOnly: return "Anthropic only"
        case .ollamaOnly: return "Ollama only"
        }
    }

    static func from(
        provider: ProviderSelection,
        escalationEnabled: Bool
    ) -> ProviderMode {
        switch (provider, escalationEnabled) {
        case (.ollama, true): return .localFirst
        case (.anthropic, _): return .anthropicOnly
        case (.ollama, false): return .ollamaOnly
        }
    }

    var pair: (provider: ProviderSelection, escalationEnabled: Bool) {
        switch self {
        case .localFirst: return (.ollama, true)
        case .anthropicOnly: return (.anthropic, false)
        case .ollamaOnly: return (.ollama, false)
        }
    }
}

/// Real Settings panel — single window, three rows, every row independently
/// editable. Distinct from the first-run wizard:
///
///   Setup…    → sequential first-run flow (Stage 1 → 2 → 3, terminal Save)
///   Settings… → freeform settings panel (this view)
///
/// The wizard is correct for fresh installs. This view is correct for
/// later changes. Both share the same underlying state (`WizardState`)
/// because the canonical truth lives there:
///   - apiKeyStored        → Keychain
///   - inputMonitoringGranted → IOHIDCheckAccess (query-only)
///   - hotkey              → UserDefaults (`Jarvis.hotkey`)
///
/// Any edit here writes through to those stores so the wizard sees the
/// same values on next open.
struct SettingsView: View {
    @ObservedObject var state: WizardState
    let keychain: any KeychainStore
    let validator: AnthropicKeyValidator
    let onGrantInputMonitoring: () -> Bool
    let onHotkeyChanged: (Shell.KeyboardShortcut?) -> Void
    /// Issue #87 — fires when the user binds, clears, or changes the PTT
    /// hotkey. Defaults to a no-op so existing callers that don't pass
    /// this still compile.
    let onPTTHotkeyChanged: (Shell.KeyboardShortcut?) -> Void

    /// Local-first LLM routing (Task 9 / spec §6): optional because the
    /// SwiftUI preview/test seams may instantiate the view without a live
    /// `ConfigStore`. When nil, the provider-mode section is hidden.
    let configStore: ConfigStore?

    let onClose: () -> Void

    init(
        state: WizardState,
        keychain: any KeychainStore,
        validator: AnthropicKeyValidator,
        onGrantInputMonitoring: @escaping () -> Bool,
        onHotkeyChanged: @escaping (Shell.KeyboardShortcut?) -> Void,
        onPTTHotkeyChanged: @escaping (Shell.KeyboardShortcut?) -> Void = { _ in },
        configStore: ConfigStore? = nil,
        onClose: @escaping () -> Void
    ) {
        self.state = state
        self.keychain = keychain
        self.validator = validator
        self.onGrantInputMonitoring = onGrantInputMonitoring
        self.onHotkeyChanged = onHotkeyChanged
        self.onPTTHotkeyChanged = onPTTHotkeyChanged
        self.configStore = configStore
        self.onClose = onClose
    }

    @State private var apiKeyDraft: String = ""
    @State private var apiKeyStatus: APIKeyStatus = .unchanged
    @State private var apiKeyEditing: Bool = false

    @State private var hotkeyDraft: Shell.KeyboardShortcut?
    @State private var hotkeyError: String?

    /// Issue #87 — PTT hotkey draft, mirrored from `state.pttHotkey` on
    /// `onAppear`. Separate from `hotkeyDraft` so binding one doesn't
    /// clobber the other.
    @State private var pttHotkeyDraft: Shell.KeyboardShortcut?
    @State private var pttHotkeyError: String?

    /// Local-first LLM routing (Task 9 / spec §6): derived from the
    /// `ConfigStore`'s current `PerTurnSnapshot`. Hydrated on `.onAppear`
    /// from `configStore.perTurn()`; mutated through the `Picker`.
    /// `nil` until hydrated so the picker doesn't flash a wrong default.
    @State private var providerMode: ProviderMode = .localFirst
    @State private var providerModeHydrated: Bool = false

    enum APIKeyStatus: Equatable {
        case unchanged
        case validating
        case validButUnsaved
        case saved
        case invalid(String)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Settings").font(.system(size: 20, weight: .semibold))

                apiKeySection
                Divider()
                if configStore != nil {
                    providerModeSection
                    Divider()
                }
                permissionsSection
                Divider()
                hotkeySection
                Divider()
                pttHotkeySection

                Spacer()
                HStack {
                    Spacer()
                    Button("Done") { onClose() }
                        .keyboardShortcut(.defaultAction)
                }
            }
            .padding(24)
        }
        .frame(width: 520, height: 620)
        .onAppear {
            // Refresh truth on each open — same reasoning as the wizard's
            // refresh on open: TCC grants and Keychain entries can change
            // between sessions.
            state.refresh()
            hotkeyDraft = state.hotkey
            pttHotkeyDraft = state.pttHotkey
            // Local-first LLM routing (Task 9): hydrate the picker from
            // the live ConfigStore. The `providerModeHydrated` flag
            // suppresses the spurious .onChange fire that would otherwise
            // immediately write back the (just-read) snapshot.
            if let configStore {
                Task {
                    let snap = await configStore.perTurn()
                    await MainActor.run {
                        providerMode = ProviderMode.from(
                            provider: snap.provider,
                            escalationEnabled: snap.escalationEnabled
                        )
                        providerModeHydrated = true
                    }
                }
            }
        }
    }

    // MARK: - Provider mode (Local-first LLM routing, Task 9 / spec §6)

    private var providerModeSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader(
                "Provider",
                subtitle: "Local-first runs the agent on Ollama and only reaches Anthropic if Ollama can't handle the turn. Anthropic only / Ollama only pin to a single backend."
            )

            Picker("Mode", selection: $providerMode) {
                ForEach(ProviderMode.allCases) { mode in
                    Text(mode.label).tag(mode)
                }
            }
            .pickerStyle(.menu)
            .onChange(of: providerMode) { _, newValue in
                // Suppress the initial fire from hydration; only persist
                // user-driven edits.
                guard providerModeHydrated, let configStore else { return }
                let pair = newValue.pair
                Task {
                    let current = await configStore.perTurn()
                    let next = current.with(
                        provider: pair.provider,
                        escalationEnabled: pair.escalationEnabled
                    )
                    await configStore.updatePerTurn(next)
                }
            }
        }
    }

    // MARK: - API key

    private var apiKeySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("Anthropic API key", subtitle: "Required to reach Claude. Stored in macOS Keychain (never plaintext on disk).")

            HStack(spacing: 8) {
                if apiKeyEditing {
                    SecureField("sk-ant-...", text: $apiKeyDraft)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: .infinity)
                        .onSubmit { saveAPIKey() }
                    Button("Save") { saveAPIKey() }
                        .disabled(apiKeyDraft.isEmpty || apiKeyStatus == .validating)
                    Button("Cancel") {
                        apiKeyEditing = false
                        apiKeyDraft = ""
                        apiKeyStatus = .unchanged
                    }
                } else {
                    Image(systemName: state.apiKeyStored
                        ? "checkmark.circle.fill"
                        : "exclamationmark.circle.fill")
                        .foregroundColor(state.apiKeyStored
                            ? Color(NSColor.systemGreen)
                            : Color(NSColor.systemOrange))
                    Text(state.apiKeyStored ? "Configured" : "Not set")
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button(state.apiKeyStored ? "Change…" : "Set Key…") {
                        apiKeyEditing = true
                        apiKeyDraft = ""
                        apiKeyStatus = .unchanged
                    }
                    if state.apiKeyStored {
                        Button("Remove") { removeAPIKey() }
                            .foregroundColor(Color(NSColor.systemRed))
                    }
                }
            }

            apiKeyStatusBanner
        }
    }

    @ViewBuilder
    private var apiKeyStatusBanner: some View {
        switch apiKeyStatus {
        case .unchanged:
            EmptyView()
        case .validating:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Validating against Anthropic…")
                    .foregroundColor(Color(NSColor.secondaryLabelColor))
            }
            .font(.system(size: 12))
        case .validButUnsaved:
            Label("Key looks valid — saving to Keychain", systemImage: "checkmark.circle")
                .foregroundColor(Color(NSColor.systemGreen))
                .font(.system(size: 12))
        case .saved:
            Label("Saved to Keychain.", systemImage: "lock.shield")
                .foregroundColor(Color(NSColor.systemGreen))
                .font(.system(size: 12))
        case .invalid(let msg):
            Label(msg, systemImage: "xmark.octagon.fill")
                .foregroundColor(Color(NSColor.systemRed))
                .font(.system(size: 12))
        }
    }

    private func saveAPIKey() {
        let trimmed = apiKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            apiKeyStatus = .invalid("Enter a key.")
            return
        }
        apiKeyStatus = .validating
        Task {
            let result = await validator.validate(key: trimmed)
            switch result {
            case .valid:
                apiKeyStatus = .validButUnsaved
                do {
                    try keychain.set(trimmed, for: .anthropic)
                    state.refresh()
                    apiKeyStatus = .saved
                    apiKeyEditing = false
                    apiKeyDraft = ""
                } catch {
                    apiKeyStatus = .invalid("Keychain write failed: \(error.localizedDescription)")
                }
            case .malformed:
                apiKeyStatus = .invalid("Key looks malformed (must start with sk-ant-).")
            case .unauthorized:
                apiKeyStatus = .invalid("Anthropic rejected the key (401). Check it on console.anthropic.com.")
            case .network:
                apiKeyStatus = .invalid("Couldn't reach Anthropic — check your connection.")
            case .generic:
                apiKeyStatus = .invalid("Validation failed for an unknown reason.")
            }
        }
    }

    private func removeAPIKey() {
        do {
            try keychain.delete(.anthropic)
            state.refresh()
            apiKeyStatus = .unchanged
        } catch {
            apiKeyStatus = .invalid("Couldn't remove key: \(error.localizedDescription)")
        }
    }

    // MARK: - Permissions

    private var permissionsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("Input Monitoring", subtitle: "Required for the global hotkey to fire when another app is frontmost.")

            HStack(spacing: 8) {
                Image(systemName: state.inputMonitoringGranted
                    ? "checkmark.circle.fill"
                    : "exclamationmark.circle.fill")
                    .foregroundColor(state.inputMonitoringGranted
                        ? Color(NSColor.systemGreen)
                        : Color(NSColor.systemOrange))
                Text(state.inputMonitoringGranted ? "Granted" : "Not granted")
                    .frame(maxWidth: .infinity, alignment: .leading)
                if state.inputMonitoringGranted {
                    Button("Open System Settings") {
                        openInputMonitoringSettings()
                    }
                } else {
                    Button("Request") {
                        state.inputMonitoringGranted = onGrantInputMonitoring()
                        state.inputMonitoringProbed = true
                    }
                    Button("Re-check") { state.refresh() }
                    Button("Open System Settings") {
                        openInputMonitoringSettings()
                    }
                }
            }

            if !state.inputMonitoringGranted {
                Text("If Jarvis isn't listed in System Settings, click + and pick Jarvis.app from the build folder.")
                    .font(.system(size: 11))
                    .foregroundColor(Color(NSColor.tertiaryLabelColor))
            }
        }
    }

    private func openInputMonitoringSettings() {
        if let url = URL(string:
            "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Hotkey

    private var hotkeySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("Global hotkey", subtitle: "Press to summon Jarvis from any app. Press again (or Esc) to dismiss.")

            HStack(spacing: 8) {
                ShortcutRecorderView(
                    shortcut: $hotkeyDraft,
                    errorMessage: $hotkeyError
                )
                .frame(height: 36)
                .frame(maxWidth: .infinity)
                if hotkeyDraft != nil {
                    Button("Save") {
                        state.hotkey = hotkeyDraft
                        onHotkeyChanged(hotkeyDraft)
                    }
                    .disabled(hotkeyDraft == state.hotkey)
                }
                if state.hotkey != nil {
                    Button("Clear") {
                        state.hotkey = nil
                        hotkeyDraft = nil
                        onHotkeyChanged(nil)
                    }
                    .foregroundColor(Color(NSColor.systemRed))
                }
            }

            if let s = state.hotkey {
                Text("Current: \(s.displayString)")
                    .font(.system(size: 12).monospaced())
                    .foregroundColor(Color(NSColor.secondaryLabelColor))
            } else {
                Text("No hotkey bound — use the menu-bar icon to summon Jarvis.")
                    .font(.system(size: 12))
                    .foregroundColor(Color(NSColor.secondaryLabelColor))
            }

            if let err = hotkeyError {
                Label(err, systemImage: "exclamationmark.triangle")
                    .font(.system(size: 12))
                    .foregroundColor(Color(NSColor.systemOrange))
            }

            if let warn = hotkeyDraft.flatMap(CollisionDetector.check) {
                Label(warn.message, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 12))
                    .foregroundColor(Color(NSColor.systemOrange))
            }
        }
    }

    // MARK: - PTT hotkey (#87 / VOICE-13)

    /// Push-to-talk shortcut. Ships unbound — the user must explicitly
    /// pick one. Independent of the summon-Jarvis hotkey above; bound to
    /// `PushToTalk` via AppDelegate's `rebindPTTFromState`.
    private var pttHotkeySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader(
                "Push-to-talk hotkey",
                subtitle: "Hold to talk; release to submit. Bypasses the wake word. Ships unbound — pick a combo that doesn't collide with your other apps (Cmd+Shift+J, Option+Space are taken on most setups)."
            )

            HStack(spacing: 8) {
                ShortcutRecorderView(
                    shortcut: $pttHotkeyDraft,
                    errorMessage: $pttHotkeyError
                )
                .frame(height: 36)
                .frame(maxWidth: .infinity)
                if pttHotkeyDraft != nil {
                    Button("Save") {
                        state.pttHotkey = pttHotkeyDraft
                        onPTTHotkeyChanged(pttHotkeyDraft)
                    }
                    .disabled(pttHotkeyDraft == state.pttHotkey)
                }
                if state.pttHotkey != nil {
                    Button("Clear") {
                        state.pttHotkey = nil
                        pttHotkeyDraft = nil
                        onPTTHotkeyChanged(nil)
                    }
                    .foregroundColor(Color(NSColor.systemRed))
                }
            }

            if let s = state.pttHotkey {
                Text("Current: \(s.displayString)")
                    .font(.system(size: 12).monospaced())
                    .foregroundColor(Color(NSColor.secondaryLabelColor))
            } else {
                Text("No PTT hotkey bound — voice activates via wake word only.")
                    .font(.system(size: 12))
                    .foregroundColor(Color(NSColor.secondaryLabelColor))
            }

            if let err = pttHotkeyError {
                Label(err, systemImage: "exclamationmark.triangle")
                    .font(.system(size: 12))
                    .foregroundColor(Color(NSColor.systemOrange))
            }

            if let warn = pttHotkeyDraft.flatMap(CollisionDetector.check) {
                Label(warn.message, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 12))
                    .foregroundColor(Color(NSColor.systemOrange))
            }
        }
    }

    // MARK: - Helpers

    private func sectionHeader(_ title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.headline)
            Text(subtitle)
                .font(.system(size: 12))
                .foregroundColor(Color(NSColor.secondaryLabelColor))
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
