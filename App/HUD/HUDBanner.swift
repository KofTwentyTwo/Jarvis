import SwiftUI
import AppKit

/// SwiftUI body for a single HUD banner. Layout per UI-SPEC Surface 5
/// "Internal layout (horizontal)" lines 467-469. The leading 4pt accent stripe
/// uses `BrandColor.arcReactorGlow` which already handles Increase Contrast
/// fallback and light/dark variants.
struct HUDBanner: View {
    let content: BannerContent
    let onAction: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            Rectangle()
                .fill(Color(nsColor: BrandColor.arcReactorGlow))
                .frame(width: 4)
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(content.title)
                            .font(.headline)
                            .foregroundColor(Color(NSColor.labelColor))
                        Text(content.body)
                            .font(.body)
                            .foregroundColor(Color(NSColor.secondaryLabelColor))
                    }
                    Spacer(minLength: 8)
                    Button(action: onDismiss) {
                        Image(systemName: "xmark")
                            .font(.system(size: 11, weight: .semibold))
                            .frame(width: 24, height: 24)
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(Color(NSColor.secondaryLabelColor))
                    .accessibilityLabel("Dismiss notification")
                }
                if let action = content.action {
                    Button(action.label, action: onAction)
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                }
            }
            .padding(.leading, 16)
            .padding(.trailing, 16)
            .padding(.vertical, 12)
        }
        .background(
            VisualEffectBackground(material: .hudWindow, blendingMode: .behindWindow)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Color(NSColor.separatorColor), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

/// Bridge `NSVisualEffectView` into SwiftUI for the `.hudWindow` material behind
/// banner content.
struct VisualEffectBackground: NSViewRepresentable {
    let material: NSVisualEffectView.Material
    let blendingMode: NSVisualEffectView.BlendingMode

    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = material
        v.blendingMode = blendingMode
        v.state = .active
        return v
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
    }
}
