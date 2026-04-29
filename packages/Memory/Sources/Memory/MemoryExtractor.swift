import Foundation
import AgentCore
import JarvisLogging
import Logging

/// mem0 ADD/UPDATE/NOOP extractor (MEM-04). Single-turn driver of
/// `LLMProvider.stream` — collects exactly one `ToolUseRequest` for
/// `apply_memory_ops` and decodes it into `[MemoryOp]`.
///
/// Per RESEARCH §5 and D-03, the model is `qwen2.5-coder:32b` (Qwen3 is
/// banned per RESEARCH-DELTAS D3 — Ollama tool-calling broken). The
/// extractor asks for tool-only output via a system prompt directive and
/// uses `toolChoice .auto` so the model can also decide NOOP.
///
/// **Single-turn only.** No outer loop, no cap recovery, no
/// UntrustedWrapper. If the model fails to call the tool, the extractor
/// returns an empty array (treated as NOOP by callers).
public actor MemoryExtractor {

    private let provider: any LLMProvider
    private let model: ModelID
    private let logger: Logger

    public init(
        provider: any LLMProvider,
        model: ModelID = .qwen25coder32b
    ) {
        self.provider = provider
        self.model = model
        self.logger = Logger(label: "memory.extractor")
    }

    /// Extract memory ops for one turn pair. Returns the parsed ops list;
    /// empty list means "model decided NOOP or returned no tool call".
    public func extract(
        userText: String,
        assistantText: String,
        priorActiveFacts: [Fact]
    ) async throws -> [MemoryOp] {
        let systemPrompt = MemoryPrompts.mem0System(priorFacts: priorActiveFacts)
        let userPrompt = MemoryPrompts.format(user: userText, assistant: assistantText)

        let messages: [LLMMessage] = [
            LLMMessage(role: .system, content: [.text(systemPrompt)]),
            LLMMessage(role: .user, content: [.text(userPrompt)]),
        ]

        let stream = provider.stream(
            messages: messages,
            tools: [MemoryTools.applyMemoryOps],
            toolChoice: .auto,
            model: model,
            maxOutputTokens: 1024,
            cacheHints: nil
        )

        var collectedToolCall: ToolUseRequest?
        for try await event in stream {
            switch event {
            case .toolUseRequested(let req):
                if req.name == MemoryTools.toolName {
                    collectedToolCall = req
                }
            case .messageStop:
                break
            default:
                continue
            }
        }

        guard let toolCall = collectedToolCall else {
            logger.debug("extractor: no apply_memory_ops tool call — treating as NOOP")
            return []
        }
        return try MemoryOp.parseApplyMemoryOps(toolCall.argsJSON)
    }
}
