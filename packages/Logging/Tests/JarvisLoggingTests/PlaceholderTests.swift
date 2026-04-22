import XCTest
@testable import JarvisLogging

final class PlaceholderTests: XCTestCase {
    func test_packageBuilds() {
        XCTAssertEqual(JarvisLoggingPackagePlaceholder.marker, "logging-scaffolded")
    }
}
