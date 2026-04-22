import Foundation

/// Serial writer with lazy rotation at local-calendar day boundary.
/// Per D-18: rotate daily at local midnight; retain last 7 days.
/// Per RESEARCH Q3 line 491: lazy on first post-midnight write (no timer thread).
final class FileRotatingWriter: @unchecked Sendable {
    private let directory: URL
    private let baseName: String
    private let retentionDays: Int
    private let dateProvider: any DateProvider
    private let queue: DispatchQueue
    private var currentDayString: String?
    private var currentHandle: FileHandle?

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
        self.queue = DispatchQueue(label: "com.kingsrook.jarvis.filelog.\(baseName)")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func append(_ line: String) {
        queue.async {
            self.rotateIfNeeded()
            guard let handle = self.currentHandle,
                  let data = line.data(using: .utf8) else { return }
            try? handle.write(contentsOf: data)
        }
    }

    private func rotateIfNeeded() {
        let today = dateFormatter.string(from: dateProvider.now())
        if today == currentDayString { return }
        try? currentHandle?.close()
        currentHandle = nil

        let fileURL = directory.appendingPathComponent("\(baseName).\(today).log")
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            FileManager.default.createFile(atPath: fileURL.path, contents: nil)
        }
        currentHandle = try? FileHandle(forWritingTo: fileURL)
        try? currentHandle?.seekToEnd()
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
