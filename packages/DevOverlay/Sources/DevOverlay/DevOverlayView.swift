// DevOverlayView.swift
//
// SwiftUI surface for the DevOverlay. Three tabs:
//
//   - Agent: live TurnState, provider/model, token + cache counters, latency.
//   - Tools: last 5 tool calls (name, status glyph, duration, preview).
//   - Health: subsystem health rows (reuses the BootHealth shape from the
//     Status panel — but read-only; the Status menu remains the place to
//     trigger a re-probe).
//
// The "Logs" tab gets added in Slice 3 by `DevOverlayLogsView`. Slice 2
// ships the three observational tabs above.
//
// Rendering is read-only. Every binding reads off `viewModel`; nothing
// in this file mutates state. The single-writer invariants live on the
// view-model.

#if canImport(SwiftUI)
import SwiftUI
import AgentCore
import AgentOrchestrator

/// Root DevOverlay view.
///
/// ## Overview
///
/// `TabView` keeps the panel small while letting each pane render its
/// data without competing for vertical space. The `Agent` tab is the
/// default; `Tools` is the second-most-used pane during development.
///
/// ## Threading
///
/// Reads only — SwiftUI handles re-render off `@Observable` property
/// changes on the main actor.
@available(macOS 14.0, *)
public struct DevOverlayView: View {
    // ME-01: `@Observable` triggers re-renders via property-wrapper macros;
    // `@State` on a reference type would capture the initial reference and
    // ignore subsequent inits. Plain `let` is the canonical Observation
    // pattern for read-only observation of an injected model.
    public let viewModel: DevOverlayViewModel

    public init(viewModel: DevOverlayViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        TabView {
            AgentPane(viewModel: viewModel)
                .tabItem { Label("Agent", systemImage: "brain") }
                .tag(0)

            ToolsPane(viewModel: viewModel)
                .tabItem { Label("Tools", systemImage: "wrench.and.screwdriver") }
                .tag(1)

            HealthPane(viewModel: viewModel)
                .tabItem { Label("Health", systemImage: "stethoscope") }
                .tag(2)

            DevOverlayLogsView()
                .tabItem { Label("Logs", systemImage: "text.alignleft") }
                .tag(3)
        }
        .padding(8)
        .frame(minWidth: 640, minHeight: 520)
        .background(.regularMaterial)
    }
}

// MARK: - Agent pane

/// Live agent snapshot: state, turn ID, provider/model, tokens, latency.
@available(macOS 14.0, *)
private struct AgentPane: View {
    let viewModel: DevOverlayViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // HudState + TurnState side-by-side. They can disagree briefly
            // (HudState lags TurnState by one resolveAndEmit hop) — showing
            // both makes that lag visible rather than mysterious.
            HStack {
                Text("HUD:").foregroundColor(.secondary)
                Text(viewModel.hudStateLabel).bold().monospaced()
                Spacer()
                Text("Turn state:").foregroundColor(.secondary)
                Text(stateLabel(viewModel.snapshot.state)).bold().monospaced()
            }
            HStack {
                Text("Turn ID:").foregroundColor(.secondary)
                Text(turnIdShort(viewModel.snapshot.turnId)).monospaced()
                Spacer()
                Text("Provider:").foregroundColor(.secondary)
                Text("\(viewModel.snapshot.provider) / \(viewModel.snapshot.modelId)").monospaced()
            }

            Divider()

            GroupBox("Tokens") {
                VStack(alignment: .leading, spacing: 4) {
                    row("Input",  "\(viewModel.snapshot.inputTokens) tok")
                    row("Output", "\(viewModel.snapshot.outputTokens) tok")
                    row("Cache create", "\(viewModel.snapshot.cacheCreationInputTokens) tok")
                    row("Cache read",
                        "\(viewModel.snapshot.cacheReadInputTokens) tok " +
                        String(format: "(%.0f%% hit)", viewModel.snapshot.cacheHitPercentage))
                }
            }

            GroupBox("Latency (current turn)") {
                VStack(alignment: .leading, spacing: 4) {
                    row("TTFB",  "\(viewModel.snapshot.ttfbMs) ms")
                    row("Total", "\(viewModel.snapshot.totalMs) ms")
                }
            }

            Spacer()
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).foregroundColor(.secondary).frame(width: 110, alignment: .leading)
            Text(value).monospaced()
            Spacer()
        }
    }
}

// MARK: - Tools pane

/// Last 5 tool calls. Dedupes on `toolUseId` upstream in the emitter, so
/// a streaming pending → running → completed sequence renders as one row
/// updating in place rather than three rows in the ring.
@available(macOS 14.0, *)
private struct ToolsPane: View {
    let viewModel: DevOverlayViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Last 5 tool calls").font(.headline)
            Divider()
            if viewModel.snapshot.toolCalls.isEmpty {
                Text("No tool calls yet.")
                    .foregroundColor(.secondary)
                    .monospaced()
                    .padding(.top, 16)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(viewModel.snapshot.toolCalls) { row in
                            ToolCallRowView(row: row)
                            Divider()
                        }
                    }
                }
            }
            Spacer()
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

@available(macOS 14.0, *)
private struct ToolCallRowView: View {
    let row: ToolCallRow

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text(symbol(row.status))
                .frame(width: 18, alignment: .center)
                .foregroundColor(color(row.status))
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(row.name).bold().monospaced()
                    Spacer()
                    Text("\(row.durationMs) ms")
                        .font(.caption.monospaced())
                        .foregroundColor(.secondary)
                }
                if let preview = row.preview, !preview.isEmpty {
                    Text(preview)
                        .font(.caption.monospaced())
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                        .truncationMode(.tail)
                }
                if let err = row.error, !err.isEmpty {
                    Text(err)
                        .font(.caption)
                        .foregroundColor(.red)
                        .lineLimit(2)
                }
            }
        }
    }

    private func symbol(_ s: ToolCallRow.Status) -> String {
        switch s {
        case .pending: return "⏸"
        case .running: return "…"
        case .completed: return "✓"
        case .failed: return "✗"
        case .awaitingApproval: return "?"
        }
    }

    private func color(_ s: ToolCallRow.Status) -> Color {
        switch s {
        case .pending, .running, .awaitingApproval: return .secondary
        case .completed: return .green
        case .failed: return .red
        }
    }
}

// MARK: - Health pane

/// Read-only BootHealth view. The Status menu remains the place to
/// trigger a re-probe; the DevOverlay just shows whatever the last
/// `lastSnapshot()` returned.
@available(macOS 14.0, *)
private struct HealthPane: View {
    let viewModel: DevOverlayViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Subsystem health").font(.headline)
            Divider()
            if let snap = viewModel.bootHealth {
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(snap.subsystems, id: \.name) { health in
                            HealthRowView(health: health)
                        }
                        Text("Probed at \(snap.producedAt.formatted(date: .omitted, time: .standard))")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .padding(.top, 6)
                    }
                }
            } else {
                Text("BootHealth has not run yet. Open Status… to trigger.")
                    .foregroundColor(.secondary)
                    .padding(.top, 16)
            }
            Spacer()
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

@available(macOS 14.0, *)
private struct HealthRowView: View {
    let health: SubsystemHealth

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Text(glyph)
                .font(.body.bold())
                .foregroundColor(color)
                .frame(width: 18, alignment: .center)
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(health.name).font(.body.weight(.medium))
                    Text(statusLabel).font(.caption).foregroundColor(.secondary)
                    Spacer()
                    Text("\(health.latencyMs) ms")
                        .font(.caption.monospaced())
                        .foregroundColor(.secondary)
                }
                Text(health.evidence)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let r = reasonText {
                    Text(r).font(.caption).foregroundColor(reasonColor)
                }
            }
        }
        .padding(.vertical, 2)
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

// MARK: - Helpers

@available(macOS 14.0, *)
private func stateLabel(_ s: TurnState) -> String {
    switch s {
    case .idle: return "idle"
    case .booting: return "booting"
    case .thinking: return "thinking"
    case .speaking: return "speaking"
    case .listening: return "listening"
    case .awaitingConfirmation(let id): return "awaiting(\(id.rawValue))"
    case .reconfiguring: return "reconfiguring"
    }
}

@available(macOS 14.0, *)
private func turnIdShort(_ id: TurnID?) -> String {
    guard let raw = id?.rawValue, !raw.isEmpty else { return "—" }
    return String(raw.prefix(8))
}
#endif
