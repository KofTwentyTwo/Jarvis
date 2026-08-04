import Foundation

public struct PerTurnSnapshot: Sendable, Codable, Equatable {
    public let schemaVersion: Int
    public let provider: ProviderSelection
    public let escalationEnabled: Bool
    public let tts: TTSConfig
    public let stt: STTConfig
    public let featureFlags: FeatureFlags
    // DO NOT add: ollama host, applescript policy, toolBlocklist, confirmationPolicy (all Launch-pinned per SEC-05).

    public init(
        schemaVersion: Int,
        provider: ProviderSelection,
        escalationEnabled: Bool = true,
        tts: TTSConfig,
        stt: STTConfig,
        featureFlags: FeatureFlags
    ) {
        self.schemaVersion = schemaVersion
        self.provider = provider
        self.escalationEnabled = escalationEnabled
        self.tts = tts
        self.stt = stt
        self.featureFlags = featureFlags
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, provider, escalationEnabled, tts, stt, featureFlags
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.schemaVersion = try c.decode(Int.self, forKey: .schemaVersion)
        self.provider = try c.decode(ProviderSelection.self, forKey: .provider)
        self.escalationEnabled = try c.decodeIfPresent(Bool.self, forKey: .escalationEnabled) ?? true
        self.tts = try c.decode(TTSConfig.self, forKey: .tts)
        self.stt = try c.decode(STTConfig.self, forKey: .stt)
        self.featureFlags = try c.decode(FeatureFlags.self, forKey: .featureFlags)
    }

    /// Local-first LLM routing (Task 6 / spec §2): convenience copy with a
    /// different provider. Used by `AgentOrchestrator` on reactive
    /// escalation to swap `.ollama` → `.anthropic` for the same turn
    /// without mutating the underlying `ConfigStore` (the escalation is a
    /// per-turn decision, not a config update).
    public func with(provider: ProviderSelection) -> PerTurnSnapshot {
        PerTurnSnapshot(
            schemaVersion: schemaVersion,
            provider: provider,
            escalationEnabled: escalationEnabled,
            tts: tts,
            stt: stt,
            featureFlags: featureFlags
        )
    }

    /// Local-first LLM routing (Task 9 / spec §6): convenience copy that
    /// mutates the `{provider, escalationEnabled}` pair atomically. Used
    /// by the Settings provider-mode picker so a single toggle persists
    /// both fields through `ConfigStore.updatePerTurn(_:)`. Other fields
    /// are preserved verbatim.
    public func with(
        provider: ProviderSelection,
        escalationEnabled: Bool
    ) -> PerTurnSnapshot {
        PerTurnSnapshot(
            schemaVersion: schemaVersion,
            provider: provider,
            escalationEnabled: escalationEnabled,
            tts: tts,
            stt: stt,
            featureFlags: featureFlags
        )
    }
}
