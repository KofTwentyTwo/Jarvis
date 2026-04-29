import Foundation
import AppKit

/// Menu-bar toggle that pauses/resumes presence detection.
///
/// D-12 verbatim clone of packages/Voice/Sources/Voice/Control/MuteWakeWord.swift.
/// Persistence key: features.vision.presenceDisabled.
///
/// IMPORTANT (D-12): this class manipulates ONLY the PresenceMonitor.
/// Camera capture lifecycle is intentionally untouched — disabling presence
/// does NOT disable frame-attach (VISION-04 single-frame capture continues
/// to work via the camera capture actor). Static grep in
/// DisablePresenceTests asserts the absence of any camera-capture-actor
/// reference in this file.
@MainActor
public final class DisablePresence {

    private static let defaultsKey = "features.vision.presenceDisabled"

    private let presenceMonitor: PresenceMonitor
    private let defaults: UserDefaults
    private weak var menuItem: NSMenuItem?
    private(set) public var isDisabled: Bool

    public init(
        presenceMonitor: PresenceMonitor,
        menuBarMenu: NSMenu,
        defaults: UserDefaults = .standard
    ) {
        self.presenceMonitor = presenceMonitor
        self.defaults = defaults
        self.isDisabled = defaults.bool(forKey: Self.defaultsKey)

        let item = NSMenuItem(
            title: "Disable presence",
            action: #selector(handleToggle),
            keyEquivalent: ""
        )
        item.target = self
        item.state = isDisabled ? .on : .off
        menuBarMenu.addItem(item)
        self.menuItem = item

        // Apply persisted state on startup.
        if isDisabled {
            Task { [presenceMonitor] in
                await presenceMonitor.pause()
            }
        }
    }

    /// Test seam — synchronously drive the toggle without depending on the
    /// runtime selector machinery.
    public func toggleForTest() {
        handleToggle()
    }

    @objc private func handleToggle() {
        isDisabled.toggle()
        defaults.set(isDisabled, forKey: Self.defaultsKey)
        menuItem?.state = isDisabled ? .on : .off
        let monitor = presenceMonitor
        let nowDisabled = isDisabled
        Task {
            if nowDisabled {
                await monitor.pause()
            } else {
                await monitor.resume()
            }
        }
    }
}
