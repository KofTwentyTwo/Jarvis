import Foundation

/// WR-11: typed allowlist of known feature flag keys. Callers go through
/// `isEnabled(_ flag: FeatureFlag)` instead of a raw string so a typo
/// (e.g. `"orpheusTtsEnabled"` — wrong case — or `"orpheus_tts_enabled"`
/// — wrong separator) fails to compile rather than silently returning
/// false. Phase 6 (Orpheus / WhisperKit) wiring depends on these flags;
/// a silently-disabled feature is nearly impossible to debug.
public enum FeatureFlag: String, CaseIterable, Sendable {
    case orpheusTTSEnabled
    case whisperKitSTTEnabled
}

/// OBS-05 / PATTERNS §Pattern 2: feature flags live in PerTurnSnapshot ONLY.
/// Security-affecting flags DO NOT EXIST (SEC-08 forbids a skip-allowlist).
public struct FeatureFlags: Sendable, Codable, Equatable {
    private let flags: [String: Bool]

    public init(_ flags: [String: Bool] = [:]) {
        self.flags = flags
    }

    /// WR-11: canonical, typo-safe feature flag lookup.
    public func isEnabled(_ flag: FeatureFlag) -> Bool {
        flags[flag.rawValue] ?? false
    }

    /// WR-11: string-keyed lookup retained only for dynamic inspection
    /// (e.g. dev overlay listing all flags by name). Do NOT call this from
    /// production code — use `isEnabled(_ flag: FeatureFlag)` instead so
    /// the compiler catches typos.
    public func isEnabledDynamic(_ key: String) -> Bool {
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
