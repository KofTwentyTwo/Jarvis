import AppKit
import Foundation

// MARK: - MuteWakeWord
//
// @MainActor menu-bar toggle wrapper that pauses/resumes the WakeWordDAG.
//
// VOICE-12 contract:
//   - Toggling the menu-bar item pauses WakeWordDAG.pause().
//   - PTT remains armed — VoiceController.pttDown() / pttUp() are NOT affected.
//   - UserDefaults `features.voice.wakeWordMuted` persists across launches.
//   - On init, reads UserDefaults and applies muted state immediately.
//
// Thread safety:
//   @MainActor — all NSMenu/NSMenuItem operations run on the main thread.

@MainActor
public final class MuteWakeWord {

    // MARK: - Constants

    private static let defaultsKey = "features.voice.wakeWordMuted"

    // MARK: - State

    private let controller: VoiceController
    private let wakeWordDAG: WakeWordDAG
    private var menuItem: NSMenuItem?
    private var isMuted: Bool = false

    // MARK: - Init

    /// Create the mute-wake-word toggle.
    ///
    /// - Parameters:
    ///   - controller: The VoiceController (receives muteWakeWord/unmuteWakeWord calls).
    ///   - wakeWordDAG: The WakeWordDAG (receives pause/resume calls).
    ///   - menuBarMenu: The NSMenu to add the toggle item to.
    public init(controller: VoiceController,
                wakeWordDAG: WakeWordDAG,
                menuBarMenu: NSMenu) {
        self.controller = controller
        self.wakeWordDAG = wakeWordDAG

        // Read persisted muted state
        isMuted = UserDefaults.standard.bool(forKey: Self.defaultsKey)

        // Add the toggle item to the menu
        let item = NSMenuItem(
            title: muteItemTitle,
            action: #selector(handleToggle),
            keyEquivalent: ""
        )
        item.target = self
        item.state = isMuted ? .on : .off
        menuBarMenu.addItem(item)
        self.menuItem = item

        // Apply persisted muted state on startup
        if isMuted {
            Task { [weak self] in
                guard let self else { return }
                await self.wakeWordDAG.pause()
                await self.controller.muteWakeWord()
            }
        }
    }

    // MARK: - Private

    private var muteItemTitle: String {
        "Mute Wake Word"
    }

    @objc private func handleToggle() {
        if isMuted {
            unmute()
        } else {
            mute()
        }
    }

    private func mute() {
        isMuted = true
        UserDefaults.standard.set(true, forKey: Self.defaultsKey)
        menuItem?.state = .on
        Task { [weak self] in
            guard let self else { return }
            await self.wakeWordDAG.pause()
            await self.controller.muteWakeWord()
        }
    }

    private func unmute() {
        isMuted = false
        UserDefaults.standard.set(false, forKey: Self.defaultsKey)
        menuItem?.state = .off
        Task { [weak self] in
            guard let self else { return }
            await self.wakeWordDAG.resume()
            await self.controller.unmuteWakeWord()
        }
    }

    // MARK: - Testing seams

    /// Current muted state (for tests).
    public var isMutedForTests: Bool { isMuted }

    /// Programmatically toggle mute state (for tests that can't click menus).
    public func toggleForTests() {
        handleToggle()
    }

    /// Set muted state directly, bypassing menu (for testing M3 persistence).
    public func setMutedForTests(_ muted: Bool) {
        if muted { mute() } else { unmute() }
    }
}
