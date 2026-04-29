import XCTest
@testable import Memory

/// Scaffold marker so the MemoryTests target has at least one source file.
/// Real tests land in Tasks 2 (EmbeddingDimSymbolTests) and 3 (MemorySchemaTests
/// + MemoryStoreTests) of Plan 07-01.
final class MemoryTestsScaffold: XCTestCase {
    func testTargetBuilds() {
        XCTAssertTrue(true)
    }
}
