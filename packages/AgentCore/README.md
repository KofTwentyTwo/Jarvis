# AgentCore

The agent loop, LLM provider protocol, and concrete providers. Four library products: shared types (`AgentCore`), the orchestrator (`AgentOrchestrator`), and two providers (`AnthropicProvider`, `OllamaProvider`).

## Key public types

| Type | Purpose |
|------|---------|
| `LLMProvider` (protocol) | Provider-agnostic streaming contract — returns `AsyncThrowingStream<LLMEvent, Error>` |
| `LLMEvent` | Stream event union — `tokenDelta`, `thinkingDelta`, `toolUseRequested`, `usage`, `messageStop` |
| `LLMMessage` | Provider-neutral chat message (role + content blocks, including `ImageBlock`) |
| `ToolSchema` / `ToolChoice` | Tool advertising + tool-choice discipline (`auto`, `none`, `required`) |
| `ImageBlock` | Multimodal extension (Plan 07-05 / D-18); base64 + media type |
| `ModelID` | Strong-typed model identifier (`claude-opus-4-7`, `qwen2.5-coder:32b`) |
| `TurnID` / `TurnNonce` | Turn identity (`TurnID` on bus + replay; `TurnNonce` for SEC-06, never on bus) |
| `CacheHints` | `eligibleForSystemPrompt` (≥1024 tokens), `extended-cache-ttl` beta header guard |
| `UntrustedWrapper` | Prompt-injection isolation around tool results |
| `ToolResultPacker` | 8 KB cap on model-facing tool result content (Opus 4.7 footgun) |
| `BoundedAsyncChannel` | `dropOldest`-policy bounded channel for orch → replay events |
| `AnthropicProvider` | Streaming SSE Opus 4.7 via Anthropic Messages API |
| `OllamaProvider` | Native NDJSON `/api/chat` + OpenAI-compat `/v1/chat/completions` |
| `AgentOrchestrator` | Actor — turn-lifecycle owner, tool dispatch, cap-recovery, retry |
| `OrchestratorEvent` | One-consumer event stream — state changes, tokens, tool starts/ends |

## Depends on

`Keychain`, `Replay`, `Vision`, `Logging`, `Config`. External: `swift-log`.

## Used by

`App/AppDelegate`, `App/Voice/VoiceOrchestratorAdapter.swift`, `App/MCPBusGatewayAdapter.swift`, `packages/Memory`, `packages/Vision`, `packages/Harness`, `packages/DevOverlay`, `packages/MCP`.

## Key invariants / contracts

- **`LLMProvider` cancellation through `Task.isCancelled`** — provider task closes the underlying transport on consumer cancel.
- **Tool-choice mandatory.** Cap-recovery turns pass `.none` (Anthropic `{"type":"none"}`; Ollama drops `tools` array entirely).
- **`turnNonce` never on the bus or in any `OrchestratorEvent`** (SEC-06).
- **Tool result content capped at 8 KB before model.** Full bytes still go to replay.
- **`extended-cache-ttl` requires the beta header** AND `ttl: "1h"` on `cache_control`. Without the header, 1h is silently ignored.
- **Cache hints gated on prompts ≥1024 tokens** (`CacheHints.eligibleForSystemPrompt`).
- **Anthropic SSE: close on `message_stop`, not `message_delta`.** Swallow `ping`. Route `thinking_delta` to its own case. Treat `stop_reason: "refusal"` first-class. Emit `partial_tool_use_at_disconnect` on mid-delta termination.
- **Ollama NDJSON: `tool_calls` arrive on the chunk preceding `done: true`** — decoder reads `tool_calls` whenever seen, never gates on `done`.
- **One-consumer invariant on `OrchestratorEvent` stream** — `scripts/check-orchestrator-events-single-consumer.sh`.

## Tests

19 swift-testing + 72 XCTest. Includes SSE fixture corpus (`packages/Harness/Sources/Harness/Corpus/SSEFixtureCorpus.swift`), NDJSON fixture corpus, tool-cap-recovery scenarios, retry-budget tests. Live-network tests gated by `JARVIS_REAL_MODELS=1`.

## Notable files

- `Sources/AgentCore/LLMProvider.swift` — the core protocol + multimodal overload
- `Sources/AgentOrchestrator/AgentOrchestrator.swift` — the turn-lifecycle actor
- `Sources/AnthropicProvider/SSEDecoder.swift` — SSE parser with all the footgun cases
- `Sources/OllamaProvider/NDJSONDecoder.swift` — `/api/chat` decoder; tool_calls-before-done
- `Sources/AgentCore/CacheHints.swift` — Track A streamTruncated fix
