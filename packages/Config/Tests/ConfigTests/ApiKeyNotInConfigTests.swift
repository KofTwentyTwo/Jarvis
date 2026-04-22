import XCTest
@testable import Config

final class ApiKeyNotInConfigTests: XCTestCase {
    func test_apiKeyNotInConfigJSON() throws {
        let launch = try ConfigTestFixtures.launch()
        let encoded = try JSONEncoder().encode(launch)
        let json = String(data: encoded, encoding: .utf8)!.lowercased()
        for forbidden in ["apikey", "\"api_key\"", "anthropic_key", "\"key\"", "sk-ant-"] {
            XCTAssertFalse(json.contains(forbidden),
                           "LaunchSnapshot JSON encoding contains forbidden field '\(forbidden)' — SEC-01 violation")
        }
    }
}
