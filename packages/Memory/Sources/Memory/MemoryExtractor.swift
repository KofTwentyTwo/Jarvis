import Foundation
import AgentCore
import JarvisLogging
import Logging

/// mem0 ADD/UPDATE/NOOP extractor (MEM-04). Single-turn driver of
/// `LLMProvider.stream` — collects exactly one `ToolUseRequest` for
/// `apply_memory_ops` and decodes it into `[MemoryOp]`.
///
/// Model default updated 2026-05-11: `qwen3.6:latest` after an empirical
/// retest showed Qwen3.6 tool-calling works correctly in Ollama (see
/// `ModelID.qwen36` doc). The original April 2026 CLAUDE.md note banning
/// Qwen3 was correct at the time; upstream has since closed the relevant
/// issues. The extractor's single-turn, single-tool flow is the lowest-
/// risk place to validate the newer model — no cap recovery, no multi-
/// turn chains. The agent loop remains pinned to `qwen2.5-coder:32b-
/// instruct-q8_0` until streaming + cap-recovery on Qwen3.6 is verified.
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
        model: ModelID = .qwen36
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
