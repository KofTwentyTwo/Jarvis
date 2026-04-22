import Foundation

public struct LoggingLaunchConfig: Sendable, Codable, Equatable {
    public let fileLevel: String   // "debug"|"info"|"notice"|"warning"|"error"
    public let osLogLevel: String
    public init(fileLevel: String = "info", osLogLevel: String = "info") {
        self.fileLevel = fileLevel
        self.osLogLevel = osLogLevel
    }
}
