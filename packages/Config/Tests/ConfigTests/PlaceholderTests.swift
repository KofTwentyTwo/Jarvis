import XCTest
@testable import Config

final class PlaceholderTests: XCTestCase {
    func test_packageBuilds() {
        XCTAssertEqual(ConfigPackagePlaceholder.marker, "config-scaffolded")
    }
}
