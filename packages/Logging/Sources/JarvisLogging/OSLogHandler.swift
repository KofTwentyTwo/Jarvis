import Foundation
import Logging   // swift-log
import os        // Apple os.Logger

struct OSLogHandler: LogHandler {
    let subsystem: String
    let category: String
    private let logger: os.Logger

    var logLevel: Logging.Logger.Level = .info
    var metadata: Logging.Logger.Metadata = [:]
    var metadataProvider: Logging.Logger.MetadataProvider?

    init(subsystem: String, category: String, label: String) {
        self.subsystem = subsystem
        self.category = category
        self.logger = os.Logger(subsystem: subsystem, category: category)
    }

    func log(level: Logging.Logger.Level, message: Logging.Logger.Message,
             metadata: Logging.Logger.Metadata?, source: String,
             file: String, function: String, line: UInt) {
        let osLevel: OSLogType = switch level {
        case .trace, .debug: .debug
        case .info, .notice: .info
        case .warning: .default
        case .error: .error
        case .critical: .fault
        }
        // NOTE: no redaction here — os.Logger handles %{private}@ at system layer.
        // Discipline: callers must redact untrusted input BEFORE passing to Logger.
        logger.log(level: osLevel, "\(message, privacy: .public)")
    }

    subscript(metadataKey key: String) -> Logging.Logger.Metadata.Value? {
        get { metadata[key] }
        set { metadata[key] = newValue }
    }
}
