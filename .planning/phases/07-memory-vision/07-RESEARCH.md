# Phase 7: Memory + Vision — Research

**Researched:** 2026-04-22
**Domain:** Local memory (SQLite + FTS5 + sqlite-vec + Ollama embeddings + mem0) and vision (AVFoundation + Vision presence signals + optional Opus 4.7 frame attach)
**Confidence:** HIGH (stack 100% pre-locked in CLAUDE.md / RESEARCH-DELTAS.md)

## Summary

All stack is pre-decided. Non-obvious work: (1) loading sqlite-vec via direct C API, (2) `EMBEDDING_DIM=768` as a single shared symbol with a test assertion, (3) `.memoryExtraction` as a background TurnSource on a separate orchestrator with a bounded job queue (MEM-06 — never block `turnEnd`), (4) architecturally preventing any presence→TTS code path (VISION-03), and (5) FTS5+vec hybrid search. Opus 4.7 image tokens are expensive — cap to single-frame, user-initiated (VISION-04). Primary risks: dimension drift and leaked WAL FDs to MCP helpers.

**Primary recommendation:** `JarvisMemory` package (`SQLiteStore`, `EmbeddingClient`, `Extractor`, `MemoryOrchestrator`, `HybridSearch`). `JarvisVision` package with `PresenceSignalBus` that has zero dependency on TTS or `Orchestrator.runTurn`.

## Architectural Responsibility Map

| Capability | Primary Tier | Rationale |
|---|---|---|
| SQLite + sqlite-vec load | Swift/Native | Extension load is C-API only, in-process |
| Embeddings + extraction | Swift → Ollama (localhost) | Fully local, HTTP client |
| Background extraction queue | Swift actor + AsyncChannel | Must not block turnEnd |
| FTS5+vec hybrid query | SQLite in-process | Single SQL with CTE |
| Presence detection | AVFoundation + Vision | On-device, throttled |
| Frame attach (VISION-04) | Swift → AnthropicProvider | User-initiated only |
| DevOverlay "memory updated" | Swift → WKWebView bridge | Per ADD/UPDATE |

## User Constraints (from CLAUDE.md — authoritative)

### Locked Decisions
- SQLite + FTS5 + `sqlite-vec v0.1.10-alpha.3` via `sqlite3_enable_load_extension` + `sqlite3_load_extension` (direct C API, no Swift wrapper package).
- `EMBEDDING_DIM = 768` single shared Swift symbol; test asserts extractor + schema import the same constant.
- Embeddings: `nomic-embed-text` via Ollama (768-dim, local).
- Extractor: `qwen2.5-coder:32b` via Ollama. Qwen3 banned (RESEARCH-DELTAS D3).
- Temporal validity: `valid_from` / `valid_to`; superseded facts never deleted.
- Extraction on `.memoryExtraction` TurnSource, separate orchestrator, bounded queue, non-blocking on `turnEnd`.
- DevOverlay "memory updated" row per ADD/UPDATE (MEM-08).
- Vision: Camera TCC with graceful denial (VISION-01); presence SIGNAL ONLY (VISION-02); no code path presence→TTS (VISION-03); optional single-frame attach on user-initiated turn (VISION-04).
- No user data leaves machine; network-sandbox test required (MEM-04).

### Claude's Discretion
- Internal schema shape beyond MEM-01/02/05 invariants; bounded queue size + concurrency; hybrid search ranking weights; presence debounce thresholds; module boundaries.

### Deferred Ideas (OUT OF SCOPE)
- Cross-device memory sync; alt vector indexes (HNSW, LanceDB); cloud embedding fallbacks; face identity; continuous video understanding.

## Phase Requirements

| ID | Description | Support |
|----|-------------|---------|
| TEXT-03 | History browsable in-session; turns queryable | §1, §8 |
| VISION-01 | Camera TCC + graceful denial | §10 |
| VISION-02 | Presence SIGNALS only | §9 |
| VISION-03 | No presence→TTS code path | §9, P5 |
| VISION-04 | Single-frame attach to Opus on user turn | §11 |
| MEM-01 | SQLite WAL + FTS5 + vec via C API | §1, §2 |
| MEM-02 | `EMBEDDING_DIM=768` shared | §3 |
| MEM-03 | `nomic-embed-text` via Ollama | §4 |
| MEM-04 | mem0 ADD/UPDATE/NOOP local | §5 |
| MEM-05 | `valid_from`/`valid_to` temporal | §6 |
| MEM-06 | Background `.memoryExtraction`, bounded, non-blocking | §7 |
| MEM-07 | FTS5+vec retrieval | §8 |
| MEM-08 | DevOverlay row per ADD/UPDATE | §13 |

---

## 1. SQLite + WAL + FTS5 + sqlite-vec schema

DB at `~/Library/Application Support/Jarvis/jarvis.db`. Open with `SQLITE_OPEN_READWRITE|CREATE|NOMUTEX`. Then: `PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL; PRAGMA foreign_keys=ON;`.

```sql
-- Raw turns (TEXT-03 browsing + replay corpus)
CREATE TABLE turns (
  id INTEGER PRIMARY KEY, session_id TEXT NOT NULL,
  role TEXT NOT NULL,           -- 'user'|'assistant'|'tool'
  content TEXT NOT NULL,
  source TEXT NOT NULL,          -- .userText|.wakeWord|.pushToTalk|.memoryExtraction
  created_at INTEGER NOT NULL);
CREATE INDEX idx_turns_session ON turns(session_id, created_at);

-- Extracted facts (mem0)
CREATE TABLE facts (
  id INTEGER PRIMARY KEY,
  subject TEXT NOT NULL, predicate TEXT NOT NULL, object TEXT NOT NULL,
  source_turn_id INTEGER REFERENCES turns(id),
  valid_from INTEGER NOT NULL, valid_to INTEGER,   -- NULL = active
  superseded_by INTEGER REFERENCES facts(id),
  created_at INTEGER NOT NULL);
CREATE INDEX idx_facts_active ON facts(subject, predicate) WHERE valid_to IS NULL;

-- FTS5 (content-table pattern; triggers sync on INS/UPD/DEL)
CREATE VIRTUAL TABLE facts_fts USING fts5(subject, predicate, object, content=facts, content_rowid=id, tokenize='unicode61 remove_diacritics 2');
CREATE VIRTUAL TABLE turns_fts USING fts5(content, content=turns, content_rowid=id, tokenize='unicode61 remove_diacritics 2');

-- Vector (sqlite-vec vec0)
CREATE VIRTUAL TABLE facts_vec USING vec0(fact_id INTEGER PRIMARY KEY, embedding FLOAT[768]);
```

Facts_vec only holds currently-active facts (removed on supersede); facts table retains history.

## 2. sqlite-vec C API load from Swift

No Swift package. Use direct sqlite3 C API. GRDB/SQLite.swift extension loaders are unreliable for this.

```swift
import SQLite3
sqlite3_enable_load_extension(db, 1)
var err: UnsafeMutablePointer<CChar>? = nil
let path = Bundle.main.path(forResource: "vec0", ofType: "dylib")!
guard sqlite3_load_extension(db, path, nil, &err) == SQLITE_OK else { /* abort */ }
sqlite3_enable_load_extension(db, 0)
```

Bundle `vec0.dylib` in `Contents/Resources/`, same-team codesigned. **Prefer same-team signing over `disable-library-validation` entitlement.** Assert `SELECT vec_version();` at open time.

## 3. EMBEDDING_DIM shared constant (MEM-02)

One symbol in `JarvisMemory/Constants.swift`:

```swift
public enum MemoryConstants { public static let embeddingDim: Int = 768 }
```

Schema migration interpolates it (`FLOAT[\(embeddingDim)]`). Extractor, embedding client, and query path all import the same symbol. Test `testBothPathsShareSymbol` asserts all consumers reference `MemoryConstants.embeddingDim` (not a local copy) — catches accidental shadowing.

## 4. nomic-embed-text via Ollama

`POST http://127.0.0.1:11434/api/embed` (not deprecated `/api/embeddings`). Body: `{"model":"nomic-embed-text","input":"..."}`. Response: `{"embeddings":[[f32,...]]}` — always 2D. Share `URLSession` with P4's `OllamaProvider`. Timeout 10s, single retry on transport error, log+skip on persistent failure (extraction is best-effort). Assert `embeddings[0].count == MemoryConstants.embeddingDim` every call.

## 5. mem0 ADD/UPDATE/NOOP (MEM-04)

After each user/assistant turn pair, send to `qwen2.5-coder:32b` with structured tool-call output (Qwen 2.5-Coder reliably produces valid tool JSON per P4 baseline).

System prompt: *"You are a memory extractor. Given a conversation turn, return operations: ADD (new durable fact), UPDATE (existing fact changed — supersede), NOOP (no memory change). Only durable personal facts (preferences, relationships, decisions, project state) — NOT trivia, ephemeral state, question content."*

Tool schema:

```json
{"name":"apply_memory_ops","parameters":{"type":"object","properties":{
  "ops":{"type":"array","items":{"type":"object","properties":{
    "op":{"enum":["ADD","UPDATE","NOOP"]},
    "subject":{"type":"string"},"predicate":{"type":"string"},"object":{"type":"string"},
    "supersedes_fact_id":{"type":"integer"}},"required":["op"]}}}}}
```

Pre-load top-K active facts for matched subjects (via FTS5 over subject) into prompt so extractor can UPDATE. Cap prior facts at ~4KB. Validate output against schema, drop invalid entries. NOOP logged at debug only (MEM-08 surfaces only ADD/UPDATE).

## 6. Temporal validity supersede (MEM-05)

**Never DELETE.** UPDATE = close-and-insert in transaction:

```sql
BEGIN;
UPDATE facts SET valid_to=:now, superseded_by=:new_id
  WHERE id=:old_id AND valid_to IS NULL;
INSERT INTO facts(subject,predicate,object,source_turn_id,valid_from,valid_to,created_at)
  VALUES(:s,:p,:o,:turn,:now,NULL,:now) RETURNING id;
-- Delete old embedding from facts_vec, insert new one
COMMIT;
```

Active queries: `WHERE valid_to IS NULL`. Point-in-time: `WHERE valid_from<=:t AND (valid_to IS NULL OR valid_to>:t)`. History: walk `superseded_by` backwards. Partial index `idx_facts_active` keeps hot path fast.

## 7. Background orchestrator (MEM-06)

`.memoryExtraction` is a `TurnSource` variant added in P4. Wire in P7:

- `MemoryOrchestrator` = separate `Orchestrator` instance configured with `OllamaProvider(model:"qwen2.5-coder:32b")`, tools = `[apply_memory_ops]` synthetic, no TTS capability.
- Main `Orchestrator` emits `.turnEnd` → `MemoryExtractionCoordinator` enqueues `(turnId, userContent, assistantContent)` into **bounded `AsyncChannel<ExtractionJob>` capacity 32**; overflow drops oldest + warns.
- Dedicated serial `Task` consumes channel (one extraction at a time — parallel would thrash 32B-model VRAM). Each job: fetch active facts, build prompt, `MemoryOrchestrator.runTurn(.memoryExtraction)`, parse/apply ops in transaction, emit DevOverlay rows.
- **Test:** fire 100 turnEnds rapidly, assert p99 `turnEnd`→next-turn-ready latency unchanged vs baseline without extraction.

## 8. FTS5 + vec hybrid search (MEM-07)

Single SQL with reciprocal rank fusion (RRF). Called by `search_memory` MCP tool.

```sql
WITH
  kw AS (SELECT fact_id, bm25(facts_fts) AS s FROM facts_fts WHERE facts_fts MATCH :q LIMIT 50),
  vc AS (SELECT fact_id, distance AS s FROM facts_vec WHERE embedding MATCH :qv AND k=50),
  fused AS (SELECT fact_id, SUM(1.0/(60+rank)) AS rrf FROM (
    SELECT fact_id, ROW_NUMBER() OVER (ORDER BY s ASC) AS rank FROM kw
    UNION ALL
    SELECT fact_id, ROW_NUMBER() OVER (ORDER BY s ASC) AS rank FROM vc
  ) GROUP BY fact_id)
SELECT f.* FROM facts f JOIN fused ON f.id=fused.fact_id
  WHERE f.valid_to IS NULL ORDER BY fused.rrf DESC LIMIT 10;
```

Query vector = `nomic-embed-text(query string)`. `vec0` requires `AND k=N` in WHERE (forgetting returns zero rows, not an error — template it). Separate `search_conversation` tool hits `turns_fts` for TEXT-03.

## 9. Vision presence detection (VISION-02/03)

Pipeline: `AVCaptureSession` 720p/15fps → `AVCaptureVideoDataOutput` → `VNDetectFaceRectanglesRequest` (on-device, free) → emit `PresenceSignal(.present|.absent, confidence, ts)` only on transitions (edge-triggered, 2s debounce). Signals flow into `PresenceSignalBus` (Combine `PassthroughSubject<PresenceSignal, Never>`).

**Architectural guard (VISION-03):** `PresenceSignalBus` is injected into `Orchestrator` as a **read-only context provider** — NOT as an event source triggering `runTurn`. `Orchestrator.runTurn` only accepts `.userText|.wakeWord|.pushToTalk|.memoryExtraction`; `.presence` is deliberately absent. `ContextBuilder` may read current presence state during a user-initiated turn and optionally include it in system prompt. **No subscriber of `PresenceSignalBus` has any reference to `TTSEngine` or `Orchestrator.runTurn`.** Enforce with compile-time package boundary: `JarvisVision` doesn't depend on `JarvisTTS` or `JarvisOrchestrator`. CI dependency-graph check fails on any `PresenceSignalBus → TTS*` path.

## 10. Camera TCC lifecycle (VISION-01)

Info.plist: `NSCameraUsageDescription`. **Do not prompt at launch** — wait for first user-initiated vision action (frame attach OR user enables presence in Settings).

```swift
switch AVCaptureDevice.authorizationStatus(for: .video) {
case .notDetermined: /* prompt on first use */
case .denied, .restricted: /* HUD banner + Settings deep link; vision features degrade gracefully */
case .authorized: /* start session lazily, stop after 30s idle */
}
```

Menu bar icon reflects camera-in-use state. `AVCaptureSessionRuntimeErrorNotification` handler degrades gracefully on mid-session revocation. Cleanup on `NSApplication.willTerminate`.

## 11. Opus 4.7 image input token cost (VISION-04)

Opus 4.7 vision tokens ≈ `(w×h)/750`. A 1024×1024 frame ≈ 1400 tokens; 1280×720 ≈ 1230. Plus the ~35% token bloat noted in CLAUDE.md. **Cap 1 frame per turn, downscale to max 1024 dim, JPEG 0.85.** Image goes in user message as `{"type":"image","source":{"type":"base64","media_type":"image/jpeg","data":"..."}}`. The 8 KB `tool_result` cap does NOT apply to image blocks.

## 12. Package layout

```
Packages/
  JarvisMemory/Sources/
    Constants.swift            # EMBEDDING_DIM (single source of truth)
    SQLiteStore.swift          # DB handle, PRAGMA, vec load
    SchemaMigration.swift      # CREATE TABLE + user_version bumps
    EmbeddingClient.swift      # Ollama /api/embed
    Extractor.swift            # mem0 prompt + schema + op apply
    MemoryOrchestrator.swift   # bounded AsyncChannel consumer
    HybridSearch.swift         # FTS5+vec RRF
  JarvisVision/Sources/
    PresenceSignalBus.swift    # Combine subject, edge-triggered
    CaptureSession.swift       # AVFoundation lifecycle
    FaceDetector.swift         # VNDetectFaceRectanglesRequest
    FrameAttach.swift          # user-initiated single-frame for VISION-04
```

`JarvisVision` has NO dependency on `JarvisTTS` or `JarvisOrchestrator` — compile-time enforcement of VISION-03.

## 13. Observability: DevOverlay "memory updated" (MEM-08)

Every ADD/UPDATE emits JSON over WKWebView bridge (`memory.mutated` channel):

```json
{"op":"ADD|UPDATE","fact":"Sarah works at Acme","factId":42,
 "supersedesFactId":17,"triggerTurnId":1234,"triggerSource":".memoryExtraction",
 "timestamp":1745308800000}
```

DevOverlay renders scrolling list (last 50). Non-debug builds log at info level but skip bridge message. NOOPs debug-only.

## Pitfalls

- **P1 sqlite-vec ABI:** dylib must match system sqlite3 on macOS 26 Tahoe. Pin `v0.1.10-alpha.3` artifact; verify `SELECT vec_version();` at open.
- **P2 Dimension drift:** swap to another embedding model with different dim → queries silently return garbage. `EMBEDDING_DIM` assertion + runtime length-check on every embedding.
- **P3 WAL FD leak:** SQLite WAL FD needs `FD_CLOEXEC`. Route all MCP helper spawns through P5's `ChildSpawnGate`. Regression risk if new spawn paths added outside the gate.
- **P4 Extraction backpressure:** Ollama stall → bounded channel overflow drops turns silently. Surface DevOverlay warning on overflow; test with deliberately-wedged Ollama.
- **P5 Presence→TTS leak (VISION-03):** any refactor injecting `TTSEngine` into a `PresenceSignalBus` subscriber is catastrophic ("agent talks when I walk by"). Enforce via CI dependency-graph check, not just code review.
- **P6 Opus 4.7 image cost:** frame auto-attach every turn would blow budget. Gate on explicit user intent/phrase heuristic.
- **P7 Hardened Runtime + dylib:** prefer same-team-signed `vec0.dylib` over `disable-library-validation`.
- **P8 FTS5 tokenizer:** default is ASCII-only. Use `unicode61 remove_diacritics 2` for international names.
- **P9 vec0 k param:** forgetting `AND k=N` returns zero rows silently. Template the query.
- **P10 Mid-session camera revocation:** macOS fires `AVCaptureSessionRuntimeErrorNotification`; handle gracefully (banner, degrade presence).

## Open Questions for Planner

1. **Session boundaries.** App lifetime vs. idle-timeout? Recommend: UUID per launch; within-session history filters `session_id`.
2. **Fact expiry policy.** Auto-expire time-bounded facts (e.g., "next week's meeting")? Recommend: no auto-expire in P7; defer.
3. **Extraction eval.** Minimal 10-scenario memory eval in P7 to catch regressions; full matrix in P8.
4. **Frame attach UI.** Button vs. phrase detection vs. both? Recommend: both, with confirm prompt before capture.
5. **Overflow policy.** Drop oldest (recommend — older turns already in `turns` table, just not distilled).
6. **Vec rebuild on model swap.** Not a P7 deliverable; document as future migration.

## Assumptions Log

| # | Claim | §  | Risk if Wrong |
|---|-------|----|---------------|
| A1 | `vec0.dylib` v0.1.10-alpha.3 same-team signable | §2 | Need `disable-library-validation` workaround |
| A2 | Ollama `/api/embed` stable (not deprecated) | §4 | Silent 404 or shape change |
| A3 | `qwen2.5-coder:32b` reliably emits valid tool calls for `apply_memory_ops` | §5 | Drops ops; needs validation + retry |
| A4 | Opus 4.7 image tokens ≈ `(w×h)/750` | §11 | Budget miscalc; measure to refine |
| A5 | `vec0` supports `FLOAT[768]` column syntax at alpha.3 | §1 | Schema fails; BLOB fallback |

## References

- [sqlite-vec — asg017/sqlite-vec](https://github.com/asg017/sqlite-vec)
- [SQLite loadable extensions](https://www.sqlite.org/loadext.html)
- [FTS5 docs](https://www.sqlite.org/fts5.html)
- [mem0](https://github.com/mem0ai/mem0)
- [Zep temporal graph](https://github.com/getzep/zep)
- [Ollama API](https://github.com/ollama/ollama/blob/main/docs/api.md)
- [nomic-embed-text](https://ollama.com/library/nomic-embed-text)
- [`VNDetectFaceRectanglesRequest`](https://developer.apple.com/documentation/vision/vndetectfacerectanglesrequest)
- [`AVCaptureDevice.authorizationStatus`](https://developer.apple.com/documentation/avfoundation/avcapturedevice/1624577-authorizationstatus)
- [Anthropic vision](https://docs.anthropic.com/en/docs/build-with-claude/vision)
- CLAUDE.md Memory Stack (authoritative); RESEARCH-DELTAS.md D3/D7
