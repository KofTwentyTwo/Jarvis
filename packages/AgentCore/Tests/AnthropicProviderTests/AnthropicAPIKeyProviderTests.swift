import XCTest
import Keychain
@testable import AnthropicProvider

/// Coverage for `AnthropicAPIKeyProvider.make(keychain:item:)` — the
/// builder that propagates `KeychainError` instead of swallowing it into
/// the empty-string fallback that produced the 2026-05-03 audit's
/// silent-401 symptom.
final class AnthropicAPIKeyProviderTests: XCTestCase {

    // MARK: - Test doubles

    private struct ThrowingKeychain: KeychainStore {
        let error: KeychainError
        func set(_ value: String, for item: KeychainItem) throws { throw error }
        func get(_ item: KeychainItem) throws -> String { throw error }
        func delete(_ item: KeychainItem) throws { throw error }
    }

    private struct StaticKeychain: KeychainStore {
        let value: String
        func set(_ value: String, for item: KeychainItem) throws {}
        func get(_ item: KeychainItem) throws -> String { value }
        func delete(_ item: KeychainItem) throws {}
    }

    private struct CapturingKeychain: KeychainStore, @unchecked Sendable {
        // @unchecked Sendable: the captured array is mutated only inside
        // a serial test method; no cross-thread access in tests.
        final class Box: @unchecked Sendable {
            var requested: [KeychainItem] = []
        }
        let box = Box()
        let value: String
        func set(_ value: String, for item: KeychainItem) throws {}
        func get(_ item: KeychainItem) throws -> String {
            box.requested.append(item)
            return value
        }
        func delete(_ item: KeychainItem) throws {}
    }

    // MARK: - Error propagation (KP-1..KP-3)

    /// KP-1: itemNotFound throws verbatim — does NOT collapse to empty
    /// string. This is the literal regression the 2026-05-03 audit named.
    func test_propagates_itemNotFound() async {
        let kc = ThrowingKeychain(error: .itemNotFound)
        let provider = AnthropicAPIKeyProvider.make(keychain: kc, item: .anthropic)

        do {
            _ = try await provider()
            XCTFail("provider must throw, not silently substitute empty string")
        } catch let err as KeychainError {
            XCTAssertEqual(err, .itemNotFound)
        } catch {
            XCTFail("expected KeychainError, got \(error)")
        }
    }

    /// KP-2: unexpectedStatus also propagates verbatim with its OSStatus.
    func test_propagates_unexpectedStatus() async {
        let kc = ThrowingKeychain(error: .unexpectedStatus(-25300))
        let provider = AnthropicAPIKeyProvider.make(keychain: kc, item: .anthropic)

        do {
            _ = try await provider()
            XCTFail("provider must throw")
        } catch let err as KeychainError {
            XCTAssertEqual(err, .unexpectedStatus(-25300))
        } catch {
            XCTFail("expected KeychainError, got \(error)")
        }
    }

    /// KP-3: duplicateItem also propagates (less likely on read, but the
    /// contract is total — every KeychainError variant flows through).
    func test_propagates_duplicateItem() async {
        let kc = ThrowingKeychain(error: .duplicateItem)
        let provider = AnthropicAPIKeyProvider.make(keychain: kc, item: .anthropic)

        do {
            _ = try await provider()
            XCTFail("provider must throw")
        } catch let err as KeychainError {
            XCTAssertEqual(err, .duplicateItem)
        } catch {
            XCTFail("expected KeychainError, got \(error)")
        }
    }

    // MARK: - Happy path (KP-4..KP-5)

    /// KP-4: when the keychain returns a value, the provider relays it.
    func test_returns_value_on_success() async throws {
        let kc = StaticKeychain(value: "sk-ant-test-12345")
        let provider = AnthropicAPIKeyProvider.make(keychain: kc, item: .anthropic)
        let key = try await provider()
        XCTAssertEqual(key, "sk-ant-test-12345")
    }

    /// KP-5: provider passes the requested item through unchanged. Locks
    /// in the contract that callers can target a different item without
    /// the builder substituting `.anthropic` silently.
    func test_uses_specified_item() async throws {
        let kc = CapturingKeychain(value: "_")
        let other = KeychainItem(service: "com.example.test", account: "test-account")
        let provider = AnthropicAPIKeyProvider.make(keychain: kc, item: other)
        _ = try await provider()
        XCTAssertEqual(kc.box.requested, [other])
    }

    /// KP-6: default `item` parameter is `.anthropic`.
    func test_default_item_is_anthropic() async throws {
        let kc = CapturingKeychain(value: "_")
        let provider = AnthropicAPIKeyProvider.make(keychain: kc)
        _ = try await provider()
        XCTAssertEqual(kc.box.requested, [.anthropic])
    }
}
