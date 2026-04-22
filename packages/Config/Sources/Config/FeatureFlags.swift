import Foundation

/// OBS-05 / PATTERNS §Pattern 2: feature flags live in PerTurnSnapshot ONLY.
/// Security-affecting flags DO NOT EXIST (SEC-08 forbids a skip-allowlist).
public struct FeatureFlags: Sendable, Codable, Equatable {
    private let flags: [String: Bool]

    public init(_ flags: [String: Bool] = [:]) {
        self.flags = flags
    }

    public func isEnabled(_ key: String) -> Bool {
        flags[key] ?? false
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.flags = try container.decode([String: Bool].self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(flags)
    }
}
