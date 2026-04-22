import Foundation

public enum KeychainError: Error, Sendable, Equatable {
    case itemNotFound
    case duplicateItem
    case unexpectedStatus(OSStatus)
}
