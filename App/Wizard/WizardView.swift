import SwiftUI
import Keychain
import Shell

/// Three-stage root view per UI-SPEC Surface 1 (api key → tcc → hotkey).
/// Header shows stage dots; footer offers Back (disabled on Stage 1). The
/// actual modal/non-modal distinction lives at the hosting
/// `OnboardingWizardController`, not here.
public struct WizardView: View {
    @ObservedObject var state: WizardState
    let keychain: any KeychainStore
    let validator: AnthropicKeyValidator
    let onGrantInputMonitoring: () -> Bool
    let onComplete: () -> Void

    public init(
        state: WizardState,
        keychain: any KeychainStore,
        validator: AnthropicKeyValidator,
        onGrantInputMonitoring: @escaping () -> Bool,
        onComplete: @escaping () -> Void
    ) {
        self.state = state
        self.keychain = keychain
        self.validator = validator
        self.onGrantInputMonitoring = onGrantInputMonitoring
        self.onComplete = onComplete
    }

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
                state: state,
                validator: validator,
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
                    case .tcc:    state.currentStage = .apiKey
                    case .hotkey: state.currentStage = .tcc
                    default:      break
                    }
                }
            }
            Spacer()
        }
        .padding(.horizontal, 48)
        .frame(height: 56)
    }
}
