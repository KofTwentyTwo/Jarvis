import XCTest
@testable import Config

final class PerTurnSnapshotTests: XCTestCase {
    func test_featureFlagsArePresentInPerTurnSnapshot() throws {
        let json = """
        {"schemaVersion":1,"provider":"anthropic","tts":{"tier":"tier1"},"stt":{"whisperKitFallback":false},"featureFlags":{"orpheusTTSEnabled":true}}
        """.data(using: .utf8)!
        let snapshot = try JSONDecoder().decode(PerTurnSnapshot.self, from: json)
        // WR-11: canonical typed-enum API.
        XCTAssertTrue(snapshot.featureFlags.isEnabled(.orpheusTTSEnabled))
        // WR-11: the dynamic string-keyed path remains for dev overlay use.
        XCTAssertFalse(snapshot.featureFlags.isEnabledDynamic("nonexistent"))
    }

    func test_featureFlagAppliesNextSubmit() async throws {
        // Mock orchestrator: reads perTurn from ConfigStore on each 'submit'.
        let launch = try ConfigTestFixtures.launch()
        let initial = try ConfigTestFixtures.perTurn(flags: [:])
        let store = ConfigStore(launch: launch, initial: initial)
        let isEnabledBefore = await store.perTurn().featureFlags.isEnabled(.orpheusTTSEnabled)
        XCTAssertFalse(isEnabledBefore)

        let next = try ConfigTestFixtures.perTurn(flags: ["orpheusTTSEnabled": true])
        await store.updatePerTurn(next)

        let isEnabledAfter = await store.perTurn().featureFlags.isEnabled(.orpheusTTSEnabled)
        XCTAssertTrue(isEnabledAfter)
    }

    /// WR-11: the typed-enum lookup key matches the `rawValue` that the
    /// decoder expects in JSON. This is the regression guard — if someone
    /// renames `orpheusTTSEnabled` to `orpheusTtsEnabled` the decoded flag
    /// no longer matches and this test fails.
    func test_featureFlagEnumRawValueMatchesDecoder() throws {
        XCTAssertEqual(FeatureFlag.orpheusTTSEnabled.rawValue, "orpheusTTSEnabled")
        XCTAssertEqual(FeatureFlag.whisperKitSTTEnabled.rawValue, "whisperKitSTTEnabled")
    }
}

enum ConfigTestFixtures {
    static func launch() throws -> LaunchSnapshot {
        let json = """
        {"schemaVersion":1,"ollama":{"baseURL":"http://127.0.0.1:11434"},"applescript":{"confirmationRequired":true},"toolBlocklist":[],"confirmationPolicy":{"timeoutSeconds":60},"logging":{"fileLevel":"info","osLogLevel":"info"}}
        """.data(using: .utf8)!
        return try JSONDecoder().decode(LaunchSnapshot.self, from: json)
    }
    static func perTurn(flags: [String: Bool]) throws -> PerTurnSnapshot {
        let flagsJSON = flags.isEmpty ? "{}" : String(data: try JSONEncoder().encode(flags), encoding: .utf8)!
        let json = """
        {"schemaVersion":1,"provider":"anthropic","tts":{"tier":"tier1"},"stt":{"whisperKitFallback":false},"featureFlags":\(flagsJSON)}
        """.data(using: .utf8)!
        return try JSONDecoder().decode(PerTurnSnapshot.self, from: json)
    }
}
