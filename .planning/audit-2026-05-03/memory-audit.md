# Memory Subsystem Audit — 2026-05-03

**TL;DR — Grade: F.** The Memory subsystem is dormant on every cold launch and has been since it was first written. The agent cannot remember anything. Saying "remember my dog's name is Brutus" today does nothing — no fact is persisted, no extraction LLM is ever called in production, and the MCP tools for `search_memory` / `forget_fact` are not registered with the runtime. Roughly half of the Memory test suite is hard-skipped behind env flags that nobody runs. The other half tests stubs of stubs. The single piece that demonstrably works in CI is the embedding HTTP client's URL-shape unit tests.

---

## 1. SQLite store init — REAL, AND PERMANENTLY BROKEN

`packages/Memory/Sources/Memory/MemoryStore.swift:368-434`. The symbol-stripped `libsqlite3` issue is real, by design, and unfixable through the path taken.

What the code does (lines 391-393): `dlsym(RTLD_DEFAULT, "sqlite3_enable_load_extension")`. Apple strips that symbol from `MacOSX.sdk/usr/lib/libsqlite3.tbd`. `dlsym` returns NULL. `MemoryError.vecLoadFailed` is thrown, `init` aborts, and `AppDelegate.installMemory` (`App/AppDelegate.swift:797-808`) catches the throw and returns early. Every `MemoryStore?` ivar stays nil for the process lifetime. That is the warning the user sees on every launch.

**Is there in-progress work to fix it?** No.
- `packages/Memory/Sources/Memory/Resources/PLACEHOLDER.txt` literally contains the text "Reserved for vec0.dylib … landed in a future ops/build plan."
- `MemoryStore.swift:380` says "A future ops/build plan will bundle a custom-built libsqlite3.dylib … at that point this dlsym pathway will resolve."
- `git log --all --oneline | grep -iE "sqlite|vec0|libsqlite"` shows the last related commit is `2dafac3` from Phase 7 plan 07-01 ("merge executor worktree (Memory schema + sqlite-vec store)"). Nothing since. No follow-on commit, no plan, no script under `scripts/`, no entry in `.planning/phases/`, no `Contents/Frameworks/` build step.
- `Package.swift` declares `resources: [.copy("Resources/PLACEHOLDER.txt")]`. The bundle ships a 2-line README in place of the dylib.

**Verdict:** permanent stub. The "deferred to a future ops plan" language is a euphemism for "we wrote 2,000 lines of code against a dependency we never shipped." Until somebody (a) builds a custom `libsqlite3.dylib` with `SQLITE_ENABLE_LOAD_EXTENSION=1`, links Memory against it, AND (b) ships the matching `vec0.dylib` (with same-team codesign per RESEARCH P7), the entire subsystem cannot construct itself.

## 2. FTS5 — UNREACHABLE

FTS5 lives inside SQLite. SQLite is opened by `MemoryStore.init`. `init` throws on every launch. So FTS5 is never exercised in production. `MemoryQueries.hybridSearchSQL` (referenced by `MemoryStore.runHybridSearchSQL` at line 271) hits both the FTS5 virtual table and the `facts_vec` vec0 table in one RRF query — even if you bypassed vec0 you would still need `facts_fts` populated, and `applyOp` is the writer that fills it, and `applyOp` only runs on a constructed store.

There is **no FTS5-only test** that opens a real SQLite file (FTS5 ships in Apple's libsqlite3 — that part would actually work) and asserts ranking. Every DB-touching test in `MemoryStoreApplyOpTests.swift`, `ForgetFactTests.swift`, `HybridSearchTests.swift`, `MemoryRegressionCorpusTests.swift` is gated behind `XCTSkipUnless(JARVIS_VEC0_STUB_PATH != nil, …)` — see e.g. `MemoryStoreApplyOpTests.swift:36-37, 63-64, 98-99, 129-130`.

## 3. sqlite-vec — UNREACHABLE; ONLY PLUMBING TESTED

Same blocker. `HybridSearchTests.swift` runs in CI but uses a `StubStore` (`HybridSearchTests.swift:15-34`) whose `runHybridSearchSQL` simply returns whatever rows the test pre-stuffed via `setRows`. **No vector math is asserted anywhere.** The test "real-DB integration coverage is gated on JARVIS_VEC0_STUB_PATH" (`HybridSearchTests.swift:101-107`) is a `XCTAssertTrue(true, "Real-DB execution lives in 07-06 regression-corpus.")` — a literal placeholder.

The stub-only tests verify (a) the embedder is called once per query, (b) `k` is forwarded, (c) `FactRef.summary == "S P P O"`. None of that exercises RRF, cosine distance, FTS5 BM25 weighting, or even that `embedding.count == 768`. The `capturedEmbeddingDim` field on `StubStore` is set but never asserted.

## 4. Embeddings — REAL CLIENT, HEAVILY UNIT-TESTED, NEVER CALLED IN PRODUCTION

`OllamaEmbeddingClient.swift` is the single best-built thing in the package. It POSTs to `127.0.0.1:11434/api/embed` with proper loopback enforcement (`assertLoopback` lines 88-98), dimension validation (line 74), and structured errors. `OllamaEmbeddingClientTests.swift:113-188` uses `URLProtocolStub` to assert URL/body/dim/HTTP-error handling. These are real tests of real bytes, just not against a real Ollama.

But: in production the embedding client is constructed by `HybridSearch`, and `HybridSearch` is reached through `SearchMemoryTool` — see next bullet — which is **not registered with `mcpRuntime`**. `grep -rn "SearchMemoryTool\|ForgetFactTool"` outside `Tests/` returns only the source files themselves. Zero call sites, zero registration, zero dispatch. The real embed path is dead code at runtime.

The extractor at `MemoryExtractor.swift` does NOT call the embedder (it only uses the LLM provider for the `apply_memory_ops` tool call), and `MemoryExtractionOrchestrator.process` (`MemoryExtractionOrchestrator.swift:78-103`) explicitly hardcodes `priorFacts: [] // Plan 07-03 will replace [] with FTS5-shortlisted prior facts.` That comment says it all: even if the store were live, the extractor runs with no prior context.

## 5. Mem0 ADD/UPDATE/NOOP extractor — REAL CALL, NEVER FIRES

`MemoryExtractor.swift:48-55` does invoke `provider.stream(messages:tools:toolChoice:.auto, model: .qwen25coder32b, maxOutputTokens: 1024, …)`. The provider is supplied by `installMemory` at `AppDelegate.swift:823-826` as a real `OllamaProvider(baseURL: 127.0.0.1:11434)`. So **if** the orchestrator drained a job, it would actually hit Ollama and ask `qwen2.5-coder:32b` for a tool call.

It does not, because:

1. `installMemory` early-returns at `AppDelegate.swift:807` on every cold launch (vec0 missing). The early return is **before** `MemoryExtractor` / `MemoryExtractionOrchestrator.start()` are constructed. Lines 822-848 never execute.
2. Even if it did, the orchestrator's `applyOp` closure (line 834) calls `store.applyOp` on a `MemoryStore` that itself only exists in the success path — so the early return takes them all out together.
3. The extractor is wired to call into `MemoryStore.applyOp`, the SOLE emission site for `ReplayEvent.memoryMutation`. Since extraction never runs, `ReplayEvent.memoryMutation` has never been emitted by production code.

`MemoryExtractorTests.swift` exists but uses a `MockLLMProvider` — it tests parsing of tool-call output, not that anything calls Ollama. The only test that actually hits `qwen2.5-coder:32b` is `MemoryRegressionCorpusTests` (gated behind `JARVIS_REAL_MODELS=1`, all 10 scenarios skipped in CI per `MemoryRegressionCorpusTests.swift:37-42, 70, 91, 110, 136, 170, 198, 214, 231, 253, 274`). There is no evidence the developer has ever run those scenarios green.

## 6. TurnTranscriptStore — Plumbing correct AS OF TODAY; was broken before

`TurnTranscriptStore.swift:60-66` requires BOTH `userText != nil/empty` AND `assistantText != ""` for `flushPair` to return non-nil.

- **User-side append:** `AppDelegate.handleChatSubmit` (`AppDelegate.swift:1166-1175`) → `appendUserTextIfRunning` calls `turnTranscriptStore.append(turnId: …, role: .user, …)` after the orchestrator returns a turnId. This part is fine.
- **Assistant-side append:** the transcript subscriber at `AppDelegate.swift:996-1007` listens on `broadcaster.subscribe(priority: .transcript, capacity: 256)` for `.tokenDelta`. **Whether `.tokenDelta` was actually being emitted into the broadcaster** is the load-bearing question — and per the user's own audit notes (commits 602a95b / 621b454 / 048ab08 from 2026-05-02 / 03), the answer until 2 days ago was: **partly no.** `BLOCKER-INT-2`/`INT-3` in `AUDIT-FINDINGS.md` describe the `.bus` subscriber being missing entirely (5 broadcaster subscribers, none forwarding to the bus). The transcript subscriber is independent of `.bus`, so it would have received `.tokenDelta` events as long as the broadcaster was running — but per `AUDIT-FINDINGS.md:154-156` the orchestrator + broadcaster + ALL six subscribers were dormant on every cold launch because `installAgent` short-circuited on `mcpRuntime == nil` (a separate ordering bug).

So: prior to commit 048ab08 (today's work), the transcript subscriber was constructed but the broadcaster it subscribed to had no upstream events because the orchestrator was never built. `flushPair` could not have returned non-nil even once. After today's fix, **structurally** the path can flow — but it still ends in `MemoryExtractionCoordinator.start(...)` enqueueing into `memoryOrchestrator` which is `nil` (because `installMemory` early-returned), so `coord.start(...)` runs but no jobs ever actually reach an extractor. See `AppDelegate.swift:969-987` — the `if let coord = self.memoryExtractionCoordinator` guard succeeds (the coordinator IS constructed even when the store fails — wait, no — `installMemory:807` returns BEFORE constructing the coordinator at line 845). Net: `memoryExtractionCoordinator == nil` on every cold launch, the warning at line 986 fires, and the memory subscriber task is never even started.

## 7. Test classification

| Test file | Classification | Notes |
|---|---|---|
| `OllamaEmbeddingClientTests.swift` | **REAL** (against URLProtocol stub) | Asserts wire shape, dim, errors. The most rigorous file in the package. |
| `EmbeddingNetworkSandboxTests.swift` | REAL | Loopback assertion only. |
| `EmbeddingDimSymbolTests.swift` | REAL (grep gate) | Symbol-presence test. |
| `MemoryQueriesAndModelTests.swift` | REAL | Pure-Swift model encoding. |
| `MemorySchemaTests.swift` | REAL | DDL string assertions, no DB. |
| `SingleEmissionSiteGrepTests.swift` | REAL (grep gate) | Asserts source-file invariants. |
| `PhaseSevenGrepGateTests.swift` | REAL (grep gate) | Asserts call ordering in AppDelegate. |
| `MemoryExtractorTests.swift` | MOCK | `MockLLMProvider`, no Ollama. |
| `MemoryExtractionOrchestratorTests.swift` | MOCK | Stub closures. |
| `HybridSearchTests.swift` | MOCK | `StubStore` + `StubEmbedder`; no math asserted; real-DB case is `XCTAssertTrue(true, "...")`. |
| `SessionHistoryTests.swift` | MOCK | StubStore, asserts plumbing. |
| `MemoryWiringEndToEndTests.swift` | MOCK | Real broadcaster + transcript + coordinator, but `JobSpy` swallows extraction. |
| `MemoryStoreTests.swift` | **DEAD** in CI | Only the negative `vecLoadFailed` test runs; positive case skipped. |
| `MemoryStoreApplyOpTests.swift` | **DEAD** in CI | All four DB-roundtrip cases skipped behind `JARVIS_VEC0_STUB_PATH`. |
| `ForgetFactTests.swift` | **DEAD** in CI | All cases skipped. |
| `MemoryRegressionCorpusTests.swift` | **DEAD** in CI | All 10 scenarios skipped behind `JARVIS_REAL_MODELS`. |

**No test in the package opens a real SQLite, runs a real query, returns real data on CI.** The grep gates are valuable but they assert structure, not behavior. The single end-to-end wiring test (`MemoryWiringEndToEndTests`) terminates in a `JobSpy`, never reaching SQLite.

## 8. End-to-end "remember my dog's name is Brutus" — every missing wire

Today, none of these work. The user types it, sees streamed tokens (now, post-2026-05-03 fixes), and nothing else happens. Required to make it work:

1. **Bundle a custom `libsqlite3.dylib`** with `SQLITE_ENABLE_LOAD_EXTENSION=1`, link Memory against it (override the implicit Foundation `import SQLite3`), codesign + place under `Contents/Frameworks/`. Currently zero work done.
2. **Bundle `vec0.dylib`** (sqlite-vec v0.1.10-alpha.3), same-team codesigned, in `Bundle.module`. Currently `Resources/PLACEHOLDER.txt` ships in its place.
3. Make `installMemory` not early-return so `MemoryExtractionOrchestrator` and `MemoryExtractionCoordinator` are actually constructed (`AppDelegate.swift:807`).
4. **Register `SearchMemoryTool` + `ForgetFactTool` with `mcpRuntime`** — they exist as files (`packages/MCP/Sources/MCP/InProcess/SearchMemoryTool.swift:25-29`, `ForgetFactTool.swift:9-13`) but are never instantiated outside their own unit tests. The agent has no way to query memory even if it existed.
5. **Fix the `priorFacts: []` hardcode** in `MemoryExtractionOrchestrator.swift:84` so the extractor sees prior context (otherwise UPDATE never fires; it's ADD-only).
6. **Pull `qwen2.5-coder:32b` and `nomic-embed-text` locally** in Ollama. Not a code wire but a setup gate; no first-run flow checks for it.
7. Run a real end-to-end test that writes "Brutus" via the extractor, queries via `search_memory`, and asserts retrieval. `MemoryRegressionCorpusTests.testScenario01_AddNewDurableFact` is structurally that test, but has never been run green per the absence of any commit acknowledging it.

---

**Bottom line.** The Memory subsystem is a 2,500-line architectural sketch resting on a missing dylib. The code quality of individual pieces (the embedding client, the supersede transaction in `applyOp`, the bounded-channel orchestrator) is reasonable. But "Phase 7 passed_with_deferrals 13/13" in the milestone audit is fiction: the central blocker — that `libsqlite3` cannot load extensions — was punted to "a future ops plan" that never materialized, and every downstream test was skipped in CI to make the suite green. Until somebody builds the dylib, nothing memory-related has ever worked or can work.
