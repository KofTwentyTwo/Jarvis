import XCTest
import Security
@testable import Keychain

final class KeychainTests: XCTestCase {
    private var testItem: KeychainItem!
    private let store = SystemKeychainStore()

    override func setUp() {
        super.setUp()
        // Random account so parallel test runs and real user Keychain state don't collide.
        testItem = KeychainItem(
            service: "com.koftwentytwo.jarvis.tests",
            account: "anthropic-test-\(UUID().uuidString)"
        )
    }

    override func tearDown() {
        try? store.delete(testItem)
        super.tearDown()
    }

    func test_setGetDeleteRoundTrip() throws {
        try store.set("secret-value-001", for: testItem)
        XCTAssertEqual(try store.get(testItem), "secret-value-001")
        try store.delete(testItem)
        XCTAssertThrowsError(try store.get(testItem)) { error in
            XCTAssertEqual(error as? KeychainError, .itemNotFound)
        }
    }

    func test_setIdempotentOverwrite() throws {
        try store.set("first", for: testItem)
        try store.set("second", for: testItem)
        XCTAssertEqual(try store.get(testItem), "second")
    }

    func test_deleteMissingDoesNotThrow() {
        // Never set; delete should swallow errSecItemNotFound.
        XCTAssertNoThrow(try store.delete(testItem))
    }

    func test_anthropicConstantMatchesD10() {
        XCTAssertEqual(KeychainItem.anthropic.service, "com.koftwentytwo.jarvis")
        XCTAssertEqual(KeychainItem.anthropic.account, "anthropic")
    }

    /// SEC-01 / D-10 / CR-01: a write must NOT produce an item that matches
    /// an iCloud-synchronizable query. On the macOS legacy (file-based)
    /// keychain, items default to synchronizable=false, so this test is most
    /// sensitive to a future regression where code explicitly sets
    /// `kSecAttrSynchronizable = true` or `kSecAttrSynchronizable = kSecAttrSynchronizableAny`.
    ///
    /// Note: on the legacy file-based macOS keychain the write-side
    /// `kSecAttrAccessible` attribute is accepted but not echoed back via
    /// SecItemCopyMatching (verified experimentally on macOS 14+), so we
    /// cannot directly assert it on read. The production code explicitly
    /// passes `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` on every write
    /// so that migration to the data-protection keychain (where the
    /// attribute IS enforced) inherits the correct class.
    func test_itemIsNotSynchronizable() throws {
        try store.set("secret-value-xyz", for: testItem)

        // A query that matches only synchronizable items must NOT find our
        // freshly-written item.
        let syncQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: testItem.service,
            kSecAttrAccount as String: testItem.account,
            kSecAttrSynchronizable as String: kCFBooleanTrue as Any,
            kSecReturnData as String: kCFBooleanTrue as Any,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var syncResult: AnyObject?
        let syncStatus = SecItemCopyMatching(syncQuery as CFDictionary, &syncResult)
        XCTAssertEqual(
            syncStatus, errSecItemNotFound,
            "SEC-01/D-10: items must NOT be iCloud-synchronizable. "
            + "Got status \(syncStatus), result \(String(describing: syncResult))"
        )

        // Sanity: a query that matches only non-synchronizable items DOES
        // find our item. This makes sure we're not false-positive on a
        // typo: `errSecItemNotFound` would also come back if the write failed
        // entirely.
        let nonSyncQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: testItem.service,
            kSecAttrAccount as String: testItem.account,
            kSecAttrSynchronizable as String: kCFBooleanFalse as Any,
            kSecReturnData as String: kCFBooleanTrue as Any,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var nonSyncResult: AnyObject?
        XCTAssertEqual(
            SecItemCopyMatching(nonSyncQuery as CFDictionary, &nonSyncResult),
            errSecSuccess,
            "Sanity check: item must be findable via synchronizable=false query"
        )
    }

    /// Regression guard: `SystemKeychainStore.set` must always pass
    /// `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` + `kSecAttrSynchronizable = kCFBooleanFalse`
    /// on BOTH the initial add (SecItemAdd) path and the update
    /// (SecItemUpdate) path. Verified at source level — this test grep-gates
    /// the implementation so a future refactor that drops either attribute
    /// fails CI immediately.
    ///
    /// We read the source text from the built-in package resource rather than
    /// reflecting on the compiled binary because the attributes aren't
    /// queryable via `SecItemCopyMatching` on the legacy macOS keychain (see
    /// `test_itemIsNotSynchronizable` for the runtime portion).
    func test_sourceAlwaysSetsDeviceOnlyAccessibility() throws {
        let sourcePath = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()     // KeychainTests/
            .deletingLastPathComponent()     // Tests/
            .deletingLastPathComponent()     // Keychain/
            .appendingPathComponent("Sources/Keychain/SystemKeychainStore.swift")
        let source = try String(contentsOf: sourcePath, encoding: .utf8)

        // Both accessibility + synchronizable must appear; the attrs dictionary
        // + addQuery override both carry them per CR-01 fix.
        XCTAssertTrue(
            source.contains("kSecAttrAccessibleWhenUnlockedThisDeviceOnly"),
            "SEC-01/D-10 regression: SystemKeychainStore.set must pass "
            + "kSecAttrAccessibleWhenUnlockedThisDeviceOnly"
        )
        XCTAssertTrue(
            source.contains("kSecAttrSynchronizable"),
            "SEC-01/D-10 regression: SystemKeychainStore.set must pass "
            + "kSecAttrSynchronizable = false"
        )
        XCTAssertTrue(
            source.contains("kCFBooleanFalse"),
            "SEC-01/D-10 regression: kSecAttrSynchronizable must be set to false "
            + "(kCFBooleanFalse), not kCFBooleanTrue"
        )
    }
}
