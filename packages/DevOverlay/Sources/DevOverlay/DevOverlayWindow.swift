#if canImport(AppKit) && canImport(SwiftUI)
import AppKit
import SwiftUI
import AgentOrchestrator

/// NSPanel wrapper hosting `DevOverlayView`.
///
/// - `.floating` window level so the overlay stays above the main HUD.
/// - `.nonactivatingPanel` style so clicking the overlay never steals focus
///   from the app the developer is inspecting.
/// - Transparent background + `.regularMaterial` comes from the SwiftUI view.
/// - Hidden by default; `show()` / `hide()` / `toggle()` drive visibility.
///
/// **Menu-bar wiring is not part of this plan** — Plan 01-04 (or the App-shell
/// plan in Phase 8 hardening) binds the toggle to a menu-bar item + global
/// hotkey. This class exposes the toggle primitive only.
@available(macOS 14.0, *)
@MainActor
public final class DevOverlayWindow {
    private let panel: NSPanel
    public let viewModel: DevOverlayViewModel

    public init(viewModel: DevOverlayViewModel = DevOverlayViewModel()) {
        self.viewModel = viewModel
        let contentRect = NSRect(x: 0, y: 0, width: 460, height: 360)
        let styleMask: NSWindow.StyleMask = [
            .titled,
            .utilityWindow,
            .nonactivatingPanel,
            .closable,
        ]
        let p = NSPanel(
            contentRect: contentRect,
            styleMask: styleMask,
            backing: .buffered,
            defer: true
        )
        p.level = .floating
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.hidesOnDeactivate = false
        p.title = "Jarvis DevOverlay"
        p.isReleasedWhenClosed = false
        p.contentView = NSHostingView(rootView: DevOverlayView(viewModel: viewModel))
        p.orderOut(nil)  // hidden by default
        self.panel = p
    }

    public func show() {
        panel.makeKeyAndOrderFront(nil)
    }

    public func hide() {
        panel.orderOut(nil)
    }

    public var isVisible: Bool { panel.isVisible }

    public func toggle() {
        if isVisible { hide() } else { show() }
    }
}
#endif
