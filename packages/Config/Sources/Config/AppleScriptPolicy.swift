import Foundation

public struct AppleScriptPolicy: Sendable, Codable, Equatable {
    public let confirmationRequired: Bool
    public init(confirmationRequired: Bool = true) {
        self.confirmationRequired = confirmationRequired
    }
    // SEC-08: Every AppleScript requires confirmation.
    // Reflection test in ConfigSplitTests.swift pins this shape.
}
