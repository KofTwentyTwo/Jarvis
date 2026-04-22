import Foundation

public struct TTSConfig: Sendable, Codable, Equatable {
    public let tier: String   // "tier1" (AVSpeechSynthesizer) | "tier2" (Orpheus). P6 interprets.
    public init(tier: String = "tier1") { self.tier = tier }
}
