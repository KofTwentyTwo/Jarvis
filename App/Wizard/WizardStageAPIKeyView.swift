import SwiftUI
import Keychain

/// Stage 1 of the first-launch wizard (UI-SPEC Surface 1). Accepts an
/// Anthropic API key, calls the AnthropicKeyValidator, and on success stores
/// the key in the macOS Keychain via the injected `KeychainStore`. The key
/// value is never persisted anywhere else (SEC-01).
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
