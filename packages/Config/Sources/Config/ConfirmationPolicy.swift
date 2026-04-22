import Foundation

public struct ConfirmationPolicy: Sendable, Codable, Equatable {
    public let timeoutSeconds: Int
    public init(timeoutSeconds: Int = 60) {
        self.timeoutSeconds = timeoutSeconds
    }
}
