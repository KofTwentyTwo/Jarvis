import AppKit
import WebKit

/// Borderless, transparent, always-on-top panel that hosts an empty `WKWebView`.
/// Plan 3 (the HUD phase) loads the R3F bundle into this webview; P1 leaves it
/// blank.
///
/// Implementation follows UI-SPEC Surface 7 lines 540-590. Key decisions:
/// - `.statusBar` level (above normal windows, below system alerts).
/// - `.nonactivatingPanel` style so summoning doesn't steal focus — matches
///   the "ambient presence" posture.
/// - `drawsBackground=false` on the webview is a macOS 26 Tahoe-specific
///   private-key force per UI-SPEC line 562; without it WKWebView paints
///   opaque white even with `isOpaque=false`.
/// - `cancelOperation(_:)` override makes Escape dismiss the panel when it is
///   key window (UI-SPEC line 576).
/// - Reduce Transparency fallback to `windowBackgroundColor` at 95% opacity
///   (UI-SPEC line 590).
@MainActor
public final class JarvisHUDPanel: NSPanel {
    /// Public so `AppDelegate` can hand this to `WebviewBridge(webView:)` without
    /// inverting the dependency graph (App → Bus, not Bus → App). Per RESEARCH
    /// open question #4 + Plan 02-03 `must_haves`.
    public var webView: WKWebView!
    private let hudSize = NSSize(width: 720, height: 720)

    public init() {
        super.init(
            contentRect: NSRect(origin: .zero, size: hudSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        self.level = .statusBar
        self.isMovableByWindowBackground = true
        self.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        self.hasShadow = false
        self.backgroundColor = .clear
        self.isOpaque = false
        self.titleVisibility = .hidden
        self.hidesOnDeactivate = false

        let config = WKWebViewConfiguration()
        self.webView = WKWebView(frame: .zero, configuration: config)
        self.webView.translatesAutoresizingMaskIntoConstraints = false
        self.webView.underPageBackgroundColor = .clear
        // UI-SPEC Surface 7 line 562: private-key force for transparent backing
        // on macOS 26 Tahoe. `WKWebView.isOpaque` is get-only in Swift, so we
        // rely on KVO-setting `drawsBackground` and the `underPageBackgroundColor`
        // clear to achieve the transparent backing the spec calls for.
        //
        // WR-10: wrap the KVC call in a `responds(to:)` probe so a future
        // WebKit rename of `setDrawsBackground:` degrades to an opaque
        // background rather than an `NSUndefinedKeyException` launch crash.
        // The cost is one extra `objc_msgSend` per app launch.
        let drawsBackgroundSelector = NSSelectorFromString("setDrawsBackground:")
        if self.webView.responds(to: drawsBackgroundSelector) {
            self.webView.setValue(false, forKey: "drawsBackground")
        }
        // Belt-and-braces: zero out layer-level backgrounds so a future macOS
        // ignoring the `_drawsBackground` private SPI still gets transparency.
        self.webView.wantsLayer = true
        self.webView.layer?.backgroundColor = NSColor.clear.cgColor
        // Enable Web Inspector so right-click → Inspect Element works in Debug
        // builds. Available macOS 13.3+; the deployment target is 13.0, so the
        // availability guard is required.
        if #available(macOS 13.3, *) {
            self.webView.isInspectable = true
        }

        let container = NSView()
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.clear.cgColor
        container.addSubview(self.webView)
        NSLayoutConstraint.activate([
            self.webView.topAnchor.constraint(equalTo: container.topAnchor),
            self.webView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            self.webView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            self.webView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
        ])
        self.contentView = container
        self.setAccessibilityLabel("Jarvis HUD")
        self.setAccessibilityRole(.window)
        applyReduceTransparencyIfNeeded()
    }

    /// The HUD can take key status so Escape / ⌘W dispatch into `cancelOperation`.
    public override var canBecomeKey: Bool { true }
    public override var canBecomeMain: Bool { false }

    /// "Summoned" = visible AND in front of every other app (key window).
    /// Just `isVisible` isn't enough — an NSPanel can be visible but
    /// occluded behind another app, in which case the hotkey should
    /// bring it forward, not dismiss it.
    public var isSummoned: Bool { self.isVisible && self.isKeyWindow }

    /// Summon on the screen holding the mouse cursor (fallback: main).
    /// Fresh-center each summon per UI-SPEC line 548 "Not saved per-display in P1".
    public func summon(on screen: NSScreen? = nil) {
        let targetScreen = screen ?? NSScreen.screenWithMouse() ?? NSScreen.main
        if let frame = targetScreen?.visibleFrame {
            let x = frame.midX - hudSize.width / 2
            let y = frame.midY - hudSize.height / 2
            self.setFrame(
                NSRect(x: x, y: y, width: hudSize.width, height: hudSize.height),
                display: true
            )
        }
        // Activate the app first, then make the panel key+front. Without
        // NSApp.activate, a global hotkey pressed while another app is
        // frontmost only orderFront's the panel into a process that isn't
        // active, so it sits behind the active app's windows.
        NSApp.activate(ignoringOtherApps: true)
        self.makeKeyAndOrderFront(nil)
        NSAccessibility.post(
            element: self as Any,
            notification: .announcementRequested,
            userInfo: [.announcement: "Jarvis opened"]
        )
    }

    public func dismiss() {
        self.orderOut(nil)
        NSAccessibility.post(
            element: self as Any,
            notification: .announcementRequested,
            userInfo: [.announcement: "Jarvis dismissed"]
        )
    }

    /// Escape key dismisses when the panel is key (UI-SPEC Surface 7 line 576).
    public override func cancelOperation(_ sender: Any?) {
        dismiss()
    }

    /// ⌘W dismisses (UI-SPEC Surface 7 line 578) — standard macOS expectation
    /// for a document-style window.
    public override func performClose(_ sender: Any?) {
        dismiss()
    }

    // MARK: - Accessibility fallbacks

    private func applyReduceTransparencyIfNeeded() {
        guard NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency else { return }
        self.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.95)
        self.isOpaque = false
    }
}

/// Helper: pick the `NSScreen` currently under the mouse cursor. Used by
/// `summon(on:)` to respect the "summon on the screen where I am" affordance.
extension NSScreen {
    static func screenWithMouse() -> NSScreen? {
        let mouseLocation = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(mouseLocation, $0.frame, false) }
    }
}
