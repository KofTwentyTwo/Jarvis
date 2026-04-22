import XCTest
@testable import Keychain

final class PlaceholderTests: XCTestCase {
    func test_packageBuilds() {
        XCTAssertEqual(KeychainPackagePlaceholder.marker, "keychain-scaffolded")
    }
}
