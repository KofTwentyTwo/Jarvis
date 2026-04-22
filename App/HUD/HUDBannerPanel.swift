import AppKit
import SwiftUI

/// A `.floating` non-activating panel positioned top-trailing on the main
/// display, used for degraded-mode banners (Input Monitoring denial, Keychain
/// empty, hotkey-bind failure, Ollama URL rejected). Distinct from
/// `JarvisHUDPanel` per UI-SPEC Surface 5 "Critical decision" lines 452-456 —
/// banners must persist across HUD summon/dismiss and live on their own z-order.
@MainActor
public final class HUDBannerPanel: NSPanel {
    public init() {
        let initialFrame = NSRect(x: 0, y: 0, width: 360, height: 96)
        super.init(
            contentRect: initialFrame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        self.level = .floating
        self.isMovableByWindowBackground = false
        self.isOpaque = false
        self.backgroundColor = .clear
        self.hasShadow = true
        self.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        self.hidesOnDeactivate = false
        self.titleVisibility = .hidden
    }

    /// Banner panel never steals focus (UI-SPEC Surface 5 line 473).
    public override var canBecomeKey: Bool { false }
    public override var canBecomeMain: Bool { false }

    /// Install a SwiftUI view as the panel's content and re-position.
    public func host(_ view: some View) {
        self.contentView = NSHostingView(rootView: view)
        self.positionTopTrailing()
    }

    /// Position banner 24pt from right edge, 8pt below the system menu-bar
    /// height on the main display (UI-SPEC Surface 5 line 460).
    public func positionTopTrailing() {
        guard let screen = NSScreen.main else { return }
        let visibleFrame = screen.visibleFrame
        let bannerWidth: CGFloat = 360
        let bannerHeight: CGFloat = self.contentView?.fittingSize.height ?? 96
        let x = visibleFrame.maxX - bannerWidth - 24
        let y = visibleFrame.maxY - bannerHeight - 8
        self.setFrame(
            NSRect(x: x, y: y, width: bannerWidth, height: bannerHeight),
            display: true
        )
    }
}
