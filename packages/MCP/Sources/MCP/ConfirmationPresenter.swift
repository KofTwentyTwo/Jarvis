// ConfirmationPresenter.swift
//
// Native AppKit presentation surface for the ConfirmationBroker. Plan 05-05
// Task 2 (MCP-04).
//
// Anti-patterns enforced (build-time + runtime + lint):
//   - DO NOT use NSAlert.runModal — parks @MainActor, breaks always-on-top HUD.
//   - DO NOT use beginModalSession / NSApplication.shared.run / NSApp.run.
//   - DO NOT route confirmation through the webview — bus / JS surface
//     could in principle forge approval (T-05-05-04). The presenter is
//     pure native AppKit; the only path to broker.response(.approve) is
//     the Approve button handler in this file (or the barge / timeout
//     paths inside the broker actor).
//
// scripts/check-no-modal-presentation.sh (Plan 05-05 Task 5) regression-
// guards the modal-API ban across App/** and packages/**/Sources/**.
//
// Sanctioned API: NSPanel.beginSheet(_:completionHandler:). beginSheet does
// NOT park MainActor (unlike runModal); the presenter remains responsive
// while the sheet is up.

import AppKit
import SwiftUI
import Foundation

/// Production confirmation presenter. Hosts a SwiftUI panel inside a hidden
/// owner NSPanel via beginSheet — the only sanctioned modal-equivalent path.
@MainActor
public final class ConfirmationPresenter: ConfirmationPresenting {

    /// Weak so the broker can deinit cleanly during process teardown
    /// without a strong cycle through the presenter.
    private weak var broker: ConfirmationBroker?

    /// One panel per pending confirmation id. The id key matches
    /// ConfirmationBroker's pending request id so dismiss(id:) can find
    /// the right panel.
    private var panels: [UUID: NSPanel] = [:]

    /// Hidden owner panel that hosts the beginSheet attachment. Never user-
    /// visible (alpha = 0). Lives at .floating level so the sheet sits at
    /// HUD layer.
    private let owner: NSPanel

    public init(broker: ConfirmationBroker) {
        self.broker = broker
        self.owner = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 1, height: 1),
            styleMask: [.nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        self.owner.isFloatingPanel = true
        self.owner.level = .floating
        self.owner.alphaValue = 0
        self.owner.orderOut(nil)
    }

    // MARK: - ConfirmationPresenting (nonisolated trampolines)

    public nonisolated func show(id: UUID, toolName: String, argsPreview: String) async {
        await MainActor.run { [weak self] in
            self?._show(id: id, toolName: toolName, argsPreview: argsPreview)
        }
    }

    public nonisolated func dismiss(id: UUID) async {
        await MainActor.run { [weak self] in
            self?._dismiss(id: id)
        }
    }

    // MARK: - MainActor implementation

    private func _show(id: UUID, toolName: String, argsPreview: String) {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 240),
            styleMask: [.titled, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.title = "Approve tool call"
        panel.isFloatingPanel = true

        let view = ConfirmationContent(
            toolName: toolName,
            argsPreview: argsPreview,
            onApprove: { [weak self] in
                guard let broker = self?.broker else { return }
                Task { await broker.response(id: id, outcome: .approve) }
            },
            onDeny: { [weak self] in
                guard let broker = self?.broker else { return }
                Task { await broker.response(id: id, outcome: .deny) }
            }
        )
        panel.contentView = NSHostingView(rootView: view)

        panels[id] = panel

        // Owner must be visible briefly so beginSheet finds a window
        // context; alpha=0 keeps it invisible to the user.
        owner.alphaValue = 0
        owner.orderFront(nil)

        // Sanctioned non-blocking modal-equivalent path. completionHandler
        // fires on sheet close; cleanup is in _dismiss.
        owner.beginSheet(panel) { _ in
            // Sheet closed; panel is removed by _dismiss(id:).
        }
    }

    private func _dismiss(id: UUID) {
        guard let panel = panels[id] else { return }
        owner.endSheet(panel, returnCode: .OK)
        panel.close()
        panels[id] = nil
        if panels.isEmpty {
            owner.orderOut(nil)
        }
    }
}

// MARK: - SwiftUI panel content

private struct ConfirmationContent: View {
    let toolName: String
    let argsPreview: String
    let onApprove: () -> Void
    let onDeny: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Tool call: \(toolName)")
                .font(.headline)
            ScrollView {
                Text(argsPreview)
                    .font(.system(.body, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 120)
            HStack {
                Spacer()
                Button("Deny", action: onDeny).keyboardShortcut(.cancelAction)
                Button("Approve", action: onApprove).keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
    }
}
