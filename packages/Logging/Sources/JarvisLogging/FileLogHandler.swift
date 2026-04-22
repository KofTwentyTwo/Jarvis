import Foundation
import Logging  // swift-log

struct FileLogHandler: LogHandler {
    let label: String
    let directory: URL
    let dateProvider: any DateProvider

    var logLevel: Logger.Level = .info
    var metadata: Logger.Metadata = [:]
    var metadataProvider: Logger.MetadataProvider?

    private let writer: FileRotatingWriter

    init(label: String, directory: URL, dateProvider: any DateProvider) {
        self.label = label
        self.directory = directory
        self.dateProvider = dateProvider
        self.writer = FileRotatingWriter(
            directory: directory,
            baseName: label,
            retentionDays: 7,
            dateProvider: dateProvider
        )
    }

    func log(level: Logger.Level, message: Logger.Message,
             metadata: Logger.Metadata?, source: String,
             file: String, function: String, line: UInt) {
        let merged = self.metadata.merging(metadata ?? [:]) { _, new in new }
        let metaStr = merged.isEmpty ? "" : " " + merged.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: " ")
        let iso = ISO8601DateFormatter.jarvisShared.string(from: dateProvider.now())
        let raw = "\(iso) \(level.rawValue.uppercased()) [\(label)] \(message)\(metaStr)\n"
        let redacted = Redact.apply(raw)   // S-4: single call site
        writer.append(redacted)
    }

    subscript(metadataKey key: String) -> Logger.Metadata.Value? {
        get { metadata[key] }
        set { metadata[key] = newValue }
    }
}

extension ISO8601DateFormatter {
    // `ISO8601DateFormatter` is documented thread-safe since macOS 10.12 (Apple: "thread-safe
    // for reading and writing" after configuration), but is not declared `Sendable`. We
    // configure it once at type-init and never mutate, so `nonisolated(unsafe)` is the
    // appropriate Swift 6 escape hatch.
    nonisolated(unsafe) static let jarvisShared: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
}
