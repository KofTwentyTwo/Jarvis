import XCTest
@testable import Shell

final class PlaceholderTests: XCTestCase {
    func test_packageBuilds() {
        XCTAssertEqual(ShellPackagePlaceholder.marker, "shell-scaffolded")
    }
}
