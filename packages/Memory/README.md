# Memory

Long-term fact store + extraction pipeline. SQLite (FTS5 + sqlite-vec) at `~/Library/Application Support/Jarvis/jarvis.db`; mem0-style ADD/UPDATE/NOOP extraction; hybrid keyword + vector search via Reciprocal Rank Fusion.

> **Functional state.** Memory is code-complete but functionally OFF until `vec0.dylib` ships (Track D-5/D-6 — user environment work) and `ollama pull nomic-embed-text` runs (D-7). `installMemory` degrades gracefully — extractor + orchestrator + coordinator construct even when `MemoryStore` init throws.

## Key public types

| Type | Purpose |
|------|---------|
| `MemoryStore` (actor) | The only writer of `jarvis.db`. Opens with WAL, loads `vec0.dylib`, runs migrations |
| `MemoryExtractionOrchestrator` (actor) | Bounded-channel + serial-drain extraction Task |
| `MemoryExtractionCoordinator` | AppDelegate-side coordinator that listens to `OrchestratorEvent.turnEnd` |
| `MemoryExtractor` | Calls Qwen 2.5-Coder via Ollama; emits ADD / UPDATE(supersedes:) / NOOP |
| `MemoryPrompts` | Prompt templates for the extractor |
| `HybridSearch` (actor) | FTS5 + vec0 RRF SQL; emits `ReplayEvent.memoryRetrieval` per fact |
| `OllamaEmbeddingClient` | `nomic-embed-text` 768-dim embeddings |
| `Fact` / `FactRef` / `ExtractionJob` | Plain-data types |
| `MemoryEvent` | Stream events — `factAdded`, `factUpdated`, `factForgotten`, `retrieval` |
| `SessionHistory` | Session-scoped recent-turn browse (TEXT-03; separate from hybrid search) |
| `MemoryReplaySink` (protocol) | Test seam over `Replay.ReplayLog` |
| `PriorFactsLookup` | Closure type for D-3 — supplies recent active facts to the extractor |

## Depends on

`AgentCore`, `Replay`, `Logging`. External: `swift-log`, system SQLite (with custom `libsqlite3.dylib` carrying `SQLITE_ENABLE_LOAD_EXTENSION=1` once D-5 ships).

## Used by

`App/AppDelegate.installMemory`, `App/MCP/InProcessMemoryAdapters.swift` (bridges to MCP `SearchMemoryTool` / `ForgetFactTool`).

## Key invariants / contracts

- **`MemoryStore` is the only writer.** All writes go through actor methods.
- **Bounded extraction channel.** `BoundedAsyncChannel<ExtractionJob>(capacity: 32, policy: .dropOldest)`. Producers (turnEnd) never block.
- **Single-consumer drain.** One serial Task per orchestrator instance.
- **Single-emission grep gates.** `scripts/check-single-memory-mutated-emit.sh` + `check-single-memory-used-emit.sh`. `MemoryStore.recordRetrieval` is the only `memoryRetrieval` emit site.
- **Embedding dim sourced from `Constants.swift`.** `scripts/check-embedding-dim-literal.sh` forbids hand-typed `768`.
- **Temporal validity preserved.** UPDATE supersedes by setting `valid_to` on the prior fact + inserting a new one. No DELETE in the happy path.
- **D-3: priorFacts wiring.** `MemoryExtractionOrchestrator.process(_:)` calls `priorFactsLookup` (default `emptyPriorFactsLookup` for back-compat); production wires `MemoryStore.recentActiveFacts(limit: 50)`.
- **T-06-05-03 analog.** `HybridSearch` does NOT log raw query text at debug level (P2-12 fix).

## Tests

87 XCTest (19 skipped — vec0/Ollama gating). Includes the `RememberBrutusEndToEndTests` regression scenario (Track D-4) that proves extraction → store → search end-to-end with fakes.

## Notable files

- `Sources/Memory/MemoryStore.swift` — actor + SQLite + vec0 loader
- `Sources/Memory/MemoryExtractionOrchestrator.swift` — bounded-channel extraction
- `Sources/Memory/HybridSearch.swift` — FTS5 + vec0 RRF
- `Sources/Memory/MemoryExtractor.swift` — Qwen extractor
- `Sources/Memory/MemoryQueries.swift` — SQL definitions
