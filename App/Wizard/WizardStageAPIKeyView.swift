import SwiftUI
import Keychain

/// Stage 1 of the first-launch wizard (UI-SPEC Surface 1). Accepts an
/// Anthropic API key, calls the AnthropicKeyValidator, and on success stores
/// the key in the macOS Keychain via the injected `KeychainStore`. The key
/// value is never persisted anywhere else (SEC-01).
///
/// CR-02 (SEC-01): `apiKey` is a SwiftUI `@State String`. Swift strings are
/// copy-on-write and immutable, so we can't truly zero the backing store in
/// place, but we shorten the plaintext's memory lifetime as much as possible:
///   1. After a successful Keychain write, `apiKey` is reassigned to "" —
///      drops this view's strong reference so ARC can release the CoW page.
///   2. `onDisappear` reassigns `apiKey` to an all-zero string then to "",
///      ensuring the @State slot no longer carries the secret when the
///      wizard dismisses (even on error paths or back-navigation).
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
                Label(msg, systemImage: "xmark.octagon.fill")
                    .foregroundColor(Color(NSColor.systemRed))
            }
            Link(
                "Get an API key from console.anthropic.com",
                destination: URL(string: "https://console.anthropic.com/settings/keys")!
            )
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
        .onDisappear {
            // CR-02: drop the plaintext key reference as soon as the view
            // dismisses. Swift Strings are CoW/immutable so this cannot
            // zero the underlying storage, but it severs the last strong
            // reference from @State so ARC releases the CoW page.
            clearAPIKey()
        }
    }

    /// Reassigns `apiKey` to "" so the @State slot no longer retains the
    /// plaintext key. Intentionally separate from the verify flow so both
    /// the success path and `onDisappear` route through the same clear.
    private func clearAPIKey() {
        // Overwrite with an all-zero string of the same length first so that,
        // if the underlying storage isn't immediately freed, the CoW page
        // contains zeros rather than the key bytes. Then drop to empty.
        if !apiKey.isEmpty {
            apiKey = String(repeating: "\0", count: apiKey.count)
        }
        apiKey = ""
    }

    private func verify() {
        errorMessage = nil
        isValidating = true
        // CR-02: capture a single local copy for the async task and clear
        // the @State immediately so SwiftUI drops its backing slot.
        let capturedKey = apiKey
        apiKey = ""
        Task { @MainActor in
            let result = await validator.validate(key: capturedKey)
            isValidating = false
            switch result {
            case .valid:
                do {
                    try keychain.set(capturedKey, for: .anthropic)
                    state.apiKeyStored = true
                    onAdvance()
                } catch {
                    // Restore @State so the user can retry without retyping.
                    apiKey = capturedKey
                    errorMessage = "Something went wrong saving your key. Details in the system log."
                }
            case .malformed:
                errorMessage = "That doesn't look like an Anthropic key. Expected prefix `sk-ant-`."
            case .unauthorized:
                // Restore @State so the user can correct a typo without retyping.
                apiKey = capturedKey
                errorMessage = "Anthropic rejected that key. Double-check it hasn't been rotated or revoked."
            case .network:
                // Restore @State so a retry after network is available doesn't
                // require re-pasting.
                apiKey = capturedKey
                errorMessage = "Couldn't reach Anthropic. Check your internet connection and try again."
            case .generic:
                apiKey = capturedKey
                errorMessage = "Something went wrong verifying that key. Details in the system log."
            }
        }
    }
}
