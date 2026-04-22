import Foundation

public enum ConfigError: Error, Sendable, Equatable {
    case malformed(reason: String)
    case unknownSchemaVersion(Int)
    case futureSchema(version: Int)
    case invalidOllamaHost(String)
}
