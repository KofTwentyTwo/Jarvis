import Darwin
import Foundation
import os

/// Serial writer with lazy rotation at local-calendar day boundary.
/// Per D-18: rotate daily at local midnight; retain last 7 days.
/// Per RESEARCH Q3 line 491: lazy on first post-midnight write (no timer thread).
///
/// WR-01 (OBS-06): every write is fallible (disk full, FD evicted,
/// permission revoked mid-session). Rather than silently drop with `try?`,
/// the writer counts dropped lines per rotation window and emits the count
/// to `os.Logger` at each rotation boundary, so failures are observable
/// even when the file log is unavailable.
final class FileRotatingWriter: @unchecked Sendable {
    private let directory: URL
    private let baseName: String
    private let retentionDays: Int
    private let dateProvider: any DateProvider
    private let queue: DispatchQueue
    private var currentDayString: String?
    private var currentHandle: FileHandle?

    /// WR-01: tracks lines dropped since the last rotation (serial queue —
    /// only touched from `queue.async` blocks). Emitted via `os.Logger` and
    /// reset to zero on each rotation so the signal doesn't grow unbounded.
    private var droppedLinesThisWindow: UInt64 = 0
    /// Guard against spamming os.Logger: emit the open-failure fault at
    /// most once per rotation window.
    private var warnedAboutOpenFailureThisWindow: Bool = false
    /// os.Logger for out-of-band fault reporting when the file log itself
    /// is the thing that's broken. Uses subsystem/category matching
    /// `OSLogHandler` so Console.app filters line up.
    private let faultLogger = os.Logger(
        subsystem: "com.koftwentytwo.jarvis",
        category: "logging.file"
    )

    private let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.timeZone = TimeZone.current
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    init(directory: URL, baseName: String, retentionDays: Int, dateProvider: any DateProvider) {
        self.directory = directory
        self.baseName = baseName
        self.retentionDays = retentionDays
        self.dateProvider = dateProvider
        self.queue = DispatchQueue(label: "com.koftwentytwo.jarvis.filelog.\(baseName)")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func append(_ line: String) {
        queue.async {
            self.rotateIfNeeded()
            guard let handle = self.currentHandle,
                  let data = line.data(using: .utf8) else {
                self.droppedLinesThisWindow &+= 1
                if !self.warnedAboutOpenFailureThisWindow {
                    self.faultLogger.fault(
                        "file log handle unavailable; dropping line for base=\(self.baseName, privacy: .public)"
                    )
                    self.warnedAboutOpenFailureThisWindow = true
                }
                return
            }
            do {
                try handle.write(contentsOf: data)
            } catch {
                self.droppedLinesThisWindow &+= 1
                if !self.warnedAboutOpenFailureThisWindow {
                    self.faultLogger.fault(
                        "file log write failed; dropping line for base=\(self.baseName, privacy: .public)"
                    )
                    self.warnedAboutOpenFailureThisWindow = true
                }
            }
        }
    }

    /// Test-only accessor for the dropped-lines counter. Dispatches through
    /// the serial queue to avoid a TSan race on the test side.
    internal func droppedLinesSnapshot() -> UInt64 {
        queue.sync { droppedLinesThisWindow }
    }

    /// WR-08: run retention GC on demand, independent of the rotation path.
    /// Call at process shutdown or on a periodic heartbeat so an app that
    /// sits idle for >7 days without a day-crossing log line still deletes
    /// stale files.
    func runRetentionGC() {
        queue.async { [self] in
            gcOldFiles(now: dateProvider.now())
        }
    }

    private func rotateIfNeeded() {
        let today = dateFormatter.string(from: dateProvider.now())
        if today == currentDayString { return }

        // WR-08: defensive check against large clock-skew. If the user's
        // clock jumped more than ±2 days from the previous window, log a
        // one-line warning alongside the normal rotation — the file log
        // still rotates because `today` changed, but ops now see that the
        // rotation happened for a non-standard reason.
        if let prev = currentDayString,
           let prevDate = dateFormatter.date(from: prev),
           let nowDate = dateFormatter.date(from: today) {
            let dayDelta = Calendar(identifier: .gregorian)
                .dateComponents([.day], from: prevDate, to: nowDate).day ?? 0
            if abs(dayDelta) > 2 {
                faultLogger.notice(
                    "file log rotating after \(dayDelta, privacy: .public)-day clock skew for base=\(self.baseName, privacy: .public)"
                )
            }
        }

        // WR-01: at a rotation boundary, emit the drop count for the
        // just-closed window (if non-zero) so ops can see data loss even
        // when the file log itself was the failure source.
        if droppedLinesThisWindow > 0 {
            faultLogger.error(
                "file log rotated with \(self.droppedLinesThisWindow, privacy: .public) dropped line(s) for base=\(self.baseName, privacy: .public)"
            )
            droppedLinesThisWindow = 0
        }
        warnedAboutOpenFailureThisWindow = false

        try? currentHandle?.close()
        currentHandle = nil

        let fileURL = directory.appendingPathComponent("\(baseName).\(today).log")
        // Open with O_CLOEXEC at creation time so this long-lived FD does not
        // leak into spawned MCP helper processes — JarvisMCP/ChildSpawnGate
        // fatal-errors in Debug on any FD missing FD_CLOEXEC. O_APPEND forces
        // every write to end-of-file, removing the need for seekToEnd().
        // O_CREAT handles the first-launch case in one syscall.
        let fd = fileURL.path.withCString { path -> Int32 in
            Darwin.open(path, O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC, 0o644)
        }
        currentHandle = fd >= 0 ? FileHandle(fileDescriptor: fd, closeOnDealloc: true) : nil
        currentDayString = today

        gcOldFiles(now: dateProvider.now())
    }

    /// Delete files older than `retentionDays` days.
    private func gcOldFiles(now: Date) {
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        let cutoff = Calendar(identifier: .gregorian).date(byAdding: .day, value: -retentionDays, to: now) ?? now

        for url in contents where url.lastPathComponent.hasPrefix("\(baseName).") && url.lastPathComponent.hasSuffix(".log") {
            let components = url.lastPathComponent
                .replacingOccurrences(of: "\(baseName).", with: "")
                .replacingOccurrences(of: ".log", with: "")
            if let fileDate = dateFormatter.date(from: components), fileDate < cutoff {
                try? fm.removeItem(at: url)
            }
        }
    }

    deinit {
        try? currentHandle?.close()
    }
}
