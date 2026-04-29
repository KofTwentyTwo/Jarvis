# Phase 7: Memory + Vision — Pattern Map

**Mapped:** 2026-04-28
**Files analyzed:** 23 new + 7 modified surfaces
**Analogs found:** 22 / 23 new files have a strong in-tree analog

This artifact maps every Phase 7 surface to the closest existing analog in the
codebase, with concrete excerpts the planner can quote into action sections.
Section §1 is the file → role / data-flow / analog table; §2 is per-file
excerpts; §3 is the shared-pattern catalog (S-1..S-9); §4 is the no-analog /
highest-risk-scaffold list.

The goal: when the planner writes "Plan X creates file Y", the answer to "what
pattern does it follow?" is one row in §1 plus one excerpt block in §2.

---

## §1. File Classification

Two new packages (`packages/Memory`, `packages/Vision`) plus extensions to
existing packages (`AgentCore`, `MCP`, `Replay`, `App`, `App/HUD`).

### 1a. New files

| New File | Role | Data Flow | Closest Analog | Match Quality |
|----------|------|-----------|----------------|---------------|
| `packages/Memory/Package.swift` | config | n/a | `packages/Voice/Package.swift` | exact |
| `packages/Memory/Sources/Memory/Constants.swift` | utility | n/a (constants) | `packages/AgentCore/Sources/AgentCore/ModelID.swift` | role-match |
| `packages/Memory/Sources/Memory/SQLiteStore.swift` (a.k.a. `MemoryStore`) | service / actor | CRUD + extension load | `packages/Replay/Sources/Replay/ReplayLog.swift` | exact |
| `packages/Memory/Sources/Memory/SchemaMigration.swift` | utility | DDL | `packages/Replay/Sources/Replay/Schema.swift` | exact |
| `packages/Memory/Sources/Memory/EmbeddingClient.swift` | service | request-response (HTTP) | `packages/AgentCore/Sources/OllamaProvider/OllamaProvider.swift` | role-match (non-streaming subset) |
| `packages/Memory/Sources/Memory/Extractor.swift` (mem0 ADD/UPDATE/NOOP) | service | LLM tool-call | `packages/AgentCore/Sources/AgentOrchestrator/AgentOrchestrator.swift` | partial — same `LLMProvider.stream` shape, single-turn |
| `packages/Memory/Sources/Memory/MemoryOrchestrator.swift` (background `.memoryExtraction`) | controller / actor | event-driven (channel consumer) | `packages/AgentCore/Sources/AgentOrchestrator/AgentOrchestrator.swift` | role-match |
| `packages/Memory/Sources/Memory/MemoryExtractionCoordinator.swift` (turnEnd → channel) | controller | event-driven | `App/AppDelegate.swift` `orchToReplayDrainTask` (Plan 05-05 channel pattern) | exact |
| `packages/Memory/Sources/Memory/HybridSearch.swift` (FTS5 + vec RRF) | service | request-response | `packages/Replay/Sources/Replay/ReplayLog.swift` (SQL via `query`) | role-match |
| `packages/Memory/Sources/Memory/MemoryEvent.swift` (`MemoryOp`, `FactRef`) | model | n/a | `packages/Replay/Sources/Replay/ReplayEvent.swift` | exact (enum + extension pattern) |
| `packages/Memory/Tests/MemoryTests/*.swift` | test | n/a | `packages/Replay/Tests/ReplayTests/SchemaTests.swift` + `ReplayLogTests.swift` | exact |
| `packages/Vision/Package.swift` | config | n/a | `packages/Voice/Package.swift` | exact |
| `packages/Vision/Sources/Vision/CaptureSession.swift` (AVCaptureSession + TCC) | service / actor | streaming (frame pull) | `packages/Voice/Sources/Voice/AudioGraph/AudioGraphOwner.swift` | exact (lifecycle + degradationStream) |
| `packages/Vision/Sources/Vision/PresenceDetector.swift` (`VNDetectFaceRectanglesRequest`) | service / actor | event-driven detector | `packages/Voice/Sources/Voice/WakeWord/WakeWordDAG.swift` | exact |
| `packages/Vision/Sources/Vision/PresenceSignalBus.swift` (`AsyncStream<PresenceEvent>`) | model / event-bus | pub-sub | `packages/Voice/Sources/Voice/WakeWord/OpenWakeWordSession.swift` (`WakeWordEvent` enum) + `WakeWordDAG.wakeWordStream` | exact |
| `packages/Vision/Sources/Vision/PresenceEvent.swift` | model | n/a | `packages/Voice/Sources/Voice/WakeWord/OpenWakeWordSession.swift` lines 208-211 | exact |
| `packages/Vision/Sources/Vision/DisablePresence.swift` (UserDefaults + menu-bar) | controller | request-response | `packages/Voice/Sources/Voice/Control/MuteWakeWord.swift` | exact (clone verbatim per D-12) |
| `packages/Vision/Sources/Vision/FrameAttachCoordinator.swift` (capture → confirm → send) | controller | request-response (one-shot) | hybrid: `CaptureSession` (capture) + `HUDBannerCoordinator` (confirm modal) + `OllamaProvider.stream` callsite (send) | partial — see §4 |
| `packages/Vision/Sources/Vision/VllmMlxProvider.swift` (T2 vision routing) | service / actor | streaming (HTTP) | `packages/AgentCore/Sources/OllamaProvider/OllamaProvider.swift` | exact (OpenAI-compat endpoint shape) |
| `packages/Vision/Sources/Vision/VllmMlxSidecar.swift` (process lifecycle + health-check) | service | process supervision | `packages/MCP/Sources/MCP/ChildSpawnGate.swift` (spawn) + `packages/Voice/Sources/Voice/TTS/OrpheusTTS.swift` (warmup probe) | partial — see §4 |
| `packages/Vision/Tests/VisionTests/*.swift` | test | n/a | `packages/Voice/Tests/VoiceTests/MuteWakeWordTests.swift` (toggle state) + `WakeWordHysteresisTests.swift` (event-bus) | exact |
| `packages/MCP/.../tools/SearchMemoryTool.swift`, `SearchConversationTool.swift`, `ForgetFactTool.swift` | controller (MCP tool) | request-response | `App/MCP/MCPRuntimeWiring.swift` `client.register(...)` + `ToolRegistry.register(toolName:...)` | exact |
| `App/HUD/PresenceRingIndicator.swift` (subtle ring shift, D-10) | view / coordinator hook | event-driven | `App/HUD/HudStateCoordinator.swift` (extends `lastVoice` shadow with new field) | role-match |

### 1b. Modified files

| File | Modification | Reason | Risk |
|------|--------------|--------|------|
| `packages/AgentCore/Sources/AgentCore/LLMProvider.swift` | Add `stream(messages:images:tools:toolChoice:model:maxOutputTokens:cacheHints:)` overload | D-18 multimodal protocol extension | Caution: every conformer must implement (`AnthropicProvider`, `OllamaProvider`, new `VllmMlxProvider`) |
| `packages/AgentCore/Sources/AgentCore/LLMMessage.swift` | Add `case image(mediaType: String, base64: String)` to `ContentBlock` | Carry image blocks through history | All providers must encode the new case |
| `packages/AgentCore/Sources/AgentOrchestrator/TurnInput.swift` | Add `images: [ImageBlock]` field (default `[]`) | VISION-04 frame attach | Backward-compatible default; existing call-sites compile |
| `packages/Replay/Sources/Replay/ReplayEvent.swift` | Add cases `.memoryMutation(MemoryOp)` and `.memoryRetrieval(FactRef)` | DevOverlay surface (D-05, MEM-08) | New `ReplayEventKind` rawValue rows in Schema.swift; encoded() switch must cover them |
| `App/AppDelegate.swift` | Add `installMemory()` + `installVision()` install functions and strong properties (`memoryStore`, `memoryOrchestrator`, `captureSession`, `presenceDetector`, `disablePresence`, `frameAttachCoordinator`) | Wire new subsystems | Mirror existing `installVoice()` exactly (lines 351-446) |
| `App/HUD/HudStateCoordinator.swift` | Add `lastPresence: PresenceEvent` shadow + low-key resolved-state shift (D-10) | Subtle ring indicator on `.present`/`.absent` | Single-writer invariant preserved (still one resolveAndEmit) |
| `packages/AgentCore/Sources/AgentOrchestrator/AgentOrchestrator.swift` | `ContextBuilder` (NEW or extended) injects presence state + frame-attach phrase detection into system prompt; orchestrator gains `submit(TurnInput.withImages(...))` overload | D-10 + D-13 | Read-only consumer of `PresenceSignalBus`; never the producer side |

---

## §2. Pattern Assignments

For each new file: cite the analog file by absolute path, then quote the
specific code block to copy. Copy-then-adapt is preferred over
copy-as-is — but the structure is the structure.

### 2.1 `packages/Memory/Package.swift`

**Analog:** `/Users/james.maes/Git.Local/kof22/Jarvis/packages/Voice/Package.swift`
(Phase 6, most recent multi-product package — strict-concurrency v6 already wired)

**Why:** Mirror SwiftPM 6 strict-concurrency setup; Memory has no external SPM
dependencies (sqlite-vec is loaded as a runtime dylib via direct C API per
RESEARCH §2 — NOT an SPM dependency). Memory needs system SQLite3 only.

**Imports / target shape excerpt** (`Voice/Package.swift` lines 13-65):

```swift
import PackageDescription

let package = Package(
    name: "Memory",
    platforms: [.macOS(.v13)],   // SQLite3, no Tahoe-only API
    products: [
        .library(name: "Memory", targets: ["Memory"]),
    ],
    dependencies: [
        .package(path: "../Logging"),
        .package(path: "../AgentCore"),     // LLMProvider for Extractor
        .package(path: "../Replay"),        // SQLiteConnection reuse + TurnSource
        .package(url: "https://github.com/apple/swift-log.git", from: "1.5.0"),
    ],
    targets: [
        .target(
            name: "Memory",
            dependencies: [
                .product(name: "JarvisLogging", package: "Logging"),
                .product(name: "AgentCore", package: "AgentCore"),
                .product(name: "Replay", package: "Replay"),
                .product(name: "Logging", package: "swift-log"),
            ],
            path: "Sources/Memory",
            swiftSettings: [.swiftLanguageMode(.v6)],
        ),
        .testTarget(
            name: "MemoryTests",
            dependencies: ["Memory"],
            path: "Tests/MemoryTests",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
```

**Linker note:** Memory does NOT add `linkedLibrary("sqlite3")` — Foundation's
`import SQLite3` already pulls in libsqlite3.tbd from the macOS SDK, exactly
how `packages/Replay/Sources/Replay/SQLiteConnection.swift:2` does it.

---

### 2.2 `packages/Memory/Sources/Memory/SQLiteStore.swift` (a.k.a. `MemoryStore`)

**Analog (primary):** `/Users/james.maes/Git.Local/kof22/Jarvis/packages/Replay/Sources/Replay/ReplayLog.swift`
(actor + injected SQLiteConnection + WAL + best-effort writes)

**Analog (lifecycle owner):** `/Users/james.maes/Git.Local/kof22/Jarvis/packages/Voice/Sources/Voice/AudioGraph/AudioGraphOwner.swift`
(actor-owned resource lifecycle with `open()` + watchers + clean shutdown — S-1)

**Critical reuse:** `SQLiteConnection` from
`packages/Replay/Sources/Replay/SQLiteConnection.swift` is **already authored
for Phase 7's needs** — its docstring (lines 12-22) explicitly says:

> *"Phase 7 will load the `sqlite-vec` extension (vector search for memory),
> which requires `sqlite3_load_extension`. The mainline Swift package
> `SQLite.swift` (Stephen Celis) statically blocks that API, so we own the
> connection ourselves. This is intentional — see CLAUDE.md memory stack
> section + research §11."*

The class is `final class @unchecked Sendable` with `OpaquePointer` handle and
`SQLITE_OPEN_FULLMUTEX`. Memory should `import Replay` and reuse this verbatim
rather than rebuild a parallel SQLite wrapper.

**Actor + init excerpt** (`ReplayLog.swift` lines 16-62):

```swift
public actor MemoryStore {
    private let conn: SQLiteConnection
    private let logger: Logger

    public init(databaseURL: URL) throws {
        try ReplayPaths.ensureParentDirectory(of: databaseURL)
        self.conn = try SQLiteConnection.open(at: databaseURL)
        self.logger = Logger(label: JarvisLogChannel.memory.rawValue)

        // 1. Pragmas (WAL + foreign_keys ON + busy_timeout per Schema.swift)
        for sql in MemorySchema.pragmas { try conn.execute(sql) }

        // 2. Load sqlite-vec extension via direct C API (RESEARCH §2)
        try loadVecExtension()

        // 3. Schema DDL (idempotent CREATE IF NOT EXISTS)
        for sql in MemorySchema.allStatements { try conn.execute(sql) }

        // 4. Sanity probe — assert vec_version() reads
        try assertVecVersion()
    }
}
```

**sqlite-vec load excerpt** — this is greenfield (§4 risk #1) but the rough
shape is a Foundation/Bundle path lookup + two `sqlite3_*` C calls:

```swift
private func loadVecExtension() throws {
    // Direct C API — must reach through SQLiteConnection to get the handle.
    // SQLiteConnection.handle is currently private; either add a
    // `withHandle(_ body:)` accessor OR move loadVecExtension into Replay.
    // (Planner decision; recommend: add a withHandle closure-based accessor
    // to SQLiteConnection so callers can't leak the OpaquePointer.)
    try conn.withHandle { db in
        guard sqlite3_enable_load_extension(db, 1) == SQLITE_OK else {
            throw MemoryError.vecLoadFailed("enable_load_extension failed")
        }
        guard let path = Bundle.module.path(forResource: "vec0", ofType: "dylib") else {
            throw MemoryError.vecLoadFailed("vec0.dylib not in bundle")
        }
        var err: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_load_extension(db, path, nil, &err)
        sqlite3_enable_load_extension(db, 0)
        if rc != SQLITE_OK {
            let msg = err.flatMap { String(cString: $0) } ?? "unknown"
            sqlite3_free(err)
            throw MemoryError.vecLoadFailed(msg)
        }
    }
}
```

**Single emission site for atomic events (S-6):** `ReplayLog.flushPending`
(lines 195-261) is the only place writes hit disk; mirror this in
`MemoryStore.applyOp` — it should be the only emit site for the
`memory.mutated` bridge channel.

**Best-effort write pattern** (`ReplayLog.swift` lines 9-15, 220-261):

```swift
do {
    try conn.beginTransaction()
    // UPDATE-and-insert per RESEARCH §6 (close-and-supersede)
    try writeRow(sql: "UPDATE facts SET valid_to=?, superseded_by=? ...", ...)
    try writeRow(sql: "INSERT INTO facts(...) VALUES(...)", ...)
    try writeRow(sql: "INSERT INTO facts_vec(fact_id, embedding) VALUES(?, ?)", ...)
    try conn.commit()
    consecutiveFlushFailures = 0   // S-6 escalation reset
} catch {
    try? conn.rollback()
    consecutiveFlushFailures += 1
    if consecutiveFlushFailures >= Self.flushFailureEscalationThreshold {
        logger.critical("memory write failing chronically (data-loss risk)", metadata: [...])
    } else {
        logger.error("memory applyOp failed", metadata: ["error": "\(error)"])
    }
    throw MemoryError.applyOpFailed(underlying: error)
}
```

---

### 2.3 `packages/Memory/Sources/Memory/SchemaMigration.swift`

**Analog:** `/Users/james.maes/Git.Local/kof22/Jarvis/packages/Replay/Sources/Replay/Schema.swift`

**Pattern:** static enum holding three string arrays — `pragmas`, `allStatements`,
`seedMeta`. Every CREATE uses `IF NOT EXISTS`; every seed uses `INSERT OR IGNORE`.

**Excerpt** (`Schema.swift` lines 8-67):

```swift
public enum MemorySchema {
    public static let pragmas: [String] = [
        "PRAGMA journal_mode=WAL;",
        "PRAGMA synchronous=NORMAL;",
        "PRAGMA busy_timeout=3000;",
        "PRAGMA foreign_keys=ON;",
        "PRAGMA temp_store=MEMORY;",
    ]

    public static let allStatements: [String] = [
        // RESEARCH §1 — turns table (TEXT-03 browsing + replay corpus)
        """
        CREATE TABLE IF NOT EXISTS turns (
          id INTEGER PRIMARY KEY,
          session_id TEXT NOT NULL,
          role TEXT NOT NULL,
          content TEXT NOT NULL,
          source TEXT NOT NULL,
          created_at INTEGER NOT NULL
        );
        """,
        // RESEARCH §1 — facts table with temporal validity
        """
        CREATE TABLE IF NOT EXISTS facts (
          id INTEGER PRIMARY KEY,
          subject TEXT NOT NULL,
          predicate TEXT NOT NULL,
          object TEXT NOT NULL,
          source_turn_id INTEGER REFERENCES turns(id),
          valid_from INTEGER NOT NULL,
          valid_to INTEGER,
          superseded_by INTEGER REFERENCES facts(id),
          forgotten_at INTEGER,                    -- D-02 forget-fact flag
          created_at INTEGER NOT NULL
        );
        """,
        "CREATE INDEX IF NOT EXISTS idx_facts_active ON facts(subject, predicate) WHERE valid_to IS NULL;",
        // FTS5 + vec0 virtual tables interpolate MemoryConstants.embeddingDim:
        "CREATE VIRTUAL TABLE IF NOT EXISTS facts_fts USING fts5(subject, predicate, object, content=facts, content_rowid=id, tokenize='unicode61 remove_diacritics 2');",
        "CREATE VIRTUAL TABLE IF NOT EXISTS turns_fts USING fts5(content, content=turns, content_rowid=id, tokenize='unicode61 remove_diacritics 2');",
        "CREATE VIRTUAL TABLE IF NOT EXISTS facts_vec USING vec0(fact_id INTEGER PRIMARY KEY, embedding FLOAT[\(MemoryConstants.embeddingDim)]);",
    ]
}
```

**Note:** The `\(MemoryConstants.embeddingDim)` interpolation in the `facts_vec`
DDL is RESEARCH §3's MEM-02 invariant — schema and code share one symbol.

---

### 2.4 `packages/Memory/Sources/Memory/EmbeddingClient.swift`

**Analog:** `/Users/james.maes/Git.Local/kof22/Jarvis/packages/AgentCore/Sources/OllamaProvider/OllamaProvider.swift`
(URLSession + JSONDecoder + localhost Ollama; reuse the URLSession from the
text provider so connection pooling is shared.)

**Why role-match not exact:** EmbeddingClient is request-response (POST one
prompt, get one fixed-length embedding back) — NOT streaming. So copy the
URLRequest building + error mapping + transport-error class **but not** the
SSE / NDJSON decoder logic.

**Imports + transport pattern** (`OllamaProvider.swift` lines 20-130):

```swift
public actor EmbeddingClient {
    private let baseURL: URL
    private let session: URLSession
    private let model: String                 // "nomic-embed-text"

    public init(
        baseURL: URL = URL(string: "http://127.0.0.1:11434")!,
        session: URLSession = .shared,
        model: String = "nomic-embed-text"
    ) {
        self.baseURL = baseURL
        self.session = session
        self.model = model
    }

    public func embed(_ input: String) async throws -> [Float] {
        var request = URLRequest(url: baseURL.appending(path: "/api/embed"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(EmbedBody(model: model, input: input))

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw MemoryError.embeddingTransportFailed(error.localizedDescription)
        }
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw MemoryError.embeddingHTTP(statusCode: http.statusCode)
        }
        let decoded = try JSONDecoder().decode(EmbedResponse.self, from: data)
        guard let first = decoded.embeddings.first else {
            throw MemoryError.embeddingShapeError("empty embeddings array")
        }
        // MEM-02 runtime invariant — RESEARCH §4
        guard first.count == MemoryConstants.embeddingDim else {
            throw MemoryError.dimensionMismatch(
                expected: MemoryConstants.embeddingDim, actual: first.count
            )
        }
        return first
    }
}

private struct EmbedBody: Encodable { let model: String; let input: String }
private struct EmbedResponse: Decodable { let embeddings: [[Float]] }
```

**Loopback validation:** `OllamaProvider` defers loopback validation to
`OllamaConfig` (its docstring lines 16-17). EmbeddingClient should do the
same — accept `baseURL: URL` from caller but the wiring layer (AppDelegate /
ConfigStore) enforces 127.0.0.1/localhost. AGENT-05 invariant carries forward.

---

### 2.5 `packages/Memory/Sources/Memory/Extractor.swift` (mem0)

**Analog:** `/Users/james.maes/Git.Local/kof22/Jarvis/packages/AgentCore/Sources/AgentOrchestrator/AgentOrchestrator.swift`
(uses `LLMProvider.stream` to drive a tool-call. RESEARCH §5 specifies
`apply_memory_ops` as a synthetic tool whose JSON the extractor parses
directly — single-turn, no agent loop.)

**Why partial:** Extractor calls `provider.stream(...)` exactly once per
extraction job; aggregates `tokenDelta` + `toolUseRequested` into a complete
response; never iterates a multi-turn loop. So copy the **request shape +
event handling** from AgentOrchestrator's `runTurnLoop` (lines 209-455) but
discard everything related to `outer:` looping, retry, cap-recovery,
`UntrustedWrapper`, and budget.

**Single-turn extraction excerpt** (composed from `AgentOrchestrator.swift`
lines 215-243, 318-354):

```swift
public actor Extractor {
    private let provider: any LLMProvider
    private let model: ModelID = .qwen25coder32b

    public init(provider: any LLMProvider) {
        self.provider = provider
    }

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
            tools: [MemoryTools.applyMemoryOps],   // synthetic tool schema
            toolChoice: .auto,                     // model decides ADD/UPDATE/NOOP
            model: model,
            maxOutputTokens: 1024,
            cacheHints: nil
        )

        var collectedToolCall: ToolUseRequest?
        for try await event in stream {
            switch event {
            case .toolUseRequested(let req):
                collectedToolCall = req
            case .stopReason(.endTurn), .stopReason(.toolUse):
                break   // expected terminators
            default:
                break
            }
        }

        guard let toolCall = collectedToolCall else {
            return []   // NOOP — model decided no memory change
        }
        return try MemoryOp.parseApplyMemoryOps(toolCall.argsJSON)
    }
}
```

---

### 2.6 `packages/Memory/Sources/Memory/MemoryOrchestrator.swift`

**Analog:** `/Users/james.maes/Git.Local/kof22/Jarvis/packages/AgentCore/Sources/AgentOrchestrator/AgentOrchestrator.swift`
(actor + bounded channel + serial Task consumer)

**Bounded channel (S-6):** Reuse `BoundedAsyncChannel<ExtractionJob>` from
`packages/AgentCore/Sources/AgentCore/BoundedAsyncChannel.swift` lines 14-44.
Capacity 32 per RESEARCH §7, policy `.dropOldest` (older turns are still in
the `turns` table; the distillation just isn't done — researcher Open Q #5
recommendation).

**Channel + drain Task pattern** (`AppDelegate.swift` lines 274-295 — the
orch→replay drain Task is the cleanest example):

```swift
public actor MemoryOrchestrator {
    private let channel: BoundedAsyncChannel<ExtractionJob>
    private let extractor: Extractor
    private let store: MemoryStore
    private let bus: MemoryEventBus               // S-2 emits memory.mutated
    private var drainTask: Task<Void, Never>?

    public init(
        extractor: Extractor,
        store: MemoryStore,
        bus: MemoryEventBus
    ) {
        self.channel = BoundedAsyncChannel<ExtractionJob>(
            capacity: 32, policy: .dropOldest    // RESEARCH §7
        )
        self.extractor = extractor
        self.store = store
        self.bus = bus
    }

    public func start() {
        drainTask = Task.detached { [weak self] in
            guard let self else { return }
            for await job in await self.channel {
                if Task.isCancelled { return }
                await self.process(job)         // serial — never parallel (32B model VRAM)
            }
        }
    }

    public func enqueue(_ job: ExtractionJob) async {
        await channel.send(job)
    }

    public func shutdown() async {
        drainTask?.cancel()
        await channel.finish()
    }

    private func process(_ job: ExtractionJob) async {
        // Best-effort — never propagate to AgentOrchestrator.
        // RESEARCH §7: each job fetches priors, runs extractor, applies ops.
        let priors = (try? await store.activeFactsMatching(subject: job.subjects)) ?? []
        do {
            let ops = try await extractor.extract(
                userText: job.userText, assistantText: job.assistantText,
                priorActiveFacts: priors
            )
            for op in ops {
                try await store.applyOp(op, sourceTurnId: job.turnId)
                // S-6 single emission site: applyOp emits memory.mutated.
            }
        } catch {
            // Best-effort. Log and proceed; never block turnEnd.
        }
    }
}
```

---

### 2.7 `packages/Memory/Sources/Memory/MemoryExtractionCoordinator.swift`

**Analog:** `/Users/james.maes/Git.Local/kof22/Jarvis/App/AppDelegate.swift` lines 274-295
(orch→replay drain Task is the textbook for "subscribe to one async sequence,
push to another bounded channel")

**Pattern:** Thin glue actor that subscribes to `AgentOrchestrator.events`
(`OrchestratorEvent.turnEnd`), assembles an `ExtractionJob` from the turn's
user+assistant content, and pushes onto `MemoryOrchestrator.channel`.

**Excerpt** (composed from `AppDelegate.swift` 274-295 + `WakeWordDAG.swift` 71-101):

```swift
public actor MemoryExtractionCoordinator {
    private var subscription: Task<Void, Never>?
    private let memoryOrchestrator: MemoryOrchestrator

    public init(memoryOrchestrator: MemoryOrchestrator) {
        self.memoryOrchestrator = memoryOrchestrator
    }

    public func start(
        orchestratorEvents: BoundedAsyncChannel<OrchestratorEvent>,
        turnContent: @escaping @Sendable (TurnID) async -> (user: String, assistant: String)?
    ) {
        subscription = Task.detached { [weak self] in
            guard let self else { return }
            for await event in orchestratorEvents {
                if Task.isCancelled { return }
                guard case .turnEnd(let turnId, let stop) = event,
                      stop == .endTurn  // only successful turns
                else { continue }
                guard let pair = await turnContent(turnId) else { continue }
                let job = ExtractionJob(
                    turnId: turnId,
                    userText: pair.user,
                    assistantText: pair.assistant
                )
                await self.memoryOrchestrator.enqueue(job)
            }
        }
    }

    public func stop() async { subscription?.cancel() }
}
```

---

### 2.8 `packages/Memory/Sources/Memory/HybridSearch.swift`

**Analog:** `/Users/james.maes/Git.Local/kof22/Jarvis/packages/Replay/Sources/Replay/SQLiteConnection.swift` lines 73-87
(prepared statement + bindings + map closure for SELECT — exactly what RESEARCH §8 needs.)

**Pattern:** Single SQL with FTS5 + vec0 + RRF fusion, parameterized query,
one `query<T>` call returning `[Fact]`.

**Excerpt** (composed from `SQLiteConnection.query` lines 73-87 + RESEARCH §8):

```swift
public actor HybridSearch {
    private let store: MemoryStore
    private let embedder: EmbeddingClient

    public init(store: MemoryStore, embedder: EmbeddingClient) {
        self.store = store
        self.embedder = embedder
    }

    public func searchFacts(_ query: String, k: Int = 10) async throws -> [Fact] {
        let qv = try await embedder.embed(query)
        // RESEARCH §8 — RRF SQL with the `60` constant; parameterized.
        // Pitfall #9: vec0 requires `AND k=N` literal in WHERE — template it.
        let sql = MemoryQueries.hybridSearchSQL(k: 50)   // top-50 per cohort
        let qvBytes = qv.withUnsafeBufferPointer { Data(buffer: $0) }
        return try await store.query(sql, bindings: [
            .text(query),
            .blob(qvBytes),
        ]) { stmt in
            Fact(
                id: stmt.columnInt(at: 0),
                subject: stmt.columnText(at: 1) ?? "",
                predicate: stmt.columnText(at: 2) ?? "",
                object: stmt.columnText(at: 3) ?? "",
                validFrom: stmt.columnInt(at: 4),
                validTo: stmt.columnIsNull(at: 5) ? nil : stmt.columnInt(at: 5)
            )
        }
        .prefix(k).map { $0 }
    }
}
```

---

### 2.9 `packages/Memory/Sources/Memory/MemoryEvent.swift` (`MemoryOp`, `FactRef`)

**Analog:** `/Users/james.maes/Git.Local/kof22/Jarvis/packages/Replay/Sources/Replay/ReplayEvent.swift`
(enum + extension for `encoded()` — mirror this pattern exactly)

**Pattern:** Sendable enum + per-case payload struct + `encoded() -> (kind: String, payloadBytes: Data)` extension. Hooks into ReplayEvent additions in §3.

**Excerpt** (`ReplayEvent.swift` lines 35-97):

```swift
public enum MemoryOp: Sendable, Equatable {
    case add(Fact)
    case update(oldId: Int64, new: Fact)
    case noop                                  // logged at debug only — MEM-08
}

public struct FactRef: Sendable, Equatable {
    public let factId: Int64
    public let triggerTurnId: TurnID
    public let timestamp: Int64
}

extension MemoryOp {
    public func encoded() -> (kind: String, payloadBytes: Data) {
        switch self {
        case .add(let f):
            // JSON envelope: {"op":"ADD","fact":...,"factId":...,...}
            // Match RESEARCH §13 schema verbatim.
            ...
        case .update(let oldId, let new):
            ...
        case .noop:
            return (MemoryEventKind.noop.rawValue, Data())
        }
    }
}
```

---

### 2.10 `packages/Vision/Package.swift`

**Analog:** `/Users/james.maes/Git.Local/kof22/Jarvis/packages/Voice/Package.swift`
(same Phase 6 SwiftPM 6 setup, AVFoundation + Vision frameworks linked.)

**ARCHITECTURAL GUARD (VISION-03 / S-7):** `Vision`'s `Package.swift` MUST NOT
declare a `dependencies:` entry on `Voice` (TTS) or `AgentOrchestrator`. This
is the compile-time enforcement of the "no presence → TTS" invariant. The
dependency list is exactly:

```swift
dependencies: [
    .package(path: "../Logging"),
    .package(path: "../AgentCore"),    // LLMProvider for VllmMlxProvider only
    .package(url: "https://github.com/apple/swift-log.git", from: "1.5.0"),
],
```

`AgentCore` (`LLMProvider` protocol) is allowed; `AgentOrchestrator`
(turn-lifecycle actor) is forbidden — Vision must never reach `runTurn`.

**Linker** (mirror Voice lines 53-57):

```swift
linkerSettings: [
    .linkedFramework("AVFoundation"),
    .linkedFramework("Vision"),
    .linkedFramework("CoreImage"),     // for downscale + JPEG encode (RESEARCH §11)
],
```

---

### 2.11 `packages/Vision/Sources/Vision/CaptureSession.swift`

**Analog:** `/Users/james.maes/Git.Local/kof22/Jarvis/packages/Voice/Sources/Voice/AudioGraph/AudioGraphOwner.swift`
(actor + degradationStream + watcher Tasks + clean shutdown — S-1, S-4)

**Pattern reuse:**
- `actor` ownership of the `AVCaptureSession`
- `AsyncStream<DegradationReason>.Continuation` for graceful denial → HUDBannerCoordinator
- Background watcher Task for mid-session revocation (`AVCaptureSessionRuntimeErrorNotification` per RESEARCH §10)
- `open()` / `shutdown()` lifecycle, **not** auto-start in init
- `cancelInFlight` slot pattern for downstream consumers

**Excerpt** (`AudioGraphOwner.swift` lines 32-114):

```swift
public actor CaptureSession {

    public var currentVariant: CaptureVariant? { session != nil ? .running : nil }

    public init(
        degradationContinuation: AsyncStream<VisionDegradationReason>.Continuation,
        sampleRate: Int = 15,                  // 720p/15fps per RESEARCH §9
        sessionBuilder: any CaptureSessionBuilder = LiveCaptureBuilder()
    ) {
        self.degradationCont = degradationContinuation
        self.sessionBuilder = sessionBuilder
    }

    public func open() async throws {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            try await buildSession()
            startWatchers()
        case .notDetermined:
            // Per RESEARCH §10: do NOT prompt at launch — wait for first call.
            // Caller should request via AVCaptureDevice.requestAccess(for: .video)
            // and re-call open() on grant.
            throw VisionError.tccNotDetermined
        case .denied, .restricted:
            // S-4: emit graceful-denial signal — HUDBannerCoordinator picks up.
            degradationCont.yield(.cameraDenied)
            throw VisionError.tccDenied
        @unknown default:
            throw VisionError.tccUnknown
        }
    }

    public func shutdown() async {
        cancelWatchers()
        session?.stopRunning()
        session = nil
        degradationCont.finish()
    }

    /// Test seam — same idiom as AudioGraphOwner.authStatusProbe (line 132).
    internal var authStatusProbe: (@Sendable () -> AVAuthorizationStatus)?
}
```

**`VisionDegradationReason` enum** mirrors `DegradationReason` exactly
(`packages/Voice/Sources/Voice/AudioGraph/DegradationReason.swift` lines 9-13):

```swift
public enum VisionDegradationReason: Sendable, Equatable {
    case cameraDenied                  // RESEARCH §10
    case midSessionRevoked             // AVCaptureSessionRuntimeErrorNotification
}
```

---

### 2.12 `packages/Vision/Sources/Vision/PresenceDetector.swift`

**Analog:** `/Users/james.maes/Git.Local/kof22/Jarvis/packages/Voice/Sources/Voice/WakeWord/WakeWordDAG.swift`
(actor + detached pull-loop Task + paused/preserve state + emits transitions on a stream)

**Pattern reuse:**
- `actor` with `nonisolated let presenceStream: AsyncStream<PresenceEvent>`
- `Task.detached` pull loop reading frames (or sample buffers) from `CaptureSession`
- Edge-triggered emission: only yield on `.present↔.absent` transitions, not every frame
- 2-second debounce (RESEARCH §9)
- `pause()` / `resume()` for the D-12 disable-presence toggle

**Excerpt** (`WakeWordDAG.swift` lines 40-134):

```swift
public actor PresenceDetector {
    public nonisolated let presenceStream: AsyncStream<PresenceEvent>

    private let captureSession: CaptureSession
    private let streamCont: AsyncStream<PresenceEvent>.Continuation
    private var feedTask: Task<Void, Never>?
    private var paused: Bool = false
    private var lastEmitted: Presence = .unknown
    private var lastTransitionAt: Date = .distantPast

    private static let debounce: TimeInterval = 2.0     // RESEARCH §9
    private static let absentSecondaryThreshold: TimeInterval = 5 * 60  // D-11

    public init(captureSession: CaptureSession) {
        self.captureSession = captureSession
        let (stream, cont) = AsyncStream<PresenceEvent>.makeStream()
        self.presenceStream = stream
        self.streamCont = cont
    }

    public func start() async {
        feedTask?.cancel()
        feedTask = Task.detached { [weak self] in
            // Pull frames from captureSession.frameStream; for each frame,
            // run VNDetectFaceRectanglesRequest, classify present/absent,
            // edge-trigger debounced.
            // (Body mirrors WakeWordDAG.start ring-feed loop lines 71-101)
        }
    }

    public func pause() async { paused = true }   // D-12 disable-presence
    public func resume() async { paused = false }
    public func cancel() async {
        feedTask?.cancel()
        feedTask = nil
        streamCont.finish()
    }
}
```

**`PresenceEvent` enum** mirrors `WakeWordEvent`
(`OpenWakeWordSession.swift` lines 208-211 — only one case; tiny):

```swift
public enum PresenceEvent: Sendable, Equatable {
    case transition(to: Presence, at: Date, debounced: TimeInterval)
}

public enum Presence: Sendable, Equatable {
    case present
    case absent(since: Date)
    case unknown
}
```

---

### 2.13 `packages/Vision/Sources/Vision/PresenceSignalBus.swift`

**Analog:** `/Users/james.maes/Git.Local/kof22/Jarvis/packages/Voice/Sources/Voice/WakeWord/WakeWordDAG.swift`
line 48 — `public nonisolated let wakeWordStream: AsyncStream<WakeWordEvent>`

**Pattern:** Read-only event bus. The bus is just the AsyncStream end of the
detector. No subscriber registry; consumers (HudStateCoordinator extension,
ContextBuilder) hold their own iterator.

**S-7 ENFORCEMENT (architectural guard):** Add a CI script
`scripts/check-presence-vision-isolation.sh` modeled on
`scripts/check-single-writer-hudstate.sh` (existing — read it lines 1-43).

The check searches for any `import Voice` or `import AgentOrchestrator`
**from any file under `packages/Vision/Sources/`** and fails the build if
found:

```bash
HITS=$(grep -rn '^import \(Voice\|AgentOrchestrator\)' packages/Vision/Sources/ \
    --include='*.swift' 2>/dev/null || true)
if [[ -n "$HITS" ]]; then
    echo "VISION-03 violation: Vision must not depend on Voice or AgentOrchestrator:" >&2
    echo "$HITS" >&2
    exit 1
fi
exit 0
```

This is `S-7` (compile-time package boundary as architectural guard) — same
pattern Phase 5 used to guard the HUD-08 single-writer invariant.

---

### 2.14 `packages/Vision/Sources/Vision/DisablePresence.swift`

**Analog:** `/Users/james.maes/Git.Local/kof22/Jarvis/packages/Voice/Sources/Voice/Control/MuteWakeWord.swift`

**Pattern (D-12: clone verbatim):** Replace every `wakeWord` with `presence` and
`controller` (VoiceController) with `presenceDetector` (PresenceDetector).
Persist with key `features.vision.presenceDisabled` (mirrors
`features.voice.wakeWordMuted` lines 22, 46, 85).

**Full pattern** (`MuteWakeWord.swift` lines 17-119, abbreviated):

```swift
@MainActor
public final class DisablePresence {
    private static let defaultsKey = "features.vision.presenceDisabled"
    private let presenceDetector: PresenceDetector
    private var menuItem: NSMenuItem?
    private var isDisabled: Bool = false

    public init(
        presenceDetector: PresenceDetector,
        menuBarMenu: NSMenu
    ) {
        self.presenceDetector = presenceDetector
        isDisabled = UserDefaults.standard.bool(forKey: Self.defaultsKey)

        let item = NSMenuItem(
            title: "Disable Presence",
            action: #selector(handleToggle),
            keyEquivalent: ""
        )
        item.target = self
        item.state = isDisabled ? .on : .off
        menuBarMenu.addItem(item)
        self.menuItem = item

        // Apply persisted state on startup.
        if isDisabled {
            Task { [weak self] in
                guard let self else { return }
                await self.presenceDetector.pause()
            }
        }
    }

    @objc private func handleToggle() {
        isDisabled.toggle()
        UserDefaults.standard.set(isDisabled, forKey: Self.defaultsKey)
        menuItem?.state = isDisabled ? .on : .off
        Task { [weak self] in
            guard let self else { return }
            if self.isDisabled { await self.presenceDetector.pause() }
            else                { await self.presenceDetector.resume() }
        }
    }
}
```

---

### 2.15 `packages/Vision/Sources/Vision/FrameAttachCoordinator.swift`

**Status:** **HYBRID — see §4 risk #3.** No single in-tree analog covers the full
capture → confirm → send pipeline. Compose from three:

| Sub-flow | Source analog |
|----------|---------------|
| Capture (single frame from `CaptureSession`) | `packages/Voice/Sources/Voice/AudioGraph/AudioGraphOwner.swift` (frame pull idiom) |
| Confirm modal (HUD thumbnail + `[Send] / [Cancel]`) | `App/HUD/HUDBannerCoordinator.swift` (priority queue + dismiss) — but the confirmation UI is **NEW**; HUDBannerCoordinator only handles text banners, not images. Planner picks design per CONTEXT.md "Claude's Discretion". Recommended: a separate `FrameConfirmationPanel` modeled on `App/HUD/HUDBannerPanel.swift`, hosting a SwiftUI thumbnail view, with a 2-second auto-cancel timer (D-14). |
| Send (vision-enabled `LLMProvider.stream(...)`) | `packages/AgentCore/Sources/AgentOrchestrator/AgentOrchestrator.swift` lines 215-225 (provider.stream call site) |

**Send-call pattern excerpt** (`AgentOrchestrator.swift` lines 215-225, adapted
for the new multimodal signature added in §3 of modifications):

```swift
let stream = provider.stream(
    messages: messages,
    images: [downscaledImageBlock],          // NEW — see §3.1 LLMProvider extension
    tools: [],                               // vision turn is single-shot, no tools yet
    toolChoice: .none,
    model: visionModelFor(tier: .t1),        // gemma4:31b for T1; T2/T3 fallback
    maxOutputTokens: perTurn.maxOutputTokens(),
    cacheHints: nil
)
```

---

### 2.16 `packages/Vision/Sources/Vision/VllmMlxProvider.swift`

**Analog:** `/Users/james.maes/Git.Local/kof22/Jarvis/packages/AgentCore/Sources/OllamaProvider/OllamaProvider.swift`

**Pattern:** vllm-mlx exposes an OpenAI/Anthropic-compatible HTTP server at
`http://127.0.0.1:<port>/v1/chat/completions`. RESEARCH-mentioned `useOpenAICompat` codepath in `OllamaProvider` is **directly applicable** — the
SSE decoder (`OpenAICompatDecoder.swift`) handles it. The new `VllmMlxProvider`
is essentially `OllamaProvider(baseURL: vllmMlxURL, useOpenAICompat: true)`.

**Excerpt** (`OllamaProvider.swift` lines 21-58):

```swift
public actor VllmMlxProvider: LLMProvider {
    private let baseURL: URL                  // http://127.0.0.1:<port>
    private let session: URLSession

    public init(baseURL: URL, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.session = session
    }

    public nonisolated func stream(
        messages: [LLMMessage],
        images: [ImageBlock] = [],            // §3.1 multimodal extension
        tools: [ToolSchema],
        toolChoice: ToolChoice,
        model: ModelID,
        maxOutputTokens: Int,
        cacheHints: CacheHints?
    ) -> AsyncThrowingStream<LLMEvent, Error> {
        // Body mirrors OllamaProvider.run lines 59-167 with the OpenAI-compat
        // path forced (path == "/v1/chat/completions"); request body must
        // include the `images` field per OpenAI's vision request shape:
        //   "content": [{"type":"text", "text":...}, {"type":"image_url", ...}]
        ...
    }
}
```

**Decision:** Whether to ship a separate `VllmMlxProvider` actor OR extend
`OllamaProvider` with a "vision" config. Recommend the former — Vision
package owns its own provider so the **VISION-03 boundary (S-7)** is preserved
naturally (Vision doesn't depend on `packages/AgentCore/Sources/OllamaProvider/*`,
just on the `LLMProvider` protocol from `AgentCore`).

---

### 2.17 `packages/Vision/Sources/Vision/VllmMlxSidecar.swift`

**Status:** **PARTIAL — see §4 risk #2.** The spawn half mirrors
`ChildSpawnGate`; the HTTP server lifecycle (start / health-check / restart)
is greenfield.

**Spawn excerpt — copy from** `/Users/james.maes/Git.Local/kof22/Jarvis/packages/MCP/Sources/MCP/ChildSpawnGate.swift` lines 33-90:

```swift
// Before Process.run() for the vllm-mlx daemon:
try await ChildSpawnGate.shared.prepare()    // FD_CLOEXEC sweep

let proc = Process()
proc.executableURL = vllmMlxBinary
proc.arguments = ["--model", "Qwen/Qwen3.5-35B-A3B-VL", "--port", "8001"]
proc.environment = ChildSpawnGate.minimalEnvironment   // PATH only — no parent env
proc.standardInput = nil
proc.standardOutput = stderrPipe
proc.standardError = stderrPipe
try proc.run()
```

**Health-check / warmup probe pattern — copy idiom from**
`packages/Voice/Sources/Voice/TTS/OrpheusTTS.swift` lines 35-58 (model load is
the warmup gate; subsequent calls assume model is loaded):

```swift
public actor VllmMlxSidecar {
    private var process: Process?
    private let healthURL: URL              // http://127.0.0.1:<port>/health

    /// Start the daemon and wait for /health to return 200 OK.
    /// Bounded by 60 s; timeout → throw.
    public func start() async throws {
        // 1. ChildSpawnGate.prepare() (above)
        // 2. proc.run()
        // 3. poll /health every 500 ms, up to 120 attempts (60 s)
        for attempt in 0..<120 {
            if Task.isCancelled { throw VisionError.cancelled }
            if let ok = try? await pingHealth(), ok { return }
            try await Task.sleep(for: .milliseconds(500))
        }
        throw VisionError.sidecarStartupTimeout
    }

    public func shutdown() async {
        process?.terminate()    // SIGTERM; vllm-mlx handles graceful shutdown
        process = nil
    }
}
```

**Lifetime ownership:** `AppDelegate.installVision()` retains the
`VllmMlxSidecar` strongly; `applicationWillTerminate` calls `shutdown()`
(mirror `voiceInstallTask` ownership in `AppDelegate.swift` lines 154-158, 339-348).

---

### 2.18 `packages/MCP/Sources/JarvisMCP/tools/SearchMemoryTool.swift` (and the other two new tools)

**Analog:** `/Users/james.maes/Git.Local/kof22/Jarvis/App/MCP/MCPRuntimeWiring.swift` lines 89-157
(production builder: `client.register(...)` + `registry.register(toolName:...)` for each tool)

**Pattern reuse:** All three new tools (`search_memory`, `search_conversation`,
`forget_fact`) are **in-process tools, not stdio helpers**. Unlike the Phase 5
`mcp-time` / `mcp-clipboard` / `mcp-applescript` that ship as nested `.app`
helpers, the memory tools have direct access to the in-process `MemoryStore`
and shouldn't go through MCP stdio at all.

**Two design options for the planner:**

**Option A — In-process tool dispatcher path:** Extend `ToolRegistry` /
`ToolDispatcher` so memory tools register at the dispatcher layer without a
spawned helper. Simpler; bypasses stdio framing. Recommended for memory tools
since they're entirely local.

**Option B — Stdio helper:** Build a fourth `mcp-memory.app` helper that opens
its own SQLite read connection (per RESEARCH §11 / RESEARCH §13 — separate
read connections are safe with WAL). Heavier; matches the existing tool
shape exactly.

Whichever path is chosen, the registration call site in `MCPRuntimeWiring.build`
(lines 99-119) is the same — three additional `register(toolName:...)` calls
slot in alongside `get_time` / `get_clipboard` / `run_applescript`:

```swift
registry.register(toolName: "search_memory", serverName: "in-process", requiresConfirmation: false)
registry.register(toolName: "search_conversation", serverName: "in-process", requiresConfirmation: false)
registry.register(toolName: "forget_fact", serverName: "in-process", requiresConfirmation: true)
// forget_fact is destructive (closes valid_to + sets forgotten_at flag) — D-02. Confirmation gate keeps users in control.
```

---

### 2.19 `packages/Replay/Sources/Replay/ReplayEvent.swift` (modified)

**Pattern:** Extend the existing enum + `encoded()` switch.

**Excerpt** (modify `ReplayEvent.swift` lines 35-46 + 57-96):

```swift
public enum ReplayEvent: Sendable {
    case userInput(Data)
    case textDelta(String)
    case thinkingDelta(String)
    case toolCallRequested(id: String, name: String, argsJSON: Data)
    case toolResultFull(toolUseId: String, bytes: Data)
    case usage(Data)
    case stopReason(String)
    case turnEnd
    case hudEvent(Data)
    case error(Data)
    // Phase 7 (D-05 + MEM-08):
    case memoryMutation(MemoryOp)             // ADD/UPDATE — DevOverlay row
    case memoryRetrieval(FactRef)             // search_memory → DevOverlay row
}

// Schema.swift:
public enum ReplayEventKind: String, Sendable {
    // ... existing 10 cases ...
    case memoryMutation = "memory_mutation"
    case memoryRetrieval = "memory_retrieval"
}

// encoded() extension — add two cases:
case .memoryMutation(let op):
    let (kind, bytes) = op.encoded()                          // delegate to MemoryOp
    return (ReplayEventKind.memoryMutation.rawValue, bytes)
case .memoryRetrieval(let ref):
    let payload = try? JSONEncoder().encode(ref)
    return (ReplayEventKind.memoryRetrieval.rawValue, payload ?? Data())
```

This is `S-9` — extension by case addition, no breaking changes to the existing 10 cases.

---

### 2.20 `App/AppDelegate.swift` `installMemory()` + `installVision()`

**Analog:** `installVoice()` at `App/AppDelegate.swift` lines 351-446.

**Pattern (S-5):** Each new subsystem is a separate `installX()` async function
spawned from `applicationWillFinishLaunching` step 11+. Each:

1. Builds dependencies (DB URL, model paths, etc.)
2. Catches "missing models / TCC denied / sidecar binary absent" non-fatally
3. Wires test seams + adapters before calling `start()`
4. Stores the actor on a strong property of AppDelegate
5. Logs success/failure via `systemLogger`

**Excerpt** (compose from `installVoice` lines 370-446 — already the canonical pattern):

```swift
@MainActor
private func installMemory() async {
    // 1. Construct MemoryStore (loads vec0.dylib + runs schema migration).
    let dbURL = configFileURL().deletingLastPathComponent().appendingPathComponent("jarvis.db")
    let store: MemoryStore
    do {
        store = try MemoryStore(databaseURL: dbURL)
    } catch {
        systemLogger?.warning("installMemory: store init failed (vec0 missing?): \(String(describing: error))")
        return
    }
    self.memoryStore = store

    // 2. EmbeddingClient (talks to local Ollama).
    let embedder = EmbeddingClient()
    self.memoryEmbedder = embedder

    // 3. Extractor (uses OllamaProvider with qwen2.5-coder:32b).
    let extractorProvider = OllamaProvider(baseURL: URL(string: "http://127.0.0.1:11434")!)
    let extractor = Extractor(provider: extractorProvider)

    // 4. MemoryOrchestrator (background channel consumer).
    let memoryOrch = MemoryOrchestrator(extractor: extractor, store: store, bus: memoryBus)
    await memoryOrch.start()
    self.memoryOrchestrator = memoryOrch

    // 5. Wire MemoryExtractionCoordinator to AgentOrchestrator.events.
    //    (AgentOrchestrator wiring is Phase 6+ — for P7 this means subscribing
    //    to the existing orchestrator's event channel.)
    let coord = MemoryExtractionCoordinator(memoryOrchestrator: memoryOrch)
    self.memoryExtractionCoordinator = coord
    await coord.start(orchestratorEvents: agentOrchestrator.events,
                      turnContent: { turnId in await self.memoryStore?.turnContent(for: turnId) })

    systemLogger?.info("installMemory: MemoryOrchestrator started")
}

@MainActor
private func installVision() async {
    let (degStream, degCont) = AsyncStream<VisionDegradationReason>.makeStream()
    let captureSession = CaptureSession(degradationContinuation: degCont)
    self.captureSession = captureSession

    // Wire degradationStream → HUDBannerCoordinator (S-4).
    self.cameraDegradationTask = Task { @MainActor [weak self] in
        for await reason in degStream {
            switch reason {
            case .cameraDenied:
                self?.bannerCoordinator?.enqueue(.cameraDenied)   // Add preset to BannerContent
            case .midSessionRevoked:
                self?.bannerCoordinator?.enqueue(.cameraRevoked)
            }
        }
    }

    // PresenceDetector — D-09: on by default after first TCC grant.
    let detector = PresenceDetector(captureSession: captureSession)
    self.presenceDetector = detector
    await detector.start()

    // DisablePresence menu-bar toggle — D-12.
    if let menu = menuBarController?.contextMenu {
        self.disablePresence = DisablePresence(presenceDetector: detector, menuBarMenu: menu)
    }

    // FrameAttachCoordinator — D-13/D-14.
    let frameAttach = FrameAttachCoordinator(
        captureSession: captureSession,
        confirmationPresenter: bannerCoordinator,    // see §4 risk #3
        provider: vllmMlxProvider                     // T2 — falls back to T1 (gemma4) on init failure
    )
    self.frameAttachCoordinator = frameAttach

    systemLogger?.info("installVision: capture + presence + frame-attach wired")
}
```

---

## §3. Shared Patterns (S-N)

These are cross-cutting patterns the planner should apply to multiple Phase 7
files. Assigned numeric IDs S-1..S-9 (matching CONTEXT.md `Established Patterns`).

### S-1: Actor-owned resource lifecycle
**Source:** `packages/Voice/Sources/Voice/AudioGraph/AudioGraphOwner.swift` lines 32-114
**Apply to:** `MemoryStore`, `CaptureSession`, `PresenceDetector`, `MemoryOrchestrator`, `VllmMlxSidecar`
**Shape:** `actor` with `open()` / `start()` / `shutdown()` lifecycle, watcher Tasks cancelled in shutdown, `(@Sendable () async -> Void)?` slots for downstream consumers.

### S-2: AsyncStream / AsyncChannel event bus
**Source:** `packages/Voice/Sources/Voice/WakeWord/WakeWordDAG.swift` lines 48, 54-56
**Apply to:** `PresenceSignalBus`, `MemoryEventBus`
**Shape:** `public nonisolated let stream: AsyncStream<Event>` + `streamCont: AsyncStream<Event>.Continuation` initialized in init via `AsyncStream<Event>.makeStream()`.

### S-3: UserDefaults-persisted menu-bar toggle
**Source:** `packages/Voice/Sources/Voice/Control/MuteWakeWord.swift` (entire file, 119 lines)
**Apply to:** `DisablePresence` (D-12 verbatim clone)
**Shape:** `@MainActor final class` + `private static let defaultsKey: String` + read on init + apply persisted state at startup + `@objc` toggle handler updating both `UserDefaults` and the actor.

### S-4: HUDBannerCoordinator graceful-denial
**Source:** `App/HUD/HUDBannerCoordinator.swift` lines 13-95 + `BannerContent.swift` lines 33-72 (presets)
**Apply to:** Camera TCC denial banner (`BannerContent.cameraDenied`), Camera mid-session revocation banner (`BannerContent.cameraRevoked`)
**Shape:** Add new presets to `BannerContent` extension; subsystem yields a `VisionDegradationReason` on its degradationStream; AppDelegate's install function wires the stream to `bannerCoordinator.enqueue(.cameraDenied)`.

### S-5: `installX()` function pattern in AppDelegate
**Source:** `App/AppDelegate.swift` lines 351-446 (`installVoice`)
**Apply to:** `installMemory()`, `installVision()`
**Shape:** Async function called from a Task in step 11+ of `applicationWillFinishLaunching`; non-fatal on missing dependencies (logs and returns); stores actors on AppDelegate strong properties.

### S-6: Single emission site for atomic events
**Source:** `packages/Voice/Sources/Voice/TTS/TTSInterrupt.swift` lines 95-100 (`.ttsStopped` single-emit grep gate)
**Apply to:** `MemoryStore.applyOp` is the only `memory.mutated` emit site
**Shape:** Document the invariant in the docstring; add a `scripts/check-single-memory-mutated-emit.sh` modeled on `scripts/check-single-writer-hudstate.sh`.

### S-7: Compile-time package boundary as architectural guard
**Source:** `scripts/check-single-writer-hudstate.sh` (entire file, 43 lines) + Voice/Package.swift dependency list (lines 21-37) which excludes `AgentOrchestrator`
**Apply to:** Vision package MUST NOT depend on Voice or AgentOrchestrator; `scripts/check-presence-vision-isolation.sh` enforces in CI
**Shape:** Two layers — (1) `packages/Vision/Package.swift` declares no dependency on `Voice` or `AgentOrchestrator`; (2) the new lint script greps Vision sources for forbidden imports.

### S-8: Env-gated scaffold-time perf probes
**Source:** `packages/Voice/Tests/VoiceTests/OrpheusTTFATests.swift` lines 26-29
**Apply to:** Memory regression-test corpus (RESEARCH Open Q #3); Vision-model TTFA probes (Gemma 4 first-token latency, vllm-mlx warmup probe)
**Shape:** `try XCTSkipUnless(ProcessInfo.processInfo.environment["JARVIS_REAL_MODELS"] == "1", "...")` at the top of every probe test.

### S-9: ReplayEvent enum-case extension
**Source:** `packages/Replay/Sources/Replay/ReplayEvent.swift` (the entire enum + extension structure)
**Apply to:** New `.memoryMutation(MemoryOp)` and `.memoryRetrieval(FactRef)` cases + matching `ReplayEventKind` rawValues
**Shape:** Add cases to enum, add rawValues to ReplayEventKind, add encoded() switch arms — no schema migration since `events.kind` column is already TEXT.

---

## §4. Highest-Risk Scaffolds (no analog or hybrid)

These five surfaces have no clean in-tree analog. Planner should call them
out as scaffold-time risks and consider env-gated probes (S-8) for each.

### Risk #1: `MemoryStore` extension loading via direct C API

**File:** `packages/Memory/Sources/Memory/SQLiteStore.swift` (the
`loadVecExtension()` private method)

**Why it's risky:** No in-tree pattern exists for `sqlite3_enable_load_extension`
+ `sqlite3_load_extension`. The current `SQLiteConnection` (`packages/Replay/Sources/Replay/SQLiteConnection.swift`) opens with `SQLITE_OPEN_FULLMUTEX` and exposes `execute` / `exec` / `query` — but its OpaquePointer handle is **private**, so loading a runtime extension requires either:
- adding a `withHandle(_ body: (OpaquePointer) -> Void)` accessor to `SQLiteConnection`, OR
- moving the load logic into Replay (uncomfortable: Replay is a Phase 4 package, doesn't know about Memory).

**Mitigation:** Add the `withHandle` accessor; document that Memory is the
only consumer; keep the OpaquePointer behind the closure so it can't escape.
Cite RESEARCH §2 (Apple SQLite C-API docs) in the plan; assert `SELECT
vec_version();` succeeds at the bottom of `init()` (RESEARCH P1 mitigation).

**Codesigning footgun (RESEARCH P7):** `vec0.dylib` must be **same-team
codesigned** alongside the main app. Prefer this over the
`com.apple.security.cs.disable-library-validation` entitlement, which weakens
Hardened Runtime. The Phase 1 codesigning script (`scripts/codesign.sh`)
already follows the inside-out rule — extend it to cover the bundled `vec0.dylib`.

---

### Risk #2: vllm-mlx sidecar lifecycle

**File:** `packages/Vision/Sources/Vision/VllmMlxSidecar.swift`

**Why it's risky:** Spawn half mirrors `ChildSpawnGate` exactly (S-1 +
existing pattern). The HTTP-server lifecycle (start, health-check polling,
graceful shutdown, restart on crash) is **greenfield**. The closest in-tree
warmup-probe pattern is `OrpheusTTS.init` (`packages/Voice/Sources/Voice/TTS/OrpheusTTS.swift` lines 50-58) which loads an MLX model — but that's an in-process model load, not an HTTP daemon.

**Open questions for the planner:**
- launchd-managed (auto-start on login + auto-restart on crash) vs. spawned
  by main app?
- If main-app-spawned, who owns retrying on health-check failure?
  Recommended: bounded 60s warmup window in `start()`; after that fail to T1 (Gemma 4 / Ollama).
- vllm-mlx version pinning + binary distribution (build from source vs.
  ship a prebuilt binary in `Contents/Helpers/`)?

**Mitigation:** Treat T2 as best-effort. If sidecar startup fails at
`installVision()`, set `vllmMlxProvider = nil` and fall through to T1
(`gemma4:31b` via Ollama) for **all** vision turns until next launch.
DevOverlay surface: `vision.tier_in_use = "T1"` so the user knows.

---

### Risk #3: HUD camera-icon button + frame confirmation thumbnail

**File:** `App/HUD/FrameAttachAffordance.swift` (NEW, name TBD by planner)

**Why it's risky:** No in-tree analog. Existing HUD surfaces (`HudStateCoordinator`, `HUDBannerPanel`, `JarvisHUDPanel`) handle text banners + R3F particle ring state. The frame-attach UX needs:
- A small camera-icon button rendered during a turn (R3F overlay?
  AppKit overlay panel?)
- A captured-frame thumbnail with `[Send] / [Cancel]` (must render an
  arbitrary image — neither `HUDBanner` nor `HUDBannerPanel` does that today)

**Mitigation:** Per CONTEXT.md "Claude's Discretion", planner picks the design.
Recommended: a separate `FrameConfirmationPanel` (subclass of
`HUDBannerPanel`) hosting a SwiftUI view with the thumbnail. 2-second auto-
cancel timer (D-14) lives in `FrameAttachCoordinator`. The camera-icon button
can be a toolbar item on `JarvisHUDPanel` or an R3F element — defer to planner.

---

### Risk #4: `LLMProvider` multimodal protocol extension

**File:** `packages/AgentCore/Sources/AgentCore/LLMProvider.swift` (modified)

**Why it's risky:** Adding `images: [ImageBlock]` to the protocol method
signature is **source-breaking** for every existing conformer. Currently
the protocol is conformed to by:

- `AnthropicProvider` (`packages/AgentCore/Sources/AnthropicProvider/AnthropicProvider.swift` line 23)
- `OllamaProvider` (`packages/AgentCore/Sources/OllamaProvider/OllamaProvider.swift` line 21)
- `MockLLMProvider` in tests (`packages/AgentCore/Tests/AgentOrchestratorTests/MockLLMProvider.swift`)

Plus the new `VllmMlxProvider`.

**Mitigation:** Two options for the planner:
- **Option A:** Add a default-empty parameter (`images: [ImageBlock] = []`)
  on a NEW method, leaving the existing single-modal `stream(...)` intact as
  a convenience wrapper. **Less disruptive but doubles the protocol surface.**
- **Option B:** Change the protocol method directly; touch all four conformers
  + ~10 test fixtures. **Cleaner but a single sweeping diff.**

Recommend Option B — protocol extensions in Swift can carry a default
implementation that forwards to the existing single-modal call when
`images.isEmpty`, so non-vision providers don't need separate logic until
they care.

**Encoder coupling:** Each conformer's request-body encoder
(`packages/AgentCore/Sources/AnthropicProvider/RequestBody.swift`,
`packages/AgentCore/Sources/OllamaProvider/OllamaRequestBody.swift`) needs a
new image-block path. Per RESEARCH §11 the Anthropic format is:
`{"type":"image","source":{"type":"base64","media_type":"image/jpeg","data":"..."}}`.
Per OpenAI-compat the format is `{"type":"image_url","image_url":{"url":"data:image/jpeg;base64,..."}}`.

---

### Risk #5: VISION-03 compile-time boundary enforcement

**File:** `scripts/check-presence-vision-isolation.sh` (NEW)

**Why it's risky:** Easy to forget. The whole point of Phase 7's vision
architecture is that presence signals **never** trigger TTS or `runTurn`.
A future refactor adding `import Voice` to a `PresenceSignalBus` subscriber
silently breaks the invariant. The compiler won't catch it as long as the
SPM dep is removed only at the `Vision/Package.swift` level — but a Phase 8+
refactor adding `Vision -> Voice` to Package.swift would be silent.

**Mitigation:** Two layers, both required:
1. `packages/Vision/Package.swift` declares NO dependency on `Voice` or
   `AgentOrchestrator` (only `Logging` + `AgentCore`).
2. `scripts/check-presence-vision-isolation.sh` greps for forbidden imports
   in Vision sources. Runs as a CI gate alongside
   `check-single-writer-hudstate.sh` (existing — copy that script's structure
   verbatim).

The grep gate is the **higher-confidence** of the two — even if a future
maintainer accidentally adds `Voice` to `Package.swift`, the lint catches
the symptom.

---

## §5. No analog (true greenfield)

| File | Reason |
|------|--------|
| `App/HUD/FrameConfirmationPanel.swift` (or equivalent) | First image-rendering HUD modal. Planner discretion per CONTEXT.md. |

Everything else has at least a partial in-tree pattern.

---

## Metadata

**Analog search scope:**
`packages/{Voice,AgentCore,MCP,Replay,Shell,Bus,DevOverlay,Logging,Config,Keychain}/Sources/`,
`App/`, `scripts/`, `App/MCP/`.

**Files scanned:** 60 Swift files + 8 shell scripts + 6 `Package.swift` files + Info.plist.

**Pattern extraction date:** 2026-04-28.

**Skipped:** No `.claude/skills/` or `.agents/skills/` directory present at
project root (verified). `~/.ai/` global rules respected (no source edits;
PATTERNS.md is the only file written).
