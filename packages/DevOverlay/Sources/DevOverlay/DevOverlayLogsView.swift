// DevOverlayLogsView.swift
//
// Live log tail rendered as the fourth DevOverlay tab. Subscribes to
// `LogBroadcaster.shared` at view-appear, accumulates into a bounded
// `@Observable` model (1000-line cap), and renders a filterable,
// pause-able, monospaced scroll view.
//
// Filtering happens client-side because the broadcaster is the shared
// fan-out point for every Jarvis subsystem — channels + levels are
// emergent from whoever calls into swift-log, not enumerated up-front.
// Filtering server-side would push topology into the broadcaster and
// couple it to every consumer.
//
// Why bounded? The broadcaster's ring is 500 lines; the UI's model
// caps at 1000 so a user pausing for ~minute can scroll the history
// without falling off the back. Both bounds are generous defaults;
// neither is hot-loaded from config because the DevOverlay is dev-only.
//
// See also: LogBroadcaster.swift, DevOverlayView.swift.

#if canImport(SwiftUI)
import SwiftUI
import Observation
import Logging
import JarvisLogging

/// Bounded buffer of recent log lines plus user filter state.
///
/// ## Threading
///
/// `@MainActor` — all mutations happen on the SwiftUI executor. The
/// background subscriber Task hops to the main actor before calling
/// `append(_:)`.
@available(macOS 14.0, *)
@MainActor
@Observable
public final class DevOverlayLogsModel {
    public private(set) var lines: [LogLine] = []
    public var isPaused: Bool = false

    /// Search substring (case-insensitive). Empty = match all.
    public var searchText: String = ""

    /// Active channel filter. Empty set = no channel filter (show all).
    public var enabledChannels: Set<String> = []

    /// Active level filter. Empty set = no level filter (show all).
    public var enabledLevels: Set<Logger.Level> = []

    /// Cap so a long-running session doesn't grow unbounded.
    public let cap: Int

    public init(cap: Int = 1000) {
        self.cap = cap
    }

    /// Append a new log line unless the user has paused the tail. We
    /// still cap the buffer regardless of pause so an unbounded backlog
    /// never accumulates — paused just means "don't show me new ones
    /// flowing in," not "stockpile them."
    public func append(_ line: LogLine) {
        guard !isPaused else { return }
        lines.append(line)
        if lines.count > cap {
            lines.removeFirst(lines.count - cap)
        }
    }

    /// Discovered channels across all currently-held lines. Drives the
    /// channel-filter dropdown — emergent rather than enumerated.
    public var availableChannels: [String] {
        Array(Set(lines.map(\.channel))).sorted()
    }

    /// Apply the active filters. Returns the filtered slice for rendering.
    public func filtered() -> [LogLine] {
        let needle = searchText.lowercased()
        return lines.filter { line in
            if !enabledChannels.isEmpty && !enabledChannels.contains(line.channel) {
                return false
            }
            if !enabledLevels.isEmpty && !enabledLevels.contains(line.level) {
                return false
            }
            if !needle.isEmpty && !line.message.lowercased().contains(needle) {
                return false
            }
            return true
        }
    }
}

/// SwiftUI surface for the logs tab.
///
/// ## Overview
///
/// Top bar: search field + channel popover + level toggles + pause/resume.
/// Body: scrollable, monospaced log list with auto-scroll-to-bottom while
/// not paused. Color-coded by level.
@available(macOS 14.0, *)
public struct DevOverlayLogsView: View {
    @State private var model = DevOverlayLogsModel()
    @State private var subscriberTask: Task<Void, Never>?

    public init() {}

    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            controlBar
            Divider()
            logList
        }
        .padding(8)
        .onAppear {
            startTail()
        }
        .onDisappear {
            subscriberTask?.cancel()
            subscriberTask = nil
        }
    }

    // MARK: - Control bar

    private var controlBar: some View {
        HStack(spacing: 8) {
            TextField("Search…", text: $model.searchText)
                .textFieldStyle(.roundedBorder)
                .frame(minWidth: 160, maxWidth: 240)

            Menu("Channels (\(model.enabledChannels.isEmpty ? "all" : "\(model.enabledChannels.count)"))") {
                Button("Show all") { model.enabledChannels = [] }
                Divider()
                ForEach(model.availableChannels, id: \.self) { ch in
                    Toggle(ch, isOn: Binding(
                        get: { model.enabledChannels.contains(ch) },
                        set: { on in
                            if on { model.enabledChannels.insert(ch) }
                            else { model.enabledChannels.remove(ch) }
                        }
                    ))
                }
            }
            .frame(maxWidth: 180)

            Menu("Levels (\(model.enabledLevels.isEmpty ? "all" : "\(model.enabledLevels.count)"))") {
                Button("Show all") { model.enabledLevels = [] }
                Divider()
                ForEach(allLevels, id: \.self) { lvl in
                    Toggle(label(for: lvl), isOn: Binding(
                        get: { model.enabledLevels.contains(lvl) },
                        set: { on in
                            if on { model.enabledLevels.insert(lvl) }
                            else { model.enabledLevels.remove(lvl) }
                        }
                    ))
                }
            }
            .frame(maxWidth: 140)

            Spacer()

            Button(model.isPaused ? "Resume" : "Pause") {
                model.isPaused.toggle()
            }
            .keyboardShortcut("p", modifiers: [.command])

            Text("\(model.lines.count) lines")
                .font(.caption.monospaced())
                .foregroundColor(.secondary)
        }
    }

    // MARK: - Log list

    private var logList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(model.filtered()) { line in
                        LogLineRow(line: line)
                            .id(line.id)
                    }
                }
                .padding(.horizontal, 4)
            }
            .onChange(of: model.lines.count) { _, _ in
                // Auto-scroll to bottom on every new line — unless the
                // user has paused, in which case the view freezes.
                guard !model.isPaused, let last = model.lines.last else { return }
                withAnimation(.linear(duration: 0.05)) {
                    proxy.scrollTo(last.id, anchor: .bottom)
                }
            }
        }
    }

    // MARK: - Subscription

    /// Spawn the live-tail subscriber. Each line is appended on the main
    /// actor so SwiftUI's Observation re-render happens on its expected
    /// executor.
    private func startTail() {
        subscriberTask?.cancel()
        let modelRef = model
        subscriberTask = Task { @MainActor in
            let stream = await LogBroadcaster.shared.subscribe()
            for await line in stream {
                if Task.isCancelled { break }
                modelRef.append(line)
            }
        }
    }

    private var allLevels: [Logger.Level] {
        [.trace, .debug, .info, .notice, .warning, .error, .critical]
    }

    private func label(for level: Logger.Level) -> String {
        switch level {
        case .trace: return "trace"
        case .debug: return "debug"
        case .info: return "info"
        case .notice: return "notice"
        case .warning: return "warning"
        case .error: return "error"
        case .critical: return "critical"
        }
    }
}

// MARK: - Row

@available(macOS 14.0, *)
private struct LogLineRow: View {
    let line: LogLine

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Text(timeFormatter.string(from: line.timestamp))
                .foregroundColor(.secondary)
            Text(levelLabel)
                .foregroundColor(levelColor)
                .frame(width: 56, alignment: .leading)
            Text(line.channel)
                .foregroundColor(.secondary)
                .frame(width: 110, alignment: .leading)
                .lineLimit(1)
                .truncationMode(.middle)
            Text(line.message)
                .foregroundColor(levelColor)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
        }
        .font(.system(size: 11, design: .monospaced))
    }

    private var levelLabel: String {
        switch line.level {
        case .trace: return "TRACE"
        case .debug: return "DEBUG"
        case .info: return "INFO"
        case .notice: return "NOTE"
        case .warning: return "WARN"
        case .error: return "ERROR"
        case .critical: return "CRIT"
        }
    }

    private var levelColor: Color {
        switch line.level {
        case .trace, .debug, .info, .notice: return .primary
        case .warning: return .orange
        case .error, .critical: return .red
        }
    }
}

// Module-private formatter — configured once at module-init. ISO with
// millisecond precision is enough for log tails.
private let timeFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "HH:mm:ss.SSS"
    return f
}()
#endif
