# Research Deltas — Corrections and Resolutions Post-Research

**Created:** 2026-04-21
**Purpose:** Capture corrections to the initial research pass, driven by (a) user-authoritative facts and (b) targeted web searches for contradictions and open questions. **This file is authoritative when it disagrees with STACK.md / FEATURES.md / ARCHITECTURE.md / PITFALLS.md.**

---

## D1 (STACK): `claude-opus-4-7` exists — CORRECTED

**Original claim (STACK D1):** "No Anthropic SDK ships a `claude-opus-4-7` constant as of 2026-04-21. Pin to `claude-opus-4-6` until user clarifies."

**User correction (authoritative, 2026-04-21):** `claude-opus-4-7` is real and currently deployed — the orchestrator running this GSD workflow is Opus 4.7 running the 1M-context variant. Community/official SDK enum lag (researcher observed `claude-opus-4-6` as the newest enum in public SDKs) does not imply model absence; model IDs work via direct string pass-through regardless of SDK-level constants.

**Resolution:** **Keep `claude-opus-4-7` as the pinned model ID in CLAUDE.md, PROJECT.md, and PLAN/IMPL.** `AnthropicProvider` uses URLSession + SSE with string model ID, not an SDK enum — enum lag is non-blocking.

---

## D3 (STACK vs PITFALLS): Qwen3 tool-calling in Ollama — PITFALLS IS CORRECT

**Contradiction resolved via web search.**

**Stack researcher claim:** Ollama v0.21.0 docs use `model='qwen3'` as primary tool-calling example; "broken" framing in CLAUDE.md is stale as of 2026-04.

**Pitfalls researcher claim:** Qwen 3/3.5 tool-calling broken per live GitHub issues (#14493, #14601, #14745, #11662).

**Web-search findings (2026-04-21):**

- **[ollama/ollama#14493](https://github.com/ollama/ollama/issues/14493) — Qwen 3.5 27B tool calling completely non-functional.** Ollama's registry config sets renderer and parser to "qwen3.5" which maps to Qwen 3 Hermes-style JSON pipeline, but Qwen 3.5 was trained on Qwen3-Coder XML format. Mismatch breaks tool calls.
- **[ollama/ollama#14601](https://github.com/ollama/ollama/issues/14601) — Qwen3 tool calling via `/api/chat` tools parameter: malformed tool definitions.** Two bugs in how Ollama constructs prompts for Qwen3 when tools are passed via `/api/chat`.
- **[ollama/ollama#14745](https://github.com/ollama/ollama/issues/14745) — qwen3.5:9b sometimes prints out tool call instead of executing it.** Happens often enough to halt agent work.
- **[ollama/ollama#11662](https://github.com/ollama/ollama/issues/11662) — Issues calling tools with qwen3:32b.**
- **Root cause (per issue #14493 thread):** when an assistant message has thinking + tool calls but no text content, the renderer never emits `</think>`, and the tool call is rendered inside an unclosed `<think>` block, corrupting every subsequent turn the model sees. Additionally: when the last message is an assistant message with tool calls, the renderer treats it as a prefill and never emits the proper generation prompt, which breaks the entire tool call round-trip loop.

**Resolution: Stack researcher was wrong.** Ollama's own docs showcasing `model='qwen3'` is marketing; live user reports in April 2026 confirm tool-calling pipeline bugs across the Qwen3 family (3.0, 3.5, 3.5:9b, 3.5:27B).

- **Keep `qwen2.5-coder:32b` as the pinned local tool-calling baseline.** This was already the CLAUDE.md decision — it stands.
- **Do NOT open `qwen3` as an opt-in baseline** in config until upstream closes #14493 / #14601.
- **P8 eval matrix**: eval suite pins `qwen2.5-coder:32b`; any newer model requires a full Tier-A pass before swap.
- **STACK.md D3's "re-evaluate the pin" guidance is superseded.** The pin holds.

Sources:
- [Qwen 3.5 27B tool calling non-functional (ollama/ollama#14493)](https://github.com/ollama/ollama/issues/14493)
- [Qwen3 malformed tool definitions via /api/chat (ollama/ollama#14601)](https://github.com/ollama/ollama/issues/14601)
- [qwen3.5:9b prints tool calls instead of executing (ollama/ollama#14745)](https://github.com/ollama/ollama/issues/14745)
- [Issues calling tools with qwen3:32b (ollama/ollama#11662)](https://github.com/ollama/ollama/issues/11662)
- [unsloth/Qwen3-Coder-30B GGUF — tool calling fixes](https://huggingface.co/unsloth/Qwen3-Coder-30B-A3B-Instruct-GGUF/discussions/10)

---

## D7 (STACK): Orpheus streaming in mlx-audio-swift — CONFIRMED WORKS

**Original claim (STACK D7):** mlx-audio-swift v0.1.2 has `generateStream` for Chatterbox/Qwen3-TTS but Orpheus's README shows only non-streaming `generate(...)`. BLOCKER status for Step 9; prototype before committing.

**Web-search findings (2026-04-21):** The mlx-audio-swift library added streaming decoding for Orpheus in recent updates. The `generateStream` method yields events including tokens, audio, and info. Orpheus voice selection works with tara, leah, jess, leo, dan, mia, zac, and zoe.

**Resolution: Orpheus streaming works.** Downgrade D7 status from BLOCKER to "verify format + TTFA timing at scaffold." mlx-audio-swift remains the tier-2 TTS primary; TTSKit fallback stays in reserve but is no longer the expected path. The open question becomes empirical performance (target 150–250 ms TTFA via chunked codec output), not feasibility.

Sources:
- [Blaizzy/mlx-audio-swift — main repo](https://github.com/Blaizzy/mlx-audio-swift)
- [mlx-audio-swift — Swift Package Index](https://swiftpackageindex.com/Blaizzy/mlx-audio)
- [mlx-audio releases](https://github.com/Blaizzy/mlx-audio/releases)

---

## Silero VAD v6 — UPGRADE FROM v5

**Original assumption (PLAN/IMPL/STACK):** Silero VAD v5 (`silero_vad_v5.onnx`, 512-sample 32ms chunks at 16 kHz). STACK open question #3: "v6 exists — evaluate at scaffold."

**Web-search findings (2026-04-21):**

- **v6.0** released 2025-08-25 with JIT and ONNX models.
- **v6.2** released 2025-12-10 with `silero_vad_16k_op15.onnx` (16 kHz only, opset 15) and tinygrad 16k models.
- **v6.2.1** released 2026-02-24 — ONNX Runtime is now optional (not required).
- Two model variants for v6:
  - `silero_vad.onnx` — both 8 kHz and 16 kHz models, opset 16
  - `silero_vad_16k_op15.onnx` — 16 kHz only, opset 15 (matches older ORT versions that don't support opset 16)

**Resolution: Use Silero VAD v6.2.1 as the baseline.** The chunk/stride contract (512 samples @ 16 kHz = 32ms) appears preserved; verify at scaffold. If ORT version in `onnxruntime-swift-package-manager 1.24.2+` supports opset 16, use `silero_vad.onnx`; otherwise `silero_vad_16k_op15.onnx`. Update IMPL §8 ONNX MANIFEST.json SHA-256 entries when pinning.

**Roadmap implication:** Add a "Silero v6 validation" checkpoint to the voice-pipeline phase (P6). Not a blocker — v5 still works — but v6 has performance improvements worth taking for greenfield.

Sources:
- [snakers4/silero-vad — main repo](https://github.com/snakers4/silero-vad)
- [snakers4/silero-vad releases](https://github.com/snakers4/silero-vad/releases)
- [Silero VAD version history wiki](https://github.com/snakers4/silero-vad/wiki/Version-history-and-Available-Models)
- [onnx-community/silero-vad on Hugging Face](https://huggingface.co/onnx-community/silero-vad)

---

## macOS 26 Tahoe `speech-recognition-assets` entitlement — UNRESOLVED, KEEP AT SCAFFOLD

**Original assumption (AUDIT-R2-S5):** macOS 26 Tahoe `SpeechAnalyzer` requires `com.apple.developer.speech-recognition-assets` entitlement plus `NSSpeechRecognitionAssetsUsageDescription` Info.plist key; missing either causes silent `SFSpeechErrorCode.assetUnavailable` on first-launch Release.

**Web-search findings (2026-04-21):** Neither Apple developer docs nor Context7 index the specific entitlement key `com.apple.developer.speech-recognition-assets` nor the Info.plist key `NSSpeechRecognitionAssetsUsageDescription`. Only the classic `NSSpeechRecognitionUsageDescription` (for SFSpeechRecognizer, cloud-routed) is indexed. `SpeechAnalyzer`'s own Apple developer doc page doesn't detail the entitlement requirements (likely updated post-WWDC25).

**Resolution: KEEP R2-S5 as a load-bearing but unverified claim.** Two scenarios:
1. **Claim is correct, docs lag** — plausible given SpeechAnalyzer is a macOS 26-only API.
2. **Claim is speculative** — derived from Personal Voice precedent; R2-S5 auditor may have extrapolated.

Either way, **verify at scaffold via the test in PITFALLS #12**: cold-launch a Release build on macOS 26 with the entitlement removed; confirm `SFSpeechErrorCode.assetUnavailable` fires (positive-result confirms the claim) or STT works without it (refutes). Keep the entitlement + Info.plist key in `Jarvis.entitlements` either way — inclusion is cheap, omission on first-launch Release is a silent-break failure mode.

**Roadmap implication:** Phase 1 entitlement scaffolding must include the pair from day one; Phase 6 (voice) adds the scaffold-time verification.

Sources:
- [SpeechAnalyzer — Apple Developer Documentation](https://developer.apple.com/documentation/speech/speechanalyzer)
- [NSSpeechRecognitionUsageDescription — Apple Developer](https://developer.apple.com/documentation/bundleresources/information-property-list/nsspeechrecognitionusagedescription) (classic key; does not mention assets variant)
- [Asking Permission to Use Speech Recognition — Apple Developer](https://developer.apple.com/documentation/speech/asking-permission-to-use-speech-recognition)
- [otaviocc/Stenographer — macOS Tahoe SpeechAnalyzer example](https://github.com/otaviocc/Stenographer) — practical reference app; inspect its entitlements at scaffold
- [iOS 26 SpeechAnalyzer Guide (Anton Gubarenko)](https://antongubarenko.substack.com/p/ios-26-speechanalyzer-guide)
- [Apple Transcription APIs faster than Whisper — MacRumors](https://www.macrumors.com/2025/06/18/apple-transcription-api-faster-than-whisper/)

---

## Summary: effect on downstream phases

| Delta | Affected downstream | Action |
|-------|---------------------|--------|
| D1: Opus 4.7 exists | P4 (AnthropicProvider) | **No change.** Pin `claude-opus-4-7` as string model ID; ignore SDK enum lag. |
| D3: Qwen3 broken (pitfalls correct) | P4 (OllamaProvider) + P8 (eval matrix) | Keep `qwen2.5-coder:32b` pinned. Do NOT enable Qwen3 opt-in. Eval pins the model. |
| D7: Orpheus streaming works | P6 (voice, Orpheus tier-2) | Downgrade from BLOCKER to scaffold-time verify. mlx-audio-swift remains primary; TTSKit stays in reserve. |
| Silero v6.2.1 available | P6 (VAD) | Upgrade from v5. Verify 16 kHz / 32ms contract holds; update IMPL §8 MANIFEST with v6.2.1 SHA-256. |
| SpeechAnalyzer entitlements | P1 (entitlement scaffolding) + P6 (verify probe) | Include entitlement + Info.plist key from day one; verify at scaffold via Release cold-launch. |

No roadmap-structural implications. All deltas flow into existing phases.
