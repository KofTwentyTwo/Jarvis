import Foundation

/// Plan 10-01 / SELF-03.
///
/// Returns a point-in-time snapshot of Jarvis's runtime self-state. D-11
/// fields verbatim. The App-side `SelfStateAdapter` composes the result
/// from `Bundle.main.infoDictionary`, `ProcessInfo`, the active
/// `LLMProvider` identity, and closures that hop into the
/// `VoiceController` / `TTSEngineActor` actors.
public protocol SelfStateDispatching: Sendable {
    func getSelfState() async -> SelfState
}

/// Tool-boundary projection of the runtime self-state (D-11).
public struct SelfState: Sendable, Codable, Equatable {
    public let appName: String
    public let appVersion: String
    public let buildMode: String          // "debug" | "release"
    public let pid: Int
    public let uptimeSeconds: Int          // app uptime, NOT host uptime
    public let llmProvider: String         // "anthropic" | "ollama"
    public let llmModel: String            // e.g., "claude-opus-4-7"
    public let ttsTier: String             // "tier1" | "tier2"
    public let sttBackend: String          // "speechAnalyzer" | "whisperKit"
    public let wakeWordMuted: Bool
    public let voiceLoopState: String      // "idle" | "listening" | "thinking" | "speaking" | ...

    public init(
        appName: String,
        appVersion: String,
        buildMode: String,
        pid: Int,
        uptimeSeconds: Int,
        llmProvider: String,
        llmModel: String,
        ttsTier: String,
        sttBackend: String,
        wakeWordMuted: Bool,
        voiceLoopState: String
    ) {
        self.appName = appName
        self.appVersion = appVersion
        self.buildMode = buildMode
        self.pid = pid
        self.uptimeSeconds = uptimeSeconds
        self.llmProvider = llmProvider
        self.llmModel = llmModel
        self.ttsTier = ttsTier
        self.sttBackend = sttBackend
        self.wakeWordMuted = wakeWordMuted
        self.voiceLoopState = voiceLoopState
    }
}

/// `get_self_state` MCP in-process tool. D-10: explicit
/// `requiresConfirmation = false`.
public struct GetSelfStateTool: InProcessTool {

    public let name: String = "get_self_state"
    public let toolDescription: String = """
    Returns a point-in-time snapshot of Jarvis's own runtime state — app \
    version, build mode (debug/release), pid, uptime, active LLM provider \
    and model, TTS tier, STT backend, wake-word mute flag, and current \
    voice-loop state. Call this tool when the user asks what model is \
    running, whether wake-word is muted, how long the app has been up, or \
    any question about Jarvis's own configuration.
    """
    public let requiresConfirmation: Bool = false

    public var schemaJSON: Data { Self.schema }

    private static let schema: Data = {
        let s: [String: Any] = [
            "type": "object",
            "properties": [:] as [String: Any],
            "required": [] as [String],
        ]
        return (try? JSONSerialization.data(withJSONObject: s, options: [.sortedKeys])) ?? Data()
    }()

    private let dispatcher: any SelfStateDispatching

    public init(dispatcher: any SelfStateDispatching) {
        self.dispatcher = dispatcher
    }

    public func call(args _: Data) async throws -> Data {
        let state = await dispatcher.getSelfState()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(state)
    }
}
