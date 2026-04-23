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
        // WR-08 / IN-02: do NOT mark the message body `.public` — that
        // defeats os.Logger's default `%{private}@` masking for interpolated
        // values. Message text may contain untrusted input (file paths,
        // error descriptions, user-supplied strings) that the caller hasn't
        // run through `Redact.apply` — os.Logger's private-by-default
        // provides defense in depth. Log level is emitted via the `osLevel`
        // API, not the message body, so this does not lose severity signal
        // in Console.app.
        logger.log(level: osLevel, "\(message, privacy: .private(mask: .hash))")
    }

    subscript(metadataKey key: String) -> Logging.Logger.Metadata.Value? {
        get { metadata[key] }
        set { metadata[key] = newValue }
    }
}
