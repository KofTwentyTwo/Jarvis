import Foundation

public struct PerTurnSnapshot: Sendable, Codable, Equatable {
    public let schemaVersion: Int
    public let provider: ProviderSelection
    public let tts: TTSConfig
    public let stt: STTConfig
    public let featureFlags: FeatureFlags
    // DO NOT add: ollama host, applescript policy, toolBlocklist, confirmationPolicy (all Launch-pinned per SEC-05).
}
