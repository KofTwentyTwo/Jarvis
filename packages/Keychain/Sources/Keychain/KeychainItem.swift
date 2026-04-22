import Foundation

public struct KeychainItem: Sendable, Equatable {
    public let service: String
    public let account: String
    public init(service: String, account: String) {
        self.service = service
        self.account = account
    }
}

public extension KeychainItem {
    /// Anthropic API key storage location per SEC-01 / D-10.
    /// kSecAttrService: "com.koftwentytwo.jarvis"
    /// kSecAttrAccount: "anthropic"
    static let anthropic = KeychainItem(service: "com.koftwentytwo.jarvis", account: "anthropic")
}
