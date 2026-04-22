import Foundation

public protocol KeychainStore: Sendable {
    func set(_ value: String, for item: KeychainItem) throws
    func get(_ item: KeychainItem) throws -> String
    func delete(_ item: KeychainItem) throws
}
