# Stack Research — Jarvis (macOS Native AI Assistant)

**Domain:** Personal, always-on macOS AI assistant with hybrid Swift/SwiftUI + WKWebView (React + R3F) HUD, streaming LLM agent, MCP tools, all-local voice, local memory.
**Researched:** 2026-04-21
**Overall confidence:** HIGH on core (Swift/React/R3F/Ollama/WhisperKit/SQLite-vec/MCP Swift SDK), MEDIUM on Anthropic SDK path (Opus 4.7 identifier unverified), MEDIUM on Orpheus streaming specifically, LOW on a few footguns the plan takes as fact.

**Read order:** "Deltas vs CLAUDE.md / PLAN / IMPL" first — that's where current 2026-04 practice disagrees with the existing planning corpus. The rest is version pins and rationale.

---

## Deltas vs CLAUDE.md / PLAN / IMPL (most important section)

| # | Existing decision | 2026-04 finding | Delta | Confidence |
|---|-------------------|-----------------|-------|-----------|
| D1 | Model ID is `claude-opus-4-7` | ~~No Anthropic SDK ships a `claude-opus-4-7` constant~~ **Correction (2026-04-21, user-confirmed):** `claude-opus-4-7` is real and currently deployed — the orchestrator running this GSD flow is Opus 4.7. The stack researcher's "absent from public SDKs" check was a false-negative: community/official SDK enum lag does not imply model absence. **Keep `claude-opus-4-7` as pinned model ID.** SSE event shape is stable across the 4.x family (content_block_start + input_json_delta for tool args). | **No change. Keep `claude-opus-4-7`.** Ignore any SDK enum that doesn't yet list it; direct URLSession + string model ID works. | HIGH (user authoritative) |
| D2 | "Cache TTL default silently regressed to 5 minutes. Always pass `ttl: \"1h\"` explicitly on `cache_control` blocks." | 1h cache TTL is real but **requires a beta header**: `anthropic-beta: extended-cache-ttl-2025-04-11`. Without it, only 5m (ephemeral default) is supported. Response usage splits into `cacheCreation.ephemeral5mInputTokens` and `cacheCreation.ephemeral1hInputTokens`. | **Update IMPL §5 (AnthropicProvider):** add the beta header on every request where a 1h cache block is present; unit-test that the header is actually sent. The "silent regression" framing is misleading — 5m is the non-beta default, 1h is beta-gated. | HIGH (verified across Go/PHP SDK docs) |
| D3 | "Qwen 3/3.5 / Gemma 4 tool-calling is broken in Ollama; qwen2.5-coder:32b is the known-good baseline" | Ollama's own official tool-calling docs (2026-04) use `model='qwen3'` in every example. Ollama v0.21.0 uses Qwen3 as the primary tool-calling example. No breakage documented on current master. | **Re-evaluate the pin.** The "broken" framing was accurate in an earlier window but no longer true as of 2026-04. Keep `qwen2.5-coder:32b` as the pinned eval-harness baseline (scope-stable), but remove the "Qwen 3 is broken" language from CLAUDE.md and allow `qwen3` as an opt-in model. | HIGH (verified directly from Ollama docs) |
| D4 | MCP client is a roll-your-own NDJSON JSON-RPC 2.0 (`MCPClient`, `MCPServerHandle`, `NDJSONTransport` — IMPL §7) | **Official MCP Swift SDK exists** (`modelcontextprotocol/swift-sdk`) at v0.12.0 (March 2026); v0.10.0+ stable. Provides `Client`, `Server`, `StdioTransport`, `ServiceGroup` (ServiceLifecycle-integrated), handler registration via `withMethodHandler(ListTools.self)` / `withMethodHandler(CallTool.self)`. 1355 stars; official modelcontextprotocol org. | **Strongly consider adopting the official SDK** for both the main-app MCP client and each `mcp-*.app` helper server. Eliminates ~400 LOC of custom JSON-RPC, restart mutex (R3-A13), sanitization (R3-Sec4) — the SDK handles most of it. Trade-off: couples restart/crash semantics to SDK internals. Prototype with `mcp-time` first. | HIGH (SDK confirmed real, actively developed) |
| D5 | `@react-three/fiber 8.17+` pinned with `react 18.3+` | R3F's own compatibility matrix: **v8 pairs with React 18, v9 pairs with React 19**. As of 2026-04, v9.6.0 is current stable; v10.0.0 is in alpha. React 19 has been stable for a year. | **Choose deliberately:** the webview is greenfield — pin **R3F v9.6+, React 19, drei v10, three r184**. No reason to anchor a new 2026 webview to React 18. | HIGH |
| D6 | `WhisperKit 0.9.0+` pinned as standalone SPM package | WhisperKit is no longer a standalone SPM package — merged into `argmax-oss-swift` monorepo (same org, redirect). As of 2026-04: SPM coordinates are `https://github.com/argmaxinc/argmax-oss-swift` at v0.18.0, product `WhisperKit`. Platforms: iOS 16+, macOS 13+. Model string format: `large-v3-v20240930_626MB` (NOT `large-v3-turbo`). | **Update IMPL §2:** change package URL, pin v0.18.0. Model string in PLAN is wrong — Argmax uses versioned variants from their `whisperkit-coreml` HF repo. Confirm exact variant at scaffold via `WhisperKit.recommendedModels()`. | HIGH |
| D7 | Orpheus via `mlx-audio-swift 0.3.0+` is tier-2 TTS with ~150-250ms TTFA streaming | `mlx-audio-swift` is at **v0.1.2** as of 2026-03-14 (NOT 0.3.0+ — that version doesn't exist). Orpheus is supported via `LlamaTTSModel.fromPretrained("mlx-community/orpheus-3b-0.1-ft-bf16")`. Framework has `generateStream(...)` documented for Chatterbox and Qwen3-TTS; **Orpheus's README shows only non-streaming `generate(...)`**. Source inspection shows `Generation.swift` defines streaming primitives, so it likely works via the generic protocol — just undocumented. Output confirmed `pcmFormatFloat32` mono via `AVAudioFormat(commonFormat: .pcmFormatFloat32, channels: 1, ...)`. Sample rate via `model.sampleRate`. | **Escalate PLAN Open Question #1 to a BLOCKER for Step 9.** (a) mlx-audio-swift is pre-1.0 (v0.1.x), less mature than IMPL suggests; (b) Orpheus streaming support is not publicly documented. **Prototype `generateStream(text:voice:)` on Orpheus at scaffold before committing to Step 9.** Fallback: **TTSKit from argmax-oss-swift** — Core ML, documented `play(strategy: .auto)` real-time streaming, 6015 stars vs mlx-audio-swift's 587, same team as WhisperKit. Different voice character (qwen3-tts voices vs Orpheus `tara`/`leah`), so only a drop-in if voice character is negotiable. | MEDIUM (lib version verified; Orpheus streaming status uncertain) |
| D8 | `onnxruntime-swift-package-manager 1.17.0+` | Current release is **1.24.2** (2026-02-25). IMPL floor is five minor versions behind. | **Bump floor to 1.24.0+.** Recent Apple Silicon perf work, Silero VAD v5 compatibility. | HIGH |
| D9 | `sqlite-vec-swift 0.1.0+` | Upstream `asg017/sqlite-vec` is at **v0.1.10-alpha.3** (2026-04-01) — still alpha. Swift bindings `jkrukowski/SQLiteVec` are 49 stars, last updated 2026-04-12. | **Note alpha status.** Pin an exact alpha tag; re-verify at v0.1.10 stable or v0.2.0. The SQLiteVec Swift bindings are low-star — consider loading the C extension directly via `sqlite3_enable_load_extension(db, 1)` + `sqlite3_load_extension(db, path, nil, nil)` from a thin SQLite wrapper instead of taking an SPM dep on SQLiteVec. | MEDIUM |
| D10 | `Zustand 4.5+` pinned | Zustand is at **v5.0.12** (2026-03-16). v4→v5 is a breaking API change. | **Pin Zustand v5.0.x** (matches React 19 if D5 is taken). Trivial migration for greenfield. | HIGH |
| D11 | `Vite 5.3+` pinned | Vite is at **v8.0.9** (2026-04-20) — three majors ahead of IMPL's floor. | **Bump to Vite 8.x.** | HIGH |
| D12 | Step 5 implies direct URLSession + SSE for Anthropic; no SDK named | `jamesrochabrun/SwiftAnthropic` is at v2.2.2 (2026-04-18), 237 stars, actively maintained. Has `service.streamMessage(parameters)` with `.contentBlockDelta` / `.messageStop` events. **BUT:** does not expose the `extended-cache-ttl-2025-04-11` beta header as a first-class option; model enum lags (shows `.claude35Sonnet`, `.claude37Sonnet`). | **Build `AnthropicProvider` directly on URLSession + custom SSE decoder** as IMPL-R3 already implies. SwiftAnthropic would save boilerplate but lags beta features. ~200 LOC hand-rolled keeps the project on current features. Confirm IMPL approach. | HIGH |
| D13 | "openWakeWord embedded via `onnxruntime-swift-package-manager`" (AUDIT-R1) | `dscripka/openWakeWord` is a Python/Jupyter repo with no Swift bindings. The approach is: bundle the pretrained ONNX models and run them directly via ORT Swift. IMPL §8 already does this correctly. | **No delta, confirming.** The name "openWakeWord" refers to the model weights + preprocessing DAG; there is no Swift SDK to choose from. Plan is correct. | HIGH |
| D14 | `HotKey 0.2.0` SPM pinned; rev-3 R3-S4 prefers `NSEvent.addGlobalMonitorForEvents` for plain-modifier keys | `soffes/HotKey 0.2.1` (Dec 2024) is the latest; repo stable but stale. `NSEvent.addGlobalMonitorForEvents` is the current best-practice per R2 Sec7 / R3-S4. | **Drop HotKey as a dependency for week-one.** Use `NSEvent.addGlobalMonitorForEvents` + `addLocalMonitorForEvents` directly. Fewer deps; no Carbon shim; no Input Monitoring TCC prompt. Keep HotKey in the back pocket for Function/media keys post-week-one. | HIGH |
| D15 | AEC via `AVAudioEngine.inputNode.isVoiceProcessingEnabled = true`; format coerced to 16 kHz mono on Sonoma, 24 kHz on Tahoe | Confirmed correct. No delta. | **No change.** Keep R3-V1 canonical 6-step teardown. | HIGH |
| D16 | macOS 26 Tahoe `SpeechAnalyzer` needs `com.apple.developer.speech-recognition-assets` entitlement + `NSSpeechRecognitionAssetsUsageDescription` (R2 S5) | Cannot externally verify macOS 26 Tahoe API surface (Apple docs not indexed in Context7). Entitlement pair is consistent with Apple's asset-download permission model (Personal Voice precedent). | **Keep R2 S5 entitlement pair as-is.** Flag for scaffold-time verification — cold-launch a Release build on macOS 26 with the entitlement removed and confirm `SFSpeechErrorCode.assetUnavailable` fires. The positive claim is load-bearing; if it's wrong, first-launch STT hard-fails in Release. | LOW (cannot externally verify; trust audit but test early) |

---

## Recommended Stack

### Native core (Swift / macOS 26 Tahoe)

| Component | Package / API | Version | Purpose | Why |
|-----------|---------------|---------|---------|-----|
| Host app | Apple SwiftUI + AppKit (`NSApplicationDelegate`, `NSPanel`, `NSStatusItem`) | Xcode 16 (Swift 6) | Menu-bar host, transparent panel, global hotkey, WKWebView container, entitlements | Apple-native; only path that gets on-device ML + menu bar + global hotkeys outside a browser sandbox. |
| WebView | `WKWebView` + `WKScriptMessageHandlerWithReply` | macOS 14+ baseline, macOS 26 target | HUD renderer + typed JSON bus | Hardened Runtime + `com.apple.security.cs.allow-jit` unlocks JavaScriptCore JIT in Release. |
| Global hotkey | `NSEvent.addGlobalMonitorForEvents` + `addLocalMonitorForEvents` | macOS 14+ | Plain-modifier shortcut summoning | **Replaces** `HotKey` SPM from IMPL §2 per R3-S4. No Carbon dependency; no Input Monitoring TCC prompt for plain-modifier keys. |
| LLM Provider | Hand-rolled `AnthropicProvider` on `URLSession.bytes(for:)` + `AnthropicSSEDecoder` | N/A (project code) | Streams Messages API SSE: `message_start`, `content_block_start`, `content_block_delta` (text or input_json_delta), `content_block_stop`, `message_delta`, `message_stop` | Community SDKs lag beta features (extended-cache-ttl) and model enum. Direct URLSession maps to `AsyncThrowingStream<LLMEvent, Error>`. Matches IMPL-R3. |
| LLM Provider (local) | Hand-rolled `OllamaProvider` on `URLSession.bytes(for:)` + NDJSON decoder for `/api/chat`, plus `OllamaSSEDecoder` for `/v1/chat/completions` fallback | Ollama 0.21.0+ daemon | Streams NDJSON-framed chat completions with tool calls | `/api/chat` is NDJSON (not SSE) — IMPL's distinction is correct. Native endpoint exposes `thinking` channel for reasoning models. |
| MCP client & server | `modelcontextprotocol/swift-sdk` (official) | **v0.12.0** (March 2026) | Main-app client and each `mcp-*.app` helper server | **Supersedes IMPL §7 roll-your-own.** `Client`, `Server`, `StdioTransport`, `ServiceGroup`, `withMethodHandler(ListTools.self)` / `withMethodHandler(CallTool.self)`. SPM: `.package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", from: "0.12.0")`. Validate with `mcp-time` prototype. |
| Local memory | **SQLite** (system) + **FTS5** (built-in) + **sqlite-vec** extension via `jkrukowski/SQLiteVec` OR direct `sqlite3_load_extension` | sqlite-vec **v0.1.10-alpha.3** (pin exact), SQLiteVec latest main | Keyword + vector search in one store (`jarvis.db`) | Unmatched single-file deployment. sqlite-vec is alpha but widely used in prod. SQLiteVec Swift bindings are 49 stars — consider loading the C extension directly from a thin SQLite wrapper to avoid the low-star SPM dep. |
| Embeddings | `nomic-embed-text` on Ollama | latest | Memory embeddings (768-dim) | Local, free; matches CLAUDE.md. |
| Audio graph | `AVAudioEngine` (`inputNode.isVoiceProcessingEnabled = true`), `AVAudioConverter`, `AVAudioPlayerNode` | macOS 13+ for AEC, macOS 26 for hardware-native format contract | Full audio I/O, AEC, resampling, TTS playback | Apple-native; R2 S1 / R3-V1 / R3-V2 contracts are sound. |
| RT→actor SPSC ring | `michaeltyson/TPCircularBuffer` (C) | latest main (active 2026-04) | Audio RT → actor bridge, lock-free | Industry standard for Core Audio. 900 stars. |
| Wake word | Custom streaming DAG over ONNX Runtime Swift with bundled openWakeWord ONNX weights (`melspectrogram.onnx`, `embedding_model.onnx`, `hey_jarvis_v0.1.onnx`) | onnxruntime-swift-package-manager **1.24.2+** | `hey_jarvis` detection on 16 kHz mono Float32; rolling mel (76-frame) + embedding (16-frame) buffers | Only approach — openWakeWord has no Swift SDK. PLAN AUDIT-R1 correctly identified this. Vendored MANIFEST.json + SHA-256 verification is right. |
| VAD | Silero VAD v5 (`silero_vad_v5.onnx`) via ONNX Runtime Swift | onnxruntime-swift-package-manager **1.24.2+** | 512-sample (32 ms) chunks at 16 kHz | Silero v5 still current; v6 exists — evaluate at scaffold. |
| STT (primary) | Apple `SpeechAnalyzer` / `SpeechTranscriber` | macOS 26 Tahoe | On-device transcription | Per R2 S5: requires `com.apple.developer.speech-recognition-assets` + `NSSpeechRecognitionAssetsUsageDescription`. Apple-native. |
| STT (fallback) | `argmaxinc/argmax-oss-swift` product `WhisperKit` | **v0.18.0** | CoreML Whisper; model string `large-v3-v20240930_626MB` or `WhisperKit.recommendedModels().default` | **Supersedes IMPL §2's `WhisperKit 0.9.0+`.** Argmax consolidated WhisperKit + TTSKit + SpeakerKit into one monorepo. macOS 13+ floor. |
| TTS tier 1 (instant) | `AVSpeechSynthesizer` | macOS 13+ | Sub-100ms confirmations / think-aloud | Apple-native, zero deps. |
| TTS tier 2 (quality) — **primary** | `blaizzy/mlx-audio-swift` → `LlamaTTSModel` (Orpheus 3B) | **v0.1.2** (pre-1.0) | In-process Apple Silicon Orpheus via MLX. Output: Float32 mono, `model.sampleRate` (probed at boot per R3-V3). | Matches CLAUDE.md decision. Pre-1.0 status and undocumented Orpheus streaming are the risks (D7). Validate streaming at scaffold. |
| TTS tier 2 (quality) — **fallback if Orpheus streaming doesn't work** | `argmaxinc/argmax-oss-swift` product `TTSKit` | **v0.18.0** | In-process CoreML TTS with `play(text:, playbackStrategy: .auto)` adaptive buffering. 9 voices, 10 languages. Models: 0.6B (speed, all platforms) / 1.7B (quality, macOS only) | Same-team as WhisperKit, more stars / maturity than mlx-audio-swift. First-class streaming playback. Different voice profile — if Orpheus's specific character is the point, this isn't a drop-in. Low-risk insurance for the 150-250ms TTFA target. |
| TTS tier 3 (deferred) | Kokoro-82M (Python sidecar) | ≥ 0.9.4 | Optional voice variety | Out of scope per CLAUDE.md unless above tiers insufficient. |
| Keychain | `Security.framework` direct calls (or thin wrapper like `KeychainAccess`) | macOS 14+ | Anthropic API key storage | ~30 LOC direct; no SDK needed. |
| Structured logging | `apple/swift-log` | **1.5.3+** | Agent / tools / UI / system channels | Apple-official. IMPL §11 correct. |
| Concurrency helpers | `apple/swift-async-algorithms` | **1.0.0+** | `AsyncChannel(capacity:)` for back-pressure (R2 A3), stream merging | Apple-official. |
| CLI for eval/replay | `apple/swift-argument-parser` | **1.3.0+** | `jarvis eval run`, `replay-viewer` | Apple-official. |
| Atomics (opt) | `apple/swift-atomics` | **1.2.0+** | If TPCircularBuffer insufficient | Only pull if profiling shows need. |

### Webview layer (React + R3F, inside WKWebView)

| Component | Package | Version | Purpose | Why |
|-----------|---------|---------|---------|-----|
| React | `react`, `react-dom` | **19.x** (NOT 18.3 as IMPL pins) | Base UI | 2026 greenfield = React 19. R3F v9 requires it. |
| React 3D renderer | `@react-three/fiber` | **9.6.0+** (NOT 8.17 as IMPL pins) | Declarative Three.js for particle rings, shaders | v9 is the React 19 pair. |
| R3F helpers | `@react-three/drei` | **10.7.7+** (NOT 9.100 as IMPL pins) | Cameras, controls, loaders | drei v10 pairs with R3F v9. |
| Three.js | `three` | **r184** (April 2026) | WebGL core | Drei/fiber track it closely. |
| State | `zustand` | **5.0.12** (NOT 4.5 as IMPL pins) | HUD state store, mirrors Swift `HudState` | v5 is current; v4→v5 is trivial migration for greenfield. |
| Build | `vite` | **8.0.9+** (NOT 5.3 as IMPL pins) | Dev server with HMR (Debug loads `http://localhost:5173`), Release bundle to `Resources/webview/` | Vite 8 is current. |
| Language | `typescript` | **5.5+** (IMPL fine) | Type safety | IMPL pin acceptable. |
| Package manager | `pnpm` (R2 B3) | 9.x | Lockfile, content-addressed store | Keep; activate via mise/asdf in `build-webview.sh` since Xcode Run Scripts strip env. |

### Development tooling

| Tool | Purpose | Notes |
|------|---------|-------|
| Xcode 16 | IDE, build, codesign | Matches Swift 6 / macOS 26. `.xcodeproj` + local SPM packages (no workspace, R1 H-B2). |
| `xcodebuild` | CLI build | For scripts/CI; primary dev is Xcode GUI. |
| `mise` or `asdf` | Pin Node version for webview build | Per R2 B3; explicit activation at top of `build-webview.sh`. |

---

## Installation (scaffold commands)

### Swift packages (in Package.swift of local SPM packages under `packages/`)

```swift
dependencies: [
    .package(url: "https://github.com/apple/swift-log.git", from: "1.5.3"),
    .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.3.0"),
    .package(url: "https://github.com/apple/swift-async-algorithms.git", from: "1.0.0"),
    .package(url: "https://github.com/apple/swift-atomics.git", from: "1.2.0"),
    .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", from: "0.12.0"), // was roll-your-own in IMPL
    .package(url: "https://github.com/argmaxinc/argmax-oss-swift.git", from: "0.18.0"),    // WhisperKit lives here now
    .package(url: "https://github.com/blaizzy/mlx-audio-swift.git", from: "0.1.2"),         // Orpheus tier-2; prototype streaming first
    .package(url: "https://github.com/microsoft/onnxruntime-swift-package-manager.git", from: "1.24.2"),
    .package(url: "https://github.com/jkrukowski/SQLiteVec.git", from: "0.0.1"),           // or load C extension directly
    .package(url: "https://github.com/michaeltyson/TPCircularBuffer.git", branch: "master"),
    // REMOVED: HotKey — use NSEvent.addGlobalMonitorForEvents instead (R3-S4)
]
```

### Webview (`webview/package.json`, pnpm)

```bash
cd webview
pnpm init
pnpm add react@^19 react-dom@^19 three@^0.184 @react-three/fiber@^9.6 @react-three/drei@^10.7 zustand@^5.0
pnpm add -D vite@^8.0 @vitejs/plugin-react@latest typescript@^5.5 @types/react@^19 @types/react-dom@^19 @types/three@^0.184
```

### Ollama (outside Swift)

```bash
brew install ollama
ollama serve &                    # http://127.0.0.1:11434
ollama pull qwen2.5-coder:32b     # known-good tool-calling baseline (PLAN decision)
ollama pull nomic-embed-text      # 768-dim embeddings for memory
# Optional per D3: ollama pull qwen3  (re-evaluate the "broken" claim)
```

### Codesigning entitlements (no change from IMPL-R3 §3)

Main app (`Jarvis.entitlements`):

```xml
<key>com.apple.security.cs.allow-jit</key>                          <true/>
<key>com.apple.security.device.audio-input</key>                    <true/>
<key>com.apple.developer.speech-recognition-assets</key>            <true/>
<!-- NO com.apple.security.automation.apple-events (R3-S5 isolation) -->
<!-- NO com.apple.security.cs.allow-unsigned-executable-memory (R2 S4 overturns R1) -->
```

Helper `mcp-applescript.entitlements`:

```xml
<key>com.apple.security.automation.apple-events</key> <true/>
```

---

## Alternatives Considered

| Category | Recommended | Alternative | Why not (or when alt makes sense) |
|----------|-------------|-------------|-----------------------------------|
| Host shell | Swift + WKWebView | **Tauri 2** (Rust + system webview) | Tauri gets system webview + menu bar + global hotkeys, but Apple on-device ML (SpeechAnalyzer, Vision, Core ML) needs FFI or Swift sidecar — negates simplicity. Keep as **acceptable fallback** per CLAUDE.md. |
| Host shell | Swift + WKWebView | **Electron** | Rejected in CLAUDE.md. Bigger binary, same sandbox limitations as browser, no Apple ML access. No comeback. |
| HUD renderer | React + R3F | **SwiftUI 3D / Metal** | RealityKit/Metal is real, but particle/shader ecosystem is an order of magnitude larger on WebGL/R3F. For Iron Man HUD vibe, R3F is right. If HUD simplifies to flat 2D panels later, SwiftUI could take over. |
| HUD renderer | React + R3F | **Svelte + Threlte** | Threlte = Svelte's R3F. Smaller ecosystem. Pick only if team is Svelte-native. |
| MCP SDK | Official Swift MCP SDK | **Roll-your-own JSON-RPC** | PLAN did this correctly for pre-v0.10 era. v0.12.0 has caught up. Prefer SDK unless prototyping reveals missing primitives. |
| LLM provider lib | Hand-rolled URLSession + SSE | `SwiftAnthropic` v2.2.2 | Community SDK lags beta features / model enum. For primary provider on evolving API, stay closer to the wire. |
| TTS (quality) | mlx-audio-swift Orpheus | **argmax-oss-swift TTSKit** | TTSKit: more mature (6015 vs 587 stars), first-class streaming playback, same team as WhisperKit. Pick TTSKit if Orpheus streaming fails. Orpheus's empathetic voice is its differentiator; TTSKit uses qwen3-tts voices. |
| Vector store | sqlite-vec | **LanceDB**, **Chroma** embedded | Neither wins at "single file, single-user, ~10K facts." sqlite-vec in same db as FTS5 + conversation history is structurally simpler. Revisit if memory grows past ~1M rows. |
| Wake word | openWakeWord via ORT Swift | **Porcupine (Picovoice)**, **coqui-ai VAD** | Porcupine is commercial. openWakeWord is Apache-2.0 with the pretrained `hey_jarvis` model the user wants. |
| STT primary | Apple SpeechAnalyzer | **WhisperKit large-v3 as primary** | If scaffold shows SpeechAnalyzer quality on noisy input is poor, flip. PLAN already feature-flags; don't change. |
| Global hotkey | `NSEvent.addGlobalMonitorForEvents` | `HotKey` SPM, Carbon `RegisterEventHotKey` | Carbon triggers Input Monitoring TCC prompt process-wide. `NSEvent` pair is current best-practice (R3-S4). |

---

## What NOT to Use

| Avoid | Specific problem | Use instead |
|-------|------------------|-------------|
| **Electron** | Sandbox + binary size, no Apple ML access | Swift + WKWebView |
| **Cloud TTS (ElevenLabs, OpenAI TTS, PlayHT)** | User constraint: privacy, local-only | AVSpeechSynthesizer + Orpheus via mlx-audio-swift / TTSKit |
| **Cloud STT (OpenAI Whisper API, Deepgram, AssemblyAI)** | Same privacy constraint | SpeechAnalyzer primary, WhisperKit fallback |
| **Sonnet 4.5/4.6 as primary** | Superseded; Opus is the reasoning tier for this workload | Opus 4.6 (verify 4.7 ID with user before pinning) |
| **`codesign --deep`** | Silently drops per-helper entitlements (R2 S2) | Sign each nested helper individually, main app last |
| **Carbon `HotKey` SPM for plain-modifier keys** | Input Monitoring TCC prompt, process-wide scope | `NSEvent.addGlobalMonitorForEvents` + local monitor pair (R3-S4) |
| **`allow-unsigned-executable-memory` entitlement** | Hardening regression with no evidence of need (R2 S4) | `allow-jit` alone is sufficient for MLX |
| **ComposableArchitecture** | Over-abstraction for a small actor-based app | Plain actors + AsyncStream |
| **CocoaPods, Xcode workspace** | Unnecessary overhead | `.xcodeproj` + local SPM packages (R1 H-B2) |
| **`Bundle.main.url(forAuxiliaryExecutable:)` for nested helpers** | Search semantics changed unpleasantly on macOS 14+ (R2 S3) | Explicit `Contents/Helpers/mcp-X.app/Contents/MacOS/mcp-X` resolution |
| **`WKWebView` + string-interpolated JSON to `evaluateJavaScript`** | XSS via untrusted content (R1 H-Sec2) | `callAsyncJavaScript(arguments:)` with serialized args |
| **Webview modal for destructive confirmations** | Webview is not a trust boundary (R1 H-Sec3) | Native sheet on hidden `NSPanel` (R3-S3) |
| **"Qwen 3 broken in Ollama" as blanket statement** | Outdated as of 2026-04; Ollama's own docs use Qwen3 | Keep `qwen2.5-coder:32b` as pinned eval baseline; allow Qwen3 opt-in (D3) |
| **WhisperKit model string `large-v3-turbo`** | Not an actual Argmax model variant | `large-v3-v20240930_626MB` or `WhisperKit.recommendedModels().default` (D6) |
| **Vite 5, React 18, R3F 8, Zustand 4** as greenfield pins | Three majors behind current as of 2026-04 | Pin current majors (D5/D10/D11) |

---

## Stack Patterns by Variant

**If user confirms `claude-opus-4-7` as a real (unreleased) model ID:**
- Keep identifier in `AnthropicProvider`; add enum case when SDK/API docs publish it.
- SSE event shape is stable across the 4.x family (content_block_start + input_json_delta for tool args).
- Verify tokenizer behavior (~35% inflation vs 3.x per CLAUDE.md) against `count_tokens` beta endpoint before pinning token budget constants.

**If mlx-audio-swift Orpheus streaming doesn't work at scaffold:**
- Swap tier-2 TTS to `TTSKit` from argmax-oss-swift. Voice profile changes, but `play(strategy: .auto)` streaming playback is documented and stable.
- `mlx-audio-swift` dep can remain for future Orpheus re-attempt; `TTSEngine` protocol (IMPL §2) makes it a single-file swap.

**If `mcp-clipboard` or `mcp-applescript` proves too thin to justify nested-helper-app complexity:**
- Move starter tools in-process as Swift actor methods wrapped by a trivial MCP-compatible adapter. The MCP Swift SDK supports in-process registration.
- Re-evaluate at week 2 when tool set grows; isolation rationale (R2 S2, R3-S5) is strong specifically for AppleScript.

**If webview Vite dev server fights Xcode on cold-launch:**
- Bundle the webview always (even Debug) and add a file-system watcher that rebuilds + triggers WKWebView reload on save. Slower iteration but simpler invariants.

---

## Version Compatibility

| A | Compatible With | Notes |
|---|-----------------|-------|
| R3F v9.x | React 19.x, three r184+, drei v10.x | v9 is the React 19 pair. v8 = React 18. v10 is alpha. |
| Zustand v5.x | React 18 or 19 | v4→v5 API is breaking for stores but trivial to migrate. |
| `argmax-oss-swift` v0.18.0 | macOS 13+ (WhisperKit), macOS 15+ (TTSKit), Swift 5.9 tools | Fine on macOS 26 host. |
| `mlx-audio-swift` v0.1.2 | Apple Silicon only, Swift 5.9+, macOS 14+ (MLX) | Pre-1.0; verify Orpheus streaming at scaffold. |
| `modelcontextprotocol/swift-sdk` v0.12.0 | Swift 6.0, macOS 13+ | Actively tracks MCP spec; pre-1.0 breaking changes possible. |
| `sqlite-vec` alpha + SQLite 3.45+ | System SQLite on macOS 14+ | Load via `sqlite3_load_extension`; pin alpha tag exact. |
| `onnxruntime-swift-package-manager` v1.24.2 | ORT model format v8+, ONNX opset 17+ | Silero v5 comfortable on ORT 1.17+. |
| `WKWebView` + Hardened Runtime + `allow-jit` | macOS 13+ | Without `allow-jit`, JavaScriptCore JIT disabled in Release → framerate dies or webview crashes. |
| Xcode 16 Run Scripts + mise/asdf/pnpm | Requires explicit shim activation in script | Xcode runs scripts under `/bin/sh -c` with stripped env; `.tool-versions` alone insufficient. IMPL §9/§14 has the pattern. |

---

## Sources

### Context7 (HIGH confidence)

- `/modelcontextprotocol/swift-sdk` — Client, Server, StdioTransport, ServiceGroup, withMethodHandler API, SPM pinning from 0.10.0
- `/asg017/sqlite-vec` — SwiftPM integration (via `sqlite3_load_extension`), API, alpha tag
- `/blaizzy/mlx-audio-swift` — Orpheus via `LlamaTTSModel.fromPretrained("mlx-community/orpheus-3b-0.1-ft-bf16")`, Float32 mono output via `AVAudioFormat(commonFormat: .pcmFormatFloat32, channels: 1, ...)`, `model.sampleRate`
- `/argmaxinc/argmax-oss-swift` — WhisperKit + TTSKit + SpeakerKit monorepo, Package.swift verified, current model strings
- `/pmndrs/react-three-fiber` — v8/React 18 vs v9/React 19 matrix (own docs)
- `/pmndrs/zustand` — v5.0.x
- `/vitejs/vite` — v8.x
- `/ollama/ollama` — tool-calling examples with Qwen3 (contradicts CLAUDE.md D3)
- `/anthropics/anthropic-sdk-typescript` — streaming MessageStream events, `text`/`inputJson`/`message` helpers, current Claude model IDs (`claude-sonnet-4-5-20250929`, `claude-sonnet-4-6`)
- `/mozex/anthropic-php` — 1h cache TTL via `anthropic-beta: extended-cache-ttl-2025-04-11`; `ephemeral5mInputTokens`/`ephemeral1hInputTokens`; `claude-opus-4-6`
- `/charmbracelet/anthropic-sdk-go` — `CacheControlEphemeralTTLTTL5m`, `ModelClaudeSonnet4_5_20250929`
- `/amscotti/anthropic-cr` — `CLAUDE_SONNET_4_6`, TTL control
- `/jamesrochabrun/swiftanthropic` — community SDK state (v2.2.2, lags)
- `/snakers4/silero-vad` — v5 metrics, 512-sample/16kHz chunk, VADIterator

### GitHub API (HIGH confidence — version pins verified 2026-04-21)

- `modelcontextprotocol/swift-sdk` — v0.12.0 (2026-03-24)
- `blaizzy/mlx-audio-swift` — v0.1.2 (2026-03-14); pre-1.0
- `argmaxinc/argmax-oss-swift` — v0.18.0 (2026-04-01)
- `pmndrs/react-three-fiber` — v9.6.0 (2026-04-13); v10.0.0-alpha in dev
- `pmndrs/zustand` — v5.0.12 (2026-03-16)
- `asg017/sqlite-vec` — v0.1.10-alpha.3 (2026-04-01)
- `microsoft/onnxruntime-swift-package-manager` — 1.24.2 (2026-02-25)
- `soffes/HotKey` — 0.2.1 (2024-12); stale but stable
- `vitejs/vite` — v8.0.9 (2026-04-20)
- `anthropics/anthropic-sdk-typescript` — sdk-v0.90.0 (2026-04-16)
- `jamesrochabrun/SwiftAnthropic` — 2.2.2 (2026-04-18)
- `pmndrs/drei` — v10.7.7 (2025-11-13) latest stable
- `mrdoob/three.js` — r184 (2026-04-16)
- `ollama/ollama` — v0.21.1-rc1; v0.21.0 stable
- `michaeltyson/TPCircularBuffer` — active 2026-04-13, 900 stars
- `jkrukowski/SQLiteVec` — 49 stars; low trust — prefer direct `sqlite3_load_extension`

### Unverifiable (MEDIUM-LOW — cross-check at scaffold)

- Apple `SpeechAnalyzer` / `SpeechTranscriber` API surface on macOS 26 Tahoe — Apple docs not indexed in Context7. R2 S5 entitlement claim is consistent with precedent but load-bearing.
- ~~`claude-opus-4-7` model ID — absent from all public SDKs~~ **RESOLVED: real and deployed; user-confirmed 2026-04-21. The researcher's "absent from SDKs" observation was a false-negative.**
- Orpheus `generateStream` specifically — documented for Chatterbox/Qwen3-TTS, not for `LlamaTTSModel`. Framework protocol suggests it should work; verify at scaffold per PLAN Open Question #1.

---

## Open Questions for Next Phase

1. **Is `claude-opus-4-7` a real forthcoming Anthropic model ID**, or should the plan use `claude-opus-4-6`? (D1)
2. **Does `LlamaTTSModel.generateStream` work on Orpheus in mlx-audio-swift 0.1.2**? Requires scaffold-time probe. (D7)
3. **Silero VAD v5 vs v6 on macOS 26** — v6 is available; does it drop in cleanly with the same 512-sample/16kHz chunk contract?
4. **Is Qwen3 tool-calling still unstable in any specific Ollama release**, or is the CLAUDE.md claim fully outdated? Consider a side-by-side eval run.
5. **macOS 26 Tahoe `SpeechAnalyzer` API surface** — unverifiable in Context7; need Apple's developer docs at scaffold to finalize IMPL §8 STT code.
