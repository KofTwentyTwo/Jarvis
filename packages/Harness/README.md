# Harness

The eval harness + test fixtures + the `jarvis-eval` CLI executable. Not shipped in the user-facing app — it's the infrastructure for "run after significant changes" eval scenarios.

## Key public types

| Type | Purpose |
|------|---------|
| `MockLLMProvider` | Records every prompt + tool-call exchange; scriptable response sequences |
| `ReplayMCPAdapter` | Replays a recorded MCP transcript against a fresh dispatcher |
| `MockHelperBuilder` | Generates fake MCP helper bundles for crash/restart tests |
| `CapturingURLProtocol` | Records HTTP traffic for SSE/NDJSON fixture capture |
| `FDLeakDetector` | Asserts no file descriptors leaked across a test boundary (SEC-08) |
| `*Corpus` | Fixture corpora (SSE, NDJSON, wake-hysteresis, injection, checklist) |
| `*Runner` | Per-corpus eval runners (`SSEFixtureRunner`, `WakeHysteresisRunner`, etc.) |
| `DriftClassifier` / `DriftReport` | Compare observed vs expected results across runs |

## Depends on

`Logging`, `Config`, `AgentCore`, `Replay`, `MCP`, `Voice`, `Memory`, `DevOverlay`. External: `swift-argument-parser`, `swift-log`, MCP SDK, `Yams`.

## Used by

The `jarvis-eval` executable target; not imported by `App/`.

## Key invariants / contracts

- **Corpora are versioned + checksummed.** Fixture changes require deliberate updates (not silent drift).
- **Local-model eval pinned to `qwen2.5-coder:32b`** — Qwen3 / Gemma 4 tool-calling broken in Ollama as of April 2026.
- **Live tests gated by env flags.** `JARVIS_REAL_MODELS=1`, `JARVIS_REAL_CAMERA=1`. Default runs are offline + deterministic.
- **`MockLLMProvider` records calls** (Mock taxonomy per CLAUDE.md §Test naming conventions).

## Tests

The harness package itself has its own XCTests (smoke tests on the runners + corpus loaders). Most of the codebase's eval coverage is invoked _through_ the harness, not _of_ the harness.

## Notable files

- `Sources/jarvis-eval/main.swift` — CLI entry point
- `Sources/Harness/Adapters/MockLLMProvider.swift` — the canonical mock LLM
- `Sources/Harness/Runners/SSEFixtureRunner.swift` — Anthropic SSE replay runner
- `Sources/Harness/Runners/MCPCrashRunner.swift` — helper-restart scenarios
- `Sources/Harness/Corpus/SSEFixtureCorpus.swift` — recorded SSE traces
