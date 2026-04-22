import XCTest
@testable import Keychain

final class KeychainTests: XCTestCase {
    private var testItem: KeychainItem!
    private let store = SystemKeychainStore()

    override func setUp() {
        super.setUp()
        // Random account so parallel test runs and real user Keychain state don't collide.
        testItem = KeychainItem(
            service: "com.kingsrook.jarvis.tests",
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
        XCTAssertEqual(KeychainItem.anthropic.service, "com.kingsrook.jarvis")
        XCTAssertEqual(KeychainItem.anthropic.account, "anthropic")
    }
}
