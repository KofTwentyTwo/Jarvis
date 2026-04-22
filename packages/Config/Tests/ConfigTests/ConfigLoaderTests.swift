import XCTest
@testable import Config

final class ConfigLoaderTests: XCTestCase {
    func test_loadDefaultConfigFromBundle() throws {
        guard let url = ConfigLoader.bundledDefaultConfigURL() else {
            XCTFail("Bundled default-config.json missing"); return
        }
        let (launch, perTurn) = try ConfigLoader.loadSnapshots(from: url)
        XCTAssertEqual(launch.schemaVersion, 1)
        XCTAssertEqual(perTurn.schemaVersion, 1)
        XCTAssertEqual(launch.ollama.baseURL.host, "127.0.0.1")
        XCTAssertEqual(perTurn.provider, .anthropic)
    }

    func test_malformedConfigThrowsMalformed() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("bad-\(UUID()).json")
        try Data("{not-valid-json".utf8).write(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }

        XCTAssertThrowsError(try ConfigLoader.loadSnapshots(from: tmp)) { error in
            if case .malformed = error as? ConfigError {
                // OK
            } else {
                XCTFail("Expected ConfigError.malformed, got: \(error)")
            }
        }
    }
}
