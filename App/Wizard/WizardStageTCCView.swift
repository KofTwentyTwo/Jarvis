import SwiftUI
import Shell

/// Stage 2 of the first-launch wizard (UI-SPEC Surface 1, D-08/SEC-04).
///
/// ONLY the Input Monitoring row invokes a real TCC prompt. The Microphone,
/// Camera, and Automation rows are explainer-only — they surface "coming
/// later" copy and never call any permission API. That's the D-08 contract:
/// Phase 1 prompts ONLY what Phase 1 needs. The test
/// `WizardTCCStageTests.test_onlyInputMonitoringTriggers` pins this shape.
///
/// The actual HID probe call happens inside `InputMonitoringProbe`, not here
/// — AppDelegate injects a closure that wraps the probe (and its banner sink)
/// so this view has no dependency on the probe or sink types.
struct WizardStageTCCView: View {
    @ObservedObject var state: WizardState
    let onAdvance: () -> Void
    /// Closure wraps `InputMonitoringProbe.check(sink:)`. Injected by WizardView.
    let onGrantInputMonitoring: () -> Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Grant Permissions").font(.system(size: 17, weight: .semibold))
            // `.fixedSize(horizontal: false, vertical: true)` opts into multi-
            // line wrap instead of tail-truncation when the proposed width is
            // narrower than the single-line natural width. Same idiom is
            // applied below to each row's body text.
            Text("Jarvis needs a few system permissions to do its job. Only one is needed right now; the others will ask when the matching feature is added.")
                .foregroundColor(Color(NSColor.secondaryLabelColor))
                .fixedSize(horizontal: false, vertical: true)

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
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Input Monitoring (needed now)").font(.headline)
                    Text("Lets Jarvis see a global hotkey press even when another app is focused. Without this, Jarvis only responds when its window is frontmost.")
                        .foregroundColor(Color(NSColor.secondaryLabelColor))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Spacer(minLength: 16)
                if state.inputMonitoringGranted {
                    Label("Granted", systemImage: "checkmark.circle.fill")
                        .foregroundColor(Color(NSColor.systemGreen))
                } else if !state.inputMonitoringProbed {
                    Button("Grant Access") {
                        state.inputMonitoringGranted = onGrantInputMonitoring()
                        state.inputMonitoringProbed = true
                    }
                } else {
                    Button("Re-check") {
                        // Re-fire the probe. If the user granted in System
                        // Settings between sessions or in another window,
                        // this picks up the new grant; if still denied, the
                        // helper text below points them at System Settings.
                        state.inputMonitoringGranted = onGrantInputMonitoring()
                    }
                }
            }
            // Only show the System Settings helper after the user has tried
            // the in-app prompt and it didn't grant — covers both "user
            // clicked Deny" and the macOS-quirk case where ad-hoc signed
            // Debug builds don't auto-list in System Settings until the
            // first IOHIDRequestAccess call has been made.
            if state.inputMonitoringProbed && !state.inputMonitoringGranted {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: "info.circle")
                            .foregroundColor(Color(NSColor.secondaryLabelColor))
                        Text("Not granted. Open System Settings → Privacy & Security → Input Monitoring, find ‘Jarvis’ in the list, and turn it on. Then click Re-check above.")
                            .foregroundColor(Color(NSColor.secondaryLabelColor))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    HStack(spacing: 8) {
                        Button("Open System Settings") {
                            if let url = URL(string:
                                "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent") {
                                NSWorkspace.shared.open(url)
                            }
                        }
                        Text("If Jarvis is missing from the list, click + and choose Jarvis.app from your build folder.")
                            .font(.system(size: 11))
                            .foregroundColor(Color(NSColor.tertiaryLabelColor))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .font(.system(size: 12))
                .padding(10)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color(NSColor.windowBackgroundColor))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(Color(NSColor.separatorColor), lineWidth: 1)
                )
            }
        }
    }

    /// Explainer-only rows per D-08. No TCC prompt, no permission-framework
    /// call — the label is a static link; docs page lands post-P1, button
    /// is a no-op in P1. The sibling test pins this.
    private func explainerRow(title: String, body: String, ctaLabel: String) -> some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                Text(body)
                    .foregroundColor(Color(NSColor.secondaryLabelColor))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Spacer(minLength: 16)
            Text(ctaLabel).foregroundColor(Color(NSColor.linkColor))
        }
    }
}
