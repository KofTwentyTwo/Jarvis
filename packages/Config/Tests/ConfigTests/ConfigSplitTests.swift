import XCTest
@testable import Config

final class ConfigSplitTests: XCTestCase {
    func test_securityKeysInLaunchOnly() throws {
        let launch = try ConfigTestFixtures.launch()
        let mirror = Mirror(reflecting: launch)
        let names = Set(mirror.children.compactMap { $0.label })
        for key in ["ollama", "applescript", "toolBlocklist", "confirmationPolicy", "logging"] {
            XCTAssertTrue(names.contains(key), "LaunchSnapshot missing security key: \(key)")
        }
    }

    func test_nonSecurityKeysInPerTurnOnly() throws {
        let perTurn = try ConfigTestFixtures.perTurn(flags: [:])
        let mirror = Mirror(reflecting: perTurn)
        let names = Set(mirror.children.compactMap { $0.label })
        for key in ["provider", "tts", "stt", "featureFlags"] {
            XCTAssertTrue(names.contains(key), "PerTurnSnapshot missing key: \(key)")
        }
    }

    func test_noSkipAllowlistKey() {
        // SEC-08: reflect over AppleScriptPolicy and assert no allowlist-like field exists.
        let policy = AppleScriptPolicy(confirmationRequired: true)
        let mirror = Mirror(reflecting: policy)
        let names = mirror.children.compactMap { ($0.label ?? "").lowercased() }
        for forbidden in ["skipallowlist", "skip_allowlist", "allowlist", "bypass", "regex"] {
            XCTAssertFalse(names.contains(forbidden),
                           "SEC-08 violation: AppleScriptPolicy has forbidden field '\(forbidden)'")
        }
    }
}
