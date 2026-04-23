import XCTest
@testable import Config

final class SchemaMigratorTests: XCTestCase {
    func test_currentVersionIsOne() {
        XCTAssertEqual(SchemaMigrator.currentVersion, 1)
    }

    func test_v1ToV1IsPassThrough() throws {
        let data = Data("{\"schemaVersion\":1}".utf8)
        let result = try SchemaMigrator.migrate(data, from: 1, to: 1)
        XCTAssertEqual(result, data)
    }

    func test_futureSchemaThrows() {
        let data = Data("{\"schemaVersion\":2}".utf8)
        XCTAssertThrowsError(try SchemaMigrator.migrate(data, from: 2, to: 1)) { error in
            // WR-04: carries both `have` (user's version) and `supports`
            // (this build's current version) so the error message isn't
            // ambiguous about which number means what.
            XCTAssertEqual(error as? ConfigError, .futureSchema(have: 2, supports: 1))
        }
    }

    func test_unknownV0ToV1Throws() {
        let data = Data("{\"schemaVersion\":0}".utf8)
        XCTAssertThrowsError(try SchemaMigrator.migrate(data, from: 0, to: 1)) { error in
            XCTAssertEqual(error as? ConfigError, .unknownSchemaVersion(have: 0, supports: 1))
        }
    }
}
