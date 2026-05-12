// DevOverlayWindow.swift
//
// NSPanel host for the developer-facing diagnostic surface. Renders four
// panes across a TabView: live agent snapshot, last-5 tool calls, token
// budget + latency, and subsystem health. Each pane is read-only — the
// window is a window into runtime state, never a controller.
//
// Wiring (Slice 2 of the dev-overlay-end-to-end fix, 2026-05-12):
//   1. AppDelegate constructs a `DevSnapshotEmitter` in `installAgent`
//      and forwards every `.devOverlay`-priority broadcaster event to it.
//   2. AppDelegate calls `DevOverlayWindow(emitter:, bootHealth:)` so the
//      window's `DevOverlayBridge` can subscribe to the emitter's bounded
//      output channel.
//   3. BootHealth + HudState are read on a 1 Hz timer (polling beats
//      adding yet another subscriber for a low-frequency surface).
//
// Before you edit:
//   - The `viewModel.apply(_:)` write path must remain single-writer (the
//     bridge subscriber). Don't add direct writes elsewhere.
//   - Window construction is lazy on first menu click — moving the
//     emitter dependency to a stored property keeps the panel "cold" until
//     a developer actually opens it.
//
// See also: DevOverlayBridge.swift (channel pump),
//   packages/AgentCore/Sources/AgentOrchestrator/DevSnapshotEmitter.swift,
//   App/MenuBar/StatusPanel.swift (sibling NSPanel pattern).

#if canImport(AppKit) && canImport(SwiftUI)
import AppKit
import SwiftUI
import AgentCore
import AgentOrchestrator

/// Floating, non-modal panel hosting `DevOverlayView`.
///
/// ## Overview
///
/// `.floating` window level keeps the overlay above the main HUD without
/// stealing focus (`.nonactivatingPanel`). The panel is constructed lazily
/// on first menu-click and survives close/reopen cycles
/// (`isReleasedWhenClosed = false`).
///
/// ## Topics
///
/// - ``init(emitter:bootHealthOrchestrator:hudStateReader:)``
/// - ``show()``
/// - ``hide()``
/// - ``toggle()``
///
/// ## Threading
///
/// `@MainActor`-isolated. The bridge subscriber task hops to the main
/// actor on each delivery to keep the SwiftUI write path on its expected
/// executor.
@available(macOS 14.0, *)
@MainActor
public final class DevOverlayWindow {
    private let panel: NSPanel
    public let viewModel: DevOverlayViewModel
    private let bridge: DevOverlayBridge
    private let bootHealthOrchestrator: BootHealthOrchestrator?
    private let hudStateReader: (@MainActor () -> String)?
    private var pollTimer: Task<Void, Never>?

    /// Wired-up initializer. AppDelegate calls this with the live emitter
    /// + boot-health orchestrator + a closure that reads the current
    /// `HudState` off `HudStateCoordinator` (which is App-target-only, so
    /// we accept a closure rather than imposing a dependency on the
    /// coordinator type).
    public init(
        emitter: DevSnapshotEmitter?,
        bootHealthOrchestrator: BootHealthOrchestrator? = nil,
        hudStateReader: (@MainActor () -> String)? = nil,
        viewModel: DevOverlayViewModel = DevOverlayViewModel()
    ) {
        self.viewModel = viewModel
        self.bridge = DevOverlayBridge(viewModel: viewModel)
        self.bootHealthOrchestrator = bootHealthOrchestrator
        self.hudStateReader = hudStateReader

        let contentRect = NSRect(x: 0, y: 0, width: 560, height: 520)
        let styleMask: NSWindow.StyleMask = [
            .titled,
            .closable,
            .resizable,
            .nonactivatingPanel,
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
        p.orderOut(nil)
        self.panel = p

        // Subscribe the bridge to the emitter's bounded output channel.
        // When `emitter` is nil (Slice-2 partial wiring, dev-only tooling
        // construction, or tests), the panel still renders `.initial` and
        // boot-health updates flow normally.
        if let emitter {
            Task { @MainActor [bridge] in
                let output = await emitter.output
                bridge.attach(channel: output)
            }
        }
    }

    /// Show the panel + start the 1 Hz poll for BootHealth and HudState.
    /// Polling only runs while visible, so a hidden DevOverlay imposes
    /// zero runtime cost.
    public func show() {
        panel.makeKeyAndOrderFront(nil)
        startPolling()
    }

    public func hide() {
        panel.orderOut(nil)
        stopPolling()
    }

    public var isVisible: Bool { panel.isVisible }

    public func toggle() {
        if isVisible { hide() } else { show() }
    }

    // MARK: - Polling (BootHealth + HudState)

    /// 1 Hz read loop. BootHealth is queried via `lastSnapshot()` (no
    /// re-probe — that's the Status panel's job; here we just observe).
    /// HudState comes from the App-target reader closure. Both are
    /// cheap: actor read + enum copy.
    private func startPolling() {
        stopPolling()
        let bh = bootHealthOrchestrator
        let hr = hudStateReader
        let vm = viewModel
        pollTimer = Task { @MainActor [weak vm] in
            while !Task.isCancelled {
                if let bh {
                    let snap = await bh.lastSnapshot()
                    vm?.updateBootHealth(snap)
                }
                if let hr {
                    vm?.updateHudState(hr())
                }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }

    private func stopPolling() {
        pollTimer?.cancel()
        pollTimer = nil
    }

    deinit {
        pollTimer?.cancel()
    }
}
#endif
