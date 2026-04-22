import AppKit
import QuartzCore

/// Owns the `NSStatusItem` and drives Core Animation on its button layer for the
/// five `HudState` transitions. Follows RESEARCH.md §Question 7 lines 753-869.
///
/// Critical gotchas cited from RESEARCH.md:
/// - Set `button.image` and animate `transform`/`opacity` via `CABasicAnimation`;
///   NEVER swap `layer.contents` (Q7 rule).
/// - After changing `layer.anchorPoint`, re-anchor the frame to the button's
///   bounds — otherwise rotation around the center jumps to bottom-left
///   (Q7 gotcha #2, Apple DevForums thread 88341).
/// - `isTemplate = true` set in code is defense-in-depth against asset-catalog
///   misconfiguration (D-13).
@MainActor
public final class MenuBarIconController {
    public let statusItem: NSStatusItem
    private let contextMenu: NSMenu
    private var currentState: HudState = .idle
    private var onLeftClick: (() -> Void)?
    private var lastAccessibilityAnnouncement: Date = .distantPast

    public init(statusItem: NSStatusItem, contextMenu: NSMenu) {
        self.statusItem = statusItem
        self.contextMenu = contextMenu
        configureButton()
    }

    /// Wired by `AppDelegate` — opens/dismisses the HUD panel.
    public func setLeftClickAction(_ action: @escaping () -> Void) {
        self.onLeftClick = action
    }

    /// Current state, exposed read-only for tests.
    public var state: HudState { currentState }

    /// Transition to a new HUD state. Same-state transitions are no-ops.
    public func transition(to newState: HudState) {
        guard newState != currentState else { return }
        guard let button = statusItem.button, let layer = button.layer else { return }

        layer.add(CAAnimationFactory.makeStateCrossfade(), forKey: "crossfade")
        layer.removeAnimation(forKey: "state.breath")
        layer.removeAnimation(forKey: "state.rotate")
        layer.removeAnimation(forKey: "state.shimmer")
        layer.removeAnimation(forKey: "state.glow")

        switch newState {
        case .idle:
            break
        case .listening:
            if let a = CAAnimationFactory.makeBreath() { layer.add(a, forKey: "state.breath") }
        case .thinking:
            if let a = CAAnimationFactory.makeRotate() { layer.add(a, forKey: "state.rotate") }
        case .speaking:
            if let a = CAAnimationFactory.makeShimmer() { layer.add(a, forKey: "state.shimmer") }
        case .awaitingConfirmation:
            if let a = CAAnimationFactory.makeGlow() { layer.add(a, forKey: "state.glow") }
        }

        currentState = newState
        button.setAccessibilityLabel(newState.voiceOverLabel)
        announceRateLimited(newState.voiceOverLabel)
    }

    // MARK: - Private

    private func configureButton() {
        guard let button = statusItem.button else { return }
        button.image = NSImage(named: "Icon-MenuBar-Template")
        button.image?.isTemplate = true

        button.wantsLayer = true
        if let layer = button.layer {
            layer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
            // Re-anchor after changing anchorPoint (Q7 gotcha #2 — rotation around
            // the center jumps to bottom-left without this).
            layer.frame = button.bounds
        }

        button.setAccessibilityLabel(currentState.voiceOverLabel)
        button.setAccessibilityHelp("Click to summon or dismiss Jarvis. Right-click for more options.")
        button.setAccessibilityRole(.button)

        // `sendAction:to:` lets us inspect NSApp.currentEvent for left vs right click.
        button.target = self
        button.action = #selector(handleClick(_:))
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
    }

    @objc private func handleClick(_ sender: NSStatusBarButton) {
        guard let event = NSApp.currentEvent else { return }
        let isRightClick = event.type == .rightMouseUp
            || event.modifierFlags.contains(.control)
        if isRightClick {
            // Temporarily assign menu so the standard status-item popup renders,
            // then clear it so left-click doesn't open the menu next time.
            statusItem.menu = contextMenu
            sender.performClick(nil)
            statusItem.menu = nil
        } else {
            onLeftClick?()
        }
    }

    private func announceRateLimited(_ label: String) {
        // UI-SPEC line 421: VoiceOver announcements limited to once per 3s to
        // avoid thinking→speaking→thinking churn spamming the user.
        let now = Date()
        guard now.timeIntervalSince(lastAccessibilityAnnouncement) >= 3.0 else { return }
        lastAccessibilityAnnouncement = now
        NSAccessibility.post(
            element: NSApp as Any,
            notification: .announcementRequested,
            userInfo: [.announcement: label]
        )
    }
}
