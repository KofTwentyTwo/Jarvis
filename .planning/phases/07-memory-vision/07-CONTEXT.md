# Phase 7: Memory + Vision - Context

**Gathered:** 2026-04-27
**Status:** Ready for planning

<domain>
## Phase Boundary

Phase 7 delivers two on-device capabilities the agent gains access to inside user-initiated turns:

1. **Persistent local memory** — every conversation turn is browsable in-session; durable facts are extracted in the background via mem0-style ADD/UPDATE/NOOP into SQLite (WAL + FTS5 + sqlite-vec, 768-dim nomic-embed-text via Ollama, qwen2.5-coder:32b extractor); facts carry temporal validity (`valid_from`/`valid_to`) and are never deleted; the agent retrieves prior decisions via FTS5+vec hybrid search across all sessions; "memory updated" surfaces in DevOverlay (MEM-08).

2. **Webcam presence + optional frame attach** — Camera TCC with graceful denial; presence detection runs on by default after first TCC grant; presence is *signal-only* (VISION-03 — no code path from `PresenceSignalBus` to TTS/Orchestrator.runTurn); the agent may *reference* presence in a user-initiated turn (system-prompt enrichment + HUD ring subtle indicator); single-frame attach to a vision-capable LLM is *user-initiated* via phrase or HUD button with always-confirm; vision routes local-first via a new `LLMProvider` multimodal extension (Gemma 4 → Qwen 3.5 → Opus tiered escape).

**Zero user data leaves the machine for memory or vision** by default — every default path is local. Cloud (Opus) is reachable only on explicit user request.

</domain>

<decisions>
## Implementation Decisions

### Memory Extraction (Area 1)
- **D-01:** Auto-extract every turn pair via `.memoryExtraction` background orchestrator (researcher §7; mem0 default). Bounded `AsyncChannel` (capacity 32 per researcher) consumed by serial Task; never blocks `turnEnd`.
- **D-02:** Forgetting is via an explicit `forget_fact` MCP tool. Closes `valid_to` and sets a `forgotten_at` flag that excludes the row from active queries; preserves history per MEM-05's never-delete invariant.
- **D-03:** Extraction scope is broad — durable personal facts (preferences, relationships, decisions, project state, recurring patterns). Excludes trivia, ephemeral state, question content. mem0 system prompt as researcher §5 specifies.
- **D-04:** No private/incognito mode in P7. The forget tool is the privacy valve. Anything said IS extracted; user uses `forget_fact` to de-store. (Trades immediacy of privacy for simplicity of scope.)

### Memory Retrieval (Area 2)
- **D-05:** Every retrieval (whether agent-initiated mid-reasoning or user-initiated via `search_memory`) emits a DevOverlay row symmetric to MEM-08's extraction surface — `{op:"used", fact, factId, triggerTurnId, timestamp}` over the `memory.used` WKWebView channel. No chat-panel UI cost; debugging-friendly.
- **D-06:** Explicit recall queries ("what did we decide about X?") render in chat as plain conversational answers — no inline citation, no chip, no special panel treatment. DevOverlay still shows the underlying retrieval per D-05.
- **D-07:** Retrieval scope is **all sessions** by default. The full `facts` table is searched regardless of `session_id`. `session_id` is used for browsing turns (TEXT-03) and `search_conversation`, NOT for filtering `search_memory`. Aligns with mental model: durable facts persist across launches.
- **D-08:** Point-in-time recall stays internal in P7. The schema supports `WHERE valid_from <= :t AND (valid_to IS NULL OR valid_to > :t)` per researcher §6, but no MCP tool surfaces it. Defer "time-machine" tool to backlog.

### Webcam Presence (Area 3)
- **D-09:** Presence detection is **on by default after the first Camera TCC grant**. Ambient / Iron Man pattern. Menu-bar arc-reactor reflects camera-in-use state.
- **D-10:** Presence affects **context-prompt enrichment + HUD ring subtle indicator**. Agent gets `"user is at desk"` / `"last seen 4 minutes ago"` in user-initiated turn system prompts (via `ContextBuilder`, read-only injection); HUD ring shifts a low-key state on `.present`/`.absent` transitions. **No DevOverlay row needed** beyond debug-only logging in `ContextBuilder`. **No subscriber of `PresenceSignalBus` references `TTSEngine` or `Orchestrator.runTurn`** (VISION-03 compile-time enforcement holds).
- **D-11:** Edge-triggered transitions with **2-second debounce** (researcher §9 baseline). Secondary threshold for context-state: **5 minutes absent** before Jarvis considers the user "gone" for "welcome back" framing. Generous: long phone calls / brief departures don't trigger transitions; only actual leaving-the-desk events register.
- **D-12:** Menu-bar **"Disable Presence" toggle** mirrors Phase 6's `MuteWakeWord` pattern (`packages/Voice/Sources/Voice/Control/MuteWakeWord.swift`). UserDefaults-persistent across launches. Camera remains available for frame-attach when the presence loop is paused. PTT-vs-mute independence pattern from VOICE-12 carries forward conceptually: disabling presence does NOT disable frame-attach.

### Frame Attach + Vision LLM Routing (Area 4)
- **D-13:** Frame-attach trigger: **phrase detection + HUD button** (both work). Phrase regex lives in `ContextBuilder` (e.g., `can you see this`, `what am I looking at`, `show this to Jarvis`, `what's on my screen`). HUD button is a small camera-icon affordance during a turn.
- **D-14:** **Always confirm before send.** After capture, HUD shows a thumbnail with `[Send] / [Cancel]` for ~2 seconds. Prevents phrase false-positives ("I can see why...") from accidentally sending desk frames to a vision model. Privacy + intent gate.
- **D-15:** **Discard frame immediately after response.** The captured PCM/JPEG bytes live only in the `ImageBlock` of the `userTurn` until the assistant turn completes. Conversation log retains response text but not frame bytes. Replay shows `{"type":"image","discarded":true}` as a placeholder.
- **D-16: VISION ROUTING (architectural, supersedes researcher §11).** The captured frame routes through a new multimodal extension to `LLMProvider` and lands in one of three tiers:
  - **T1 (default fast):** **Gemma 4 31B Dense** via Ollama (`gemma4:31b`). Released 2026-04-02; Apache 2.0; multimodal native; reportedly outperforms Llama 4 Maverick on math/coding/reasoning at fraction of size. Sub-second-class latency on 128 GB Apple Silicon. Privacy-pure local default.
  - **T2 (quality escalation, local):** **Qwen 3.5 35B-A3B-VL** (multimodal MoE, 35B total / 3B active) via **vllm-mlx sidecar** (`waybarrios/vllm-mlx`, OpenAI/Anthropic-compatible localhost server, native MLX backend, 400+ tok/s). Released 2026-02-16. Highest open-source vision benchmarks at decision time (MMMU 85.0, MathVision 88.6 — beats GPT-5.2 and Gemini 3 Pro on MathVision; OmniDocBench 90.8). Note: Qwen 3.5 multimodal is NOT yet supported by Ollama as of March 2026 — vllm-mlx is the runtime.
  - **T3 (cloud escape, explicit):** **Opus 4.7** via the existing `AnthropicProvider`, only when the user explicitly asks ("send to Opus" / "use cloud" phrase OR a deliberate UI affordance). Never automatic.
- **D-17:** **T1 → T2 escalation is automatic on low-confidence heuristic.** When T1 returns `"I'm not sure" / "unclear" / "cannot determine"` substrings OR a response shorter than a threshold, the system silently re-runs on T2 and uses that result. The user perceives "one frame in, one good answer out." T2 → T3 escalation is **not automatic** — only the explicit user phrase reaches T3.
- **D-18 (architectural follow-on, supersedes CLAUDE.md's "Opus for reasoning" implication for vision):** The `LLMProvider` protocol gains a multimodal `stream(messages:images:tools:toolChoice:)` signature; both `OllamaProvider` and `AnthropicProvider` implement vision; a new `VllmMlxProvider` (or `OllamaProvider` configured against the vllm-mlx port) covers T2. The Local-vs-Cloud routing abstraction that exists for text extends to vision — vision is the *more* privacy-sensitive surface, so the default tilts harder toward local.

### Claude's Discretion
- **Internal schema shape** beyond MEM-01/02/05 invariants (researcher §1 has the recommended shape; planner may refine).
- **Bounded queue size** for the extraction channel (researcher recommends 32; planner empirically tunes).
- **Hybrid search ranking weights** for FTS5 + vec RRF (researcher §8 has the SQL; planner tunes the `60` constant if needed).
- **Phrase-detection regex** for frame-attach triggers and Opus-escape phrases.
- **HUD camera-icon affordance design** (researcher didn't specify; planner picks).
- **Confirmation thumbnail UX** (size, fade-out timing, where it renders in the HUD).
- **vllm-mlx sidecar lifecycle** (launchd-managed vs spawned by main app vs user-managed; planner picks; should mirror MCP helper spawn pattern from `ChildSpawnGate`).
- **Low-confidence heuristic for T1→T2** — exact substring set, length threshold, optional secondary signal (e.g., low-token-probability ranking if exposed).
- **Memory regression-test corpus for P7** — researcher's Open Q #3 suggests a minimal 10-scenario suite; planner decides quantity/specificity. (Not deferred — likely worth doing.)

### Folded Todos
None (no matching todos for Phase 7).

</decisions>

<canonical_refs>
## Canonical References

**Downstream agents MUST read these before planning or implementing.**

### Phase 7 specifics
- `.planning/phases/07-memory-vision/07-RESEARCH.md` — 290-line research artifact; SQLite/FTS5/vec schema, mem0 prompt + tool schema, supersede SQL transaction, background orchestrator pattern, hybrid search SQL with RRF, presence pipeline, Camera TCC lifecycle, package layout, pitfalls table. **Authoritative for the memory subsystem.**
- `.planning/phases/07-memory-vision/07-DISCUSSION-LOG.md` — full Q&A trail of this discussion (all four areas + the vision-routing pivot).

### Project-level (reread for cross-phase invariants)
- `CLAUDE.md` — Memory Stack section (authoritative); Voice Stack section (Orpheus / mlx-audio-swift / TTSKit pattern that informs vllm-mlx sidecar pattern); Local-vs-Cloud routing abstraction (extends to multimodal here).
- `.planning/research/RESEARCH-DELTAS.md` — D3 (Qwen3 tool-calling broken in Ollama; affects routing for tool-using paths but not vision-only); D7 (Orpheus mlx-audio-swift in-process — sets the precedent for in-process MLX runtimes that vllm-mlx mirrors at the HTTP layer).
- `.planning/REQUIREMENTS.md` — TEXT-03, VISION-01..04, MEM-01..08 (10 requirements covered).
- `.planning/ROADMAP.md` §Phase 7 — 6 success criteria; goal statement.
- `.planning/PROJECT.md` — core value, evolution rules.

### Cross-phase dependency surfaces
- `packages/AgentCore/Sources/AgentOrchestrator/AgentOrchestrator.swift` — `submit` / `cancelAndSubmit` / `TurnSource` (`.memoryExtraction` variant lives here per Phase 4; P7 wires the producer side).
- `packages/AgentCore/Sources/AgentOrchestrator/TurnInput.swift` — extends to carry `[ImageBlock]` for VISION-04 frame attach.
- `packages/AgentCore/Sources/LLMProvider/` — `LLMProvider` protocol; **gains multimodal `stream(...,images:)` signature in P7**.
- `packages/Voice/Sources/Voice/Control/MuteWakeWord.swift` — pattern for Phase 7's "Disable Presence" menu-bar toggle (UserDefaults persistence + menu-bar wiring).
- `packages/Voice/Sources/Voice/AudioGraph/AudioGraphOwner.swift` — graceful-denial banner pattern (`degradationStream`) → reused for Camera TCC denial via `HUDBannerCoordinator`.
- `App/AppDelegate.swift` `installVoice()` — pattern for `installMemory()` + `installVision()` entry points.
- `App/HUD/HudStateCoordinator.swift` — three-subscriber pattern for HUD state intent streams (ring subtle indicator for D-10 plugs in here).
- `packages/MCP/Sources/JarvisMCP/` — `search_memory`, `search_conversation`, `forget_fact` MCP tools land here (Phase 5 MCP runtime hosts them).
- `packages/Replay/Sources/Replay/` — `ReplayEvent` schema needs to handle `.memoryMutation` and `.memoryRetrieval` rows for DevOverlay surfacing.

### External documentation
- [sqlite-vec — asg017/sqlite-vec](https://github.com/asg017/sqlite-vec) — pinned `v0.1.10-alpha.3`; `vec0` virtual table; `FLOAT[768]` column syntax (assumption A5 in research)
- [SQLite loadable extensions](https://www.sqlite.org/loadext.html) — `sqlite3_enable_load_extension` + `sqlite3_load_extension` direct C API
- [SQLite FTS5](https://www.sqlite.org/fts5.html) — `unicode61 remove_diacritics 2` tokenizer for international names (P8 pitfall)
- [Ollama API — `/api/embed`](https://github.com/ollama/ollama/blob/main/docs/api.md) — NOT deprecated `/api/embeddings`
- [mem0](https://github.com/mem0ai/mem0) — ADD/UPDATE/NOOP extraction pattern; system prompt template
- [Zep / Graphiti](https://github.com/getzep/zep) — temporal validity invariant inspiration
- [`VNDetectFaceRectanglesRequest`](https://developer.apple.com/documentation/vision/vndetectfacerectanglesrequest) — on-device face detection
- [`AVCaptureDevice.authorizationStatus`](https://developer.apple.com/documentation/avfoundation/avcapturedevice/1624577-authorizationstatus) — Camera TCC lifecycle
- [Anthropic vision input](https://docs.anthropic.com/en/docs/build-with-claude/vision) — image_block format for T3 path
- [Blaizzy/mlx-vlm](https://github.com/Blaizzy/mlx-vlm) — VLM inference + fine-tuning on Apple Silicon via MLX
- [waybarrios/vllm-mlx](https://github.com/waybarrios/vllm-mlx) — OpenAI/Anthropic-compatible MLX server, native multimodal, 400+ tok/s; **the T2 runtime**
- [Gemma 4 (Apr 2, 2026)](https://ollama.com/library/gemma4) — T1 default vision model
- [Qwen 3.5 (Feb 16, 2026)](https://huggingface.co/Qwen/Qwen3.5-35B-A3B) — T2 vision MoE model
- [Llama 4 Scout (Apr 5, 2025)](https://www.llama.com/models/llama-4/) — fallback T2 candidate if Qwen 3.5 doesn't pan out

</canonical_refs>

<code_context>
## Existing Code Insights

### Reusable Assets
- `MuteWakeWord` (Phase 6 / `packages/Voice/Sources/Voice/Control/MuteWakeWord.swift`) — UserDefaults persistence + menu-bar toggle; clone the pattern for "Disable Presence" (D-12).
- `HUDBannerCoordinator` (Phase 1 + reused in Phase 6's AEC banner) — native AppKit banner. Reuse for Camera TCC denial banner (VISION-01 graceful denial). Modal-lint from Phase 5 enforces no webview modal.
- `ChildSpawnGate` (Phase 1) — `FD_CLOEXEC` + minimal-env spawn pattern. Apply to vllm-mlx sidecar process if main app spawns it (D-16 / Claude's discretion in routing follow-on).
- `MCPRuntimeWiring` + `withMethodHandler` (Phase 5) — registration pattern for `search_memory`, `search_conversation`, `forget_fact` MCP tools.
- `ContextBuilder` (Phase 4) — pre-turn context assembler; gains presence-state injection (D-10) + frame-attach phrase detection (D-13) + Opus-escape phrase detection (D-16 T3 trigger).
- `ReplayEvent` (Phase 4 / `packages/Replay`) — extend with `.memoryMutation(MemoryOp)` and `.memoryRetrieval(FactRef)` cases for DevOverlay (D-05 + MEM-08).
- `AudioGraphOwner.degradationStream` (Phase 6) — pattern for emitting graceful-denial signals consumed by HUDBannerCoordinator. Vision's `CaptureSession` can mirror it for Camera TCC denial.

### Established Patterns
- **Single emission site for atomic events** (Phase 6 grep gate `\.ttsStopped` count == 1 in `TTSInterrupt.swift`) — apply to memory mutations: `MemoryStore.applyOp` should be the only emit site for `memory.mutated` over the bridge.
- **Compile-time package boundary as an architectural guard** (Phase 6 `JarvisVision` cannot depend on `JarvisTTS` or `JarvisOrchestrator` per VISION-03) — formalize via SPM dependency graph + a CI check.
- **`@available(macOS 26)` runtime guards with feature-flag fallback** (Phase 6 `STTBackendSelector`) — apply to vision routing where `vllm-mlx` may not be available on a given install.
- **Env-gated scaffold-time perf probes** (Phase 6 `OrpheusTTFATests` behind `JARVIS_REAL_MODELS=1`) — apply to memory regression-test corpus (researcher Open Q #3) and vision-model TTFA probes.
- **Worktree mode with executor-per-plan + orchestrator post-wave validation** (Phase 6 demonstrated value) — Phase 7 should expect the same flow; the orchestrator should re-run `swift test` + `bash scripts/check-app-builds.sh` against the merged develop tree before marking each plan done.

### Integration Points
- **Phase 4 AgentOrchestrator** — gains `.memoryExtraction` `TurnSource`; `cancelAndSubmit` and `submit` are the only turn-lifecycle entry points (extracted as a separate orchestrator instance for memory).
- **Phase 5 MCP Runtime** — hosts the three new tools (`search_memory`, `search_conversation`, `forget_fact`).
- **Phase 3 HUD** — gains presence-state subtle ring indicator (D-10); existing `HudStateCoordinator` three-subscriber pattern is the integration seam.
- **Phase 1 menu-bar** — gains "Disable Presence" toggle alongside Phase 6's "Mute Wake Word" item.
- **Phase 6 voice loop** — unaffected; voice and vision/memory are independent; both reach `Orchestrator.submit` through their own producers.

</code_context>

<specifics>
## Specific Ideas

- **Mac Studio M3 + MacBook M5, both 128 GB unified memory.** This is the target hardware for routing decisions. Gemma 4 31B Dense unquantized fits comfortably; Qwen 3.5 35B-A3B-VL fits comfortably; even Llama 4 Maverick (100 GB) fits but is too slow at 8–12 tok/s for interactive UX.
- **Ollama is already installed on the user's machines.** Phase 7 doesn't need to bring its own Ollama lifecycle; it just needs to talk to the existing local server and add a vllm-mlx sidecar for the T2 path.
- **User explicitly pushed back on Qwen2.5-VL** (researcher's original recommendation) and asked for the latest April-2026 vision models. The selected stack reflects post-pushback research: Gemma 4 (April 2, 2026 — 25 days old at decision time) + Qwen 3.5 (February 16, 2026) replaces Qwen2.5-VL.
- **Iron Man / ambient pattern** — presence on by default after TCC grant (D-09), HUD ring subtle indicator on transitions (D-10). The user wants Jarvis to feel "aware," not "polite." Phase 7 leans into this.
- **Privacy-first floor.** "Zero user data leaves the machine for memory or vision" is enforced as the default truth, not an aspiration: extraction is local, embeddings are local, vision T1 + T2 are local; only T3 (Opus) is cloud, and only on explicit user request.

</specifics>

<deferred>
## Deferred Ideas

### Out-of-scope for P7 (deferred to future phases / backlog)
- **Cross-device memory sync** — the M3 Studio and M5 MacBook each have their own SQLite store; sync between them would be a separate feature. Researcher already noted this as out of scope; reaffirmed.
- **Alternative vector indexes** (HNSW, LanceDB) — vec0 is fine for P7; revisit if hybrid search proves slow at scale.
- **Cloud embedding fallback** — `nomic-embed-text` via local Ollama is the only embedding path; no Anthropic/OpenAI embedding fallback in P7.
- **Face identity / per-person presence** — Vision framework's `VNDetectFaceRectanglesRequest` is presence-only. Face identification is a separate capability and a much bigger privacy surface.
- **Continuous video understanding** — single-frame attach only; no streaming video to vision models in P7.
- **Time-machine MCP tool** — `search_memory_at_time` (D-08) is deferred. Schema supports it; tool surface waits.
- **Manual memory browser UI** — Phase 7 does NOT ship a chat-panel widget for browsing/editing stored facts. DevOverlay surfaces mutations + retrievals (D-05) which is enough for now. Full memory-browser UI is its own phase.
- **Auto-expiring time-bounded facts** (researcher Open Q #2) — "next week's meeting" type facts don't auto-expire in P7. They become superseded only when the user explicitly says they have. Defer to backlog.
- **Vec rebuild on embedding model swap** — researcher Open Q #6 — not a P7 deliverable. Document as a future migration if `nomic-embed-text` is ever swapped.
- **Continuous video frame attach during a turn** — VISION-04 is single-frame only. "Show me what you see for the next 10 seconds" is out of scope.

### Architecturally adjacent — likely Phase 8 or later
- **Vision-model fine-tuning on user data** — the user's Jarvis would benefit from a custom vision adapter trained on their environment (their desk, their whiteboards, their handwriting). Not P7. Possibly a v1.x feature once memory has accumulated enough labeled frames.
- **Vision provider feature-flag UI** — D-16's three-tier routing is locked in CONTEXT, but a Settings UI for users to flip `features.vision.tier1` and `features.vision.tier2` is Phase 8 polish.

### Reviewed Todos (not folded)
None — no matching todos in the backlog at discussion time.

</deferred>

---

*Phase: 07-memory-vision*
*Context gathered: 2026-04-27*
