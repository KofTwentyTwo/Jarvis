import AppKit
import SwiftUI
import AgentCore

// Round 3 — Status menu dialog per the 2026-05-11 handoff.
//
// `NSPanel` + SwiftUI body that renders the current `BootHealthSnapshot`,
// re-probes on every open ("NOT FAKED 0 100% real only" — never show a
// stale cached snapshot), and exposes "Re-probe all" + "Copy report"
// buttons. AppKit, not WKWebView: this is an operator/dev tool, not a
// user-facing surface, and shouldn't ride the R3F render pipeline.
//
// Non-modal — uses `makeKeyAndOrderFront(_:)`, not `.runModal()`. Project
// rule `scripts/check-no-modal-presentation.sh` is the gate that keeps it
// that way.

// MARK: - StatusPanelModel

/// View-model wrapping the `BootHealthOrchestrator`. Exposes a published
/// `snapshot` for SwiftUI, an `isProbing` flag for the spinner, and a
/// `reprobe()` async method that AppDelegate's `runBootHealth()` drives
/// (so the snapshot read in the panel matches the snapshot logged to
/// the system log — single source of truth).
@MainActor
public final class StatusPanelModel: ObservableObject {
    @Published public var snapshot: BootHealthSnapshot?
    @Published public var isProbing: Bool = false
    @Published public var copyConfirmation: String?

    private let orchestrator: BootHealthOrchestrator
    /// Closure that runs the same registration + logging + banner-enqueue
    /// sweep AppDelegate ran at boot. Injected so the panel's "Re-probe"
    /// button hits the production code path, not a parallel one.
    private let probeRunner: @MainActor () async -> Void

    public init(
        orchestrator: BootHealthOrchestrator,
        probeRunner: @escaping @MainActor () async -> Void
    ) {
        self.orchestrator = orchestrator
        self.probeRunner = probeRunner
    }

    /// Run a fresh sweep, then read the new snapshot off the orchestrator.
    public func reprobe() async {
        isProbing = true
        copyConfirmation = nil
        await probeRunner()
        snapshot = await orchestrator.lastSnapshot()
        isProbing = false
    }

    /// Encode the snapshot as pretty-printed JSON and write to the
    /// general pasteboard. Updates `copyConfirmation` for the caption
    /// next to the button — auto-clears on next re-probe.
    public func copyReport() {
        guard let snap = snapshot else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(snap),
              let s = String(data: data, encoding: .utf8) else {
            copyConfirmation = "Encode failed"
            return
        }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(s, forType: .string)
        copyConfirmation = "Copied \(data.count) B"
    }
}

// MARK: - SwiftUI view

struct StatusPanelView: View {
    @ObservedObject var model: StatusPanelModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Jarvis Status").font(.title2).bold()
                Spacer()
                if model.isProbing {
                    ProgressView().controlSize(.small)
                }
            }

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    if let snap = model.snapshot {
                        ForEach(snap.subsystems, id: \.name) { health in
                            SubsystemRow(health: health)
                        }
                        Text("Probed \(snap.subsystems.count) subsystems at \(snap.producedAt.formatted(date: .omitted, time: .standard))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.top, 6)
                    } else if model.isProbing {
                        Text("Probing…")
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Probes haven't run yet.")
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: .infinity)

            Divider()

            HStack(spacing: 12) {
                Button("Re-probe all") {
                    Task { await model.reprobe() }
                }
                .disabled(model.isProbing)
                .keyboardShortcut("r", modifiers: [.command])

                Spacer()

                if let conf = model.copyConfirmation {
                    Text(conf)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .transition(.opacity)
                }

                Button("Copy report") {
                    model.copyReport()
                }
                .disabled(model.snapshot == nil)
                .keyboardShortcut("c", modifiers: [.command, .shift])
            }
        }
        .padding()
        .frame(minWidth: 480, minHeight: 380)
        .task {
            // Always re-probe on open. The handoff's mandate is live
            // state, never a cached boot snapshot.
            await model.reprobe()
        }
    }
}

// MARK: - Row

private struct SubsystemRow: View {
    let health: SubsystemHealth

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Text(glyph)
                .font(.body.bold())
                .foregroundColor(color)
                .frame(width: 18, alignment: .center)
                .accessibilityLabel(statusLabel)

            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(health.name)
                        .font(.body.weight(.medium))
                    Text(statusLabel)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("\(health.latencyMs) ms")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
                Text(health.evidence)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let reason = reasonText {
                    Text(reason)
                        .font(.caption)
                        .foregroundColor(reasonColor)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.vertical, 4)
    }

    private var glyph: String {
        switch health.status {
        case .ok: return "✓"
        case .degraded: return "⚠"
        case .failed: return "✗"
        case .unknown: return "?"
        }
    }

    private var color: Color {
        switch health.status {
        case .ok: return .green
        case .degraded: return .orange
        case .failed: return .red
        case .unknown: return .gray
        }
    }

    private var statusLabel: String {
        switch health.status {
        case .ok: return "ok"
        case .degraded: return "degraded"
        case .failed: return "failed"
        case .unknown: return "unknown"
        }
    }

    /// The reason string is only meaningful for non-ok statuses; for `.ok`
    /// the evidence line is already the concrete proof of health.
    private var reasonText: String? {
        switch health.status {
        case .ok: return nil
        case .degraded(let r, _), .failed(let r, _), .unknown(let r, _): return r
        }
    }

    private var reasonColor: Color {
        switch health.status {
        case .failed: return .red
        case .degraded: return .orange
        default: return .secondary
        }
    }
}

// MARK: - NSPanel

/// Floating panel that owns the SwiftUI hosting view. Constructed once
/// on first `Status…` menu click and kept alive across closes via
/// `isReleasedWhenClosed = false` (default NSPanel behavior releases the
/// window on close → second open crashes).
@MainActor
public final class StatusPanel: NSPanel {
    public let model: StatusPanelModel
    private let hosting: NSHostingView<StatusPanelView>

    public init(model: StatusPanelModel) {
        self.model = model
        self.hosting = NSHostingView(rootView: StatusPanelView(model: model))
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 380),
            styleMask: [.titled, .closable, .resizable, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        title = "Jarvis Status"
        isFloatingPanel = false
        becomesKeyOnlyIfNeeded = false
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        hosting.autoresizingMask = [.width, .height]
        contentView = hosting
    }

    /// Bring panel onto screen + give it focus. Non-modal — caller
    /// continues running. SwiftUI's `.task` modifier on the view body
    /// fires a re-probe automatically on the appearance pass.
    public func present() {
        if !isVisible {
            center()
        }
        makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
