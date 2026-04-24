import Foundation
import AgentCore
import Config
import Replay
@testable import AgentOrchestrator

/// Closure-backed `ToolDispatcher` for tests.
final class StubToolDispatcher: ToolDispatcher, @unchecked Sendable {
    let dispatchHandler: @Sendable (ToolUseRequest) async throws -> Data
    let confirmHandler: @Sendable (String) -> Bool

    init(
        dispatch: @escaping @Sendable (ToolUseRequest) async throws -> Data = { _ in Data() },
        requiresConfirmation: @escaping @Sendable (String) -> Bool = { _ in false }
    ) {
        self.dispatchHandler = dispatch
        self.confirmHandler = requiresConfirmation
    }

    func dispatch(toolUse: ToolUseRequest) async throws -> Data {
        try await dispatchHandler(toolUse)
    }

    func requiresConfirmation(toolName: String) -> Bool {
        confirmHandler(toolName)
    }
}

/// One-shot temp directory for an isolated ReplayLog DB.
struct TempReplayHome {
    let directory: URL
    let dbURL: URL

    static func make() -> TempReplayHome {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("jarvis-orch-tests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return TempReplayHome(directory: dir, dbURL: dir.appendingPathComponent("replay.db"))
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: directory)
    }
}

/// Build a `PerTurnSnapshot` with sensible defaults — the orchestrator only
/// reads `provider`. `PerTurnSnapshot` exposes only `Codable` init, so we
/// round-trip through JSON like `LaunchSnapshotTests` does.
func makePerTurnSnapshot(provider: ProviderSelection = .anthropic) -> PerTurnSnapshot {
    let providerString = provider.rawValue
    let json = """
    {"schemaVersion":1,"provider":"\(providerString)","tts":{"tier":"tier1"},"stt":{"whisperKitFallback":false},"featureFlags":{}}
    """.data(using: .utf8)!
    return try! JSONDecoder().decode(PerTurnSnapshot.self, from: json)
}

/// Build a minimal `LaunchSnapshot` for tests. `LaunchSnapshot` only exposes
/// the synthesized `Codable` init, so we round-trip through JSON.
func makeLaunchSnapshot() -> LaunchSnapshot {
    let json = """
    {"schemaVersion":1,"ollama":{"baseURL":"http://127.0.0.1:11434"},"applescript":{"confirmationRequired":true},"toolBlocklist":[],"confirmationPolicy":{"timeoutSeconds":60},"logging":{"fileLevel":"info","osLogLevel":"info"}}
    """.data(using: .utf8)!
    return try! JSONDecoder().decode(LaunchSnapshot.self, from: json)
}

func makeConfigStore(provider: ProviderSelection = .anthropic) -> ConfigStore {
    ConfigStore(launch: makeLaunchSnapshot(), initial: makePerTurnSnapshot(provider: provider))
}

/// Tiny thread-safe counter for test closures that need to count invocations
/// across @Sendable closures (Swift 6 strict concurrency disallows captured
/// `var` mutation inside @Sendable).
actor TestCounter {
    private(set) var value: Int = 0
    func inc() { value += 1 }
    func get() -> Int { value }
}
