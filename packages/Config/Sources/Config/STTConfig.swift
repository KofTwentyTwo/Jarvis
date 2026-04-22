import Foundation

public struct STTConfig: Sendable, Codable, Equatable {
    public let whisperKitFallback: Bool
    public init(whisperKitFallback: Bool = false) {
        self.whisperKitFallback = whisperKitFallback
    }
}
