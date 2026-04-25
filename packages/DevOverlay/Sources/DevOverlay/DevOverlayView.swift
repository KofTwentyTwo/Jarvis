#if canImport(SwiftUI)
import SwiftUI
import AgentCore
import AgentOrchestrator

/// SwiftUI surface for the DevOverlay (OBS-01).
///
/// Matches the layout described in `04-RESEARCH.md §9`:
/// - State + turn-id row
/// - Provider + model row
/// - Input/output token counts row
/// - Cache creation / read row with hit percentage
/// - Latency row (TTFB + total)
/// - "Last 5 tool calls" table
///
/// Rendering is read-only — the view-model is driven by a DevSnapshot channel
/// subscriber, so nothing in this file mutates state.
@available(macOS 14.0, *)
public struct DevOverlayView: View {
    // ME-01: `@Observable` triggers re-renders via the property-wrapper
    // macros; `@State` on a reference type defeats this — it captures the
    // initial reference and ignores subsequent inits. The view-model is
    // injected from outside (DevOverlayWindow), so a plain `let` is the
    // canonical Observation-framework pattern for read-only observation.
    public let viewModel: DevOverlayViewModel

    public init(viewModel: DevOverlayViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("State:")
                Text(stateLabel(viewModel.snapshot.state)).bold()
                Spacer()
                Text("Turn:")
                Text(turnIdShort(viewModel.snapshot.turnId)).monospaced()
            }
            HStack {
                Text("Provider:")
                Text("\(viewModel.snapshot.provider) / \(viewModel.snapshot.modelId)").monospaced()
            }
            HStack {
                Text("Input:")
                Text("\(viewModel.snapshot.inputTokens) tok").monospaced()
                Text("Output:")
                Text("\(viewModel.snapshot.outputTokens) tok").monospaced()
            }
            HStack {
                Text("Cache creation:")
                Text("\(viewModel.snapshot.cacheCreationInputTokens) tok").monospaced()
            }
            HStack {
                Text("Cache read:")
                Text("\(viewModel.snapshot.cacheReadInputTokens) tok").monospaced()
                Text(String(format: "(%.0f%% hit)", viewModel.snapshot.cacheHitPercentage)).monospaced()
            }
            HStack {
                Text("Latency:")
                Text("ttfb=\(viewModel.snapshot.ttfbMs)ms").monospaced()
                Text("total=\(viewModel.snapshot.totalMs)ms").monospaced()
            }
            Divider()
            Text("Last 5 tool calls:").bold()
            if viewModel.snapshot.toolCalls.isEmpty {
                Text("—").foregroundColor(.secondary).monospaced()
            } else {
                ForEach(viewModel.snapshot.toolCalls) { row in
                    HStack {
                        Text(row.name).monospaced()
                        Text("\(row.durationMs)ms").monospaced().foregroundColor(.secondary)
                        Text(symbolForStatus(row.status))
                        Spacer()
                        Text(previewText(row.preview)).foregroundColor(.secondary).monospaced()
                    }
                }
            }
        }
        .padding(12)
        .frame(minWidth: 380, maxWidth: 460, alignment: .leading)
        .background(.regularMaterial)
    }

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

    private func turnIdShort(_ id: TurnID?) -> String {
        guard let raw = id?.rawValue, !raw.isEmpty else { return "—" }
        return String(raw.prefix(8))
    }

    private func symbolForStatus(_ s: ToolCallRow.Status) -> String {
        switch s {
        case .pending: return "⏸"
        case .running: return "…"
        case .completed: return "✓"
        case .failed: return "✗"
        case .awaitingApproval: return "?"
        }
    }

    private func previewText(_ preview: String?) -> String {
        guard let p = preview, !p.isEmpty else { return "—" }
        return String(p.prefix(30))
    }
}
#endif
