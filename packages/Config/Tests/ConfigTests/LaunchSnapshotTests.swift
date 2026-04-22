import XCTest
@testable import Config

final class LaunchSnapshotTests: XCTestCase {
    func test_ollamaBaseURLAcceptsLocalhostAndLoopback() throws {
        for host in ["127.0.0.1", "localhost", "::1"] {
            let urlString = host == "::1" ? "http://[::1]:11434" : "http://\(host):11434"
            let json = """
            {"schemaVersion":1,"ollama":{"baseURL":"\(urlString)"},"applescript":{"confirmationRequired":true},"toolBlocklist":[],"confirmationPolicy":{"timeoutSeconds":60},"logging":{"fileLevel":"info","osLogLevel":"info"}}
            """.data(using: .utf8)!
            XCTAssertNoThrow(try JSONDecoder().decode(LaunchSnapshot.self, from: json),
                             "host \(host) should be accepted")
        }
    }

    func test_ollamaBaseURLMustBeLocalhost() {
        let json = """
        {"schemaVersion":1,"ollama":{"baseURL":"http://evil.com/"},"applescript":{"confirmationRequired":true},"toolBlocklist":[],"confirmationPolicy":{"timeoutSeconds":60},"logging":{"fileLevel":"info","osLogLevel":"info"}}
        """.data(using: .utf8)!
        XCTAssertThrowsError(try JSONDecoder().decode(LaunchSnapshot.self, from: json)) { error in
            // Decoder wraps invalidOllamaHost inside DecodingError.dataCorrupted.
            // We just assert that decoding fails; the exact wrapping is accepted.
            XCTAssertTrue(
                "\(error)".contains("invalidOllamaHost") || "\(error)".contains("evil.com"),
                "Expected invalidOllamaHost error, got: \(error)"
            )
        }
    }

    func test_featureFlagsNotInLaunchSnapshot() throws {
        // Introspect type: assert no stored property named 'featureFlags' exists.
        let mirror = Mirror(reflecting: try buildFixtureLaunchSnapshot())
        let names = mirror.children.compactMap { $0.label }
        XCTAssertFalse(names.contains("featureFlags"),
                       "featureFlags must NOT live in LaunchSnapshot (OBS-05). Found: \(names)")
    }

    private func buildFixtureLaunchSnapshot() throws -> LaunchSnapshot {
        let json = """
        {"schemaVersion":1,"ollama":{"baseURL":"http://127.0.0.1:11434"},"applescript":{"confirmationRequired":true},"toolBlocklist":[],"confirmationPolicy":{"timeoutSeconds":60},"logging":{"fileLevel":"info","osLogLevel":"info"}}
        """.data(using: .utf8)!
        return try JSONDecoder().decode(LaunchSnapshot.self, from: json)
    }
}
