# AUDIT-R4 — Round-Four Whiteroom Findings

**Date:** 2026-04-17
**Reviewed:** `docs/PLAN-week-one.md` rev 3, `docs/IMPL-week-one.md` rev 3
**De-duped against:** `docs/AUDIT-R1.md`, `docs/AUDIT-R2.md`, `docs/AUDIT-R3.md`
**Source:** six parallel specialist reviewers (architecture / Swift·macOS / security / voice·audio / LLM streaming / build·eval), briefed architecture-only per R3 scope clarification

## Scope (unchanged from R3)

A-tier only. C-tier (exact API names, xcconfig values, Swift symbol exactness, Info.plist key spellings) continues to track in AUDIT-R3's implementation checklist and is not evaluated here.

Totals (A-tier only):

| Namespace | HIGH | MEDIUM | Combined |
|---|---:|---:|---:|
| R4-A (architecture) | 5 | 5 | 10 |
| R4-S (Swift/macOS) | 2 | 2 | 4 |
| R4-V (voice/audio) | 3 | 2 | 5 |
| R4-L (LLM streaming) | 4 | 4 | 8 |
| R4-Sec (security) | 2 | 3 | 5 |
| R4-B (build/eval) | 6 | 6 | 12 |
| **Total** | **22** | **22** | **44** |

**Convergence read:** R3 predicted "≤3 A-tier MEDIUM and 0 A-tier HIGH" for round 4. Actual is 22 HIGH + 22 MEDIUM. Round 4 did **not** converge. The architecture-level decisions in R3 are sound — the failure is that R3 fixes landed as decision-log entries and prose in one section but were not propagated to downstream typed schemas, TS mirror, file layout, or CI wiring. Most findings are mechanical wiring work; none require rearchitecture.

---

## Cross-cutting themes (what R3 missed)

1. **Typed-schema downstream drift (biggest cluster, 8 findings).** R3 committed `HudState` to include `.booting`/`.awaitingConfirmation`/`.reconfiguring` (A12, V1, confirmation flow), `TurnTerminator` to include `.crashRecovered` (A4), `SwiftToJS` to include `.systemReady`/`.retryStarted` (A11, L3), `ConfirmRequest` to collapse `confirmId`→`toolCallId` (A6), `TurnSource` to add `.eval`/`.replay` (A10), `ReplayEvent` as back-pressure primitive (A9), `VoiceController.events` as subscribe target (lifecycle step 9). In rev-3 IMPL, the Swift enums, the TS mirror, and the SQL schema comments disagree pairwise on case names, present/missing cases, and string tokens. A single `grep` across §4 / §6 / §8 / §12 surfaces the contradictions.
2. **R3-S15 scripts-and-layout drift (major cluster, 6 findings).** §1 file layout was not updated when R3-S15 added `prime-tcc.sh`, `verify-models.sh`, `verify-fixtures.sh`, `check-bus-protocol-version.sh`, `check-plist-parity.sh` and renamed `sign-and-notarize.sh → codesign.sh`. Downstream sections (§8, §13, §15) cite the scripts that §1 doesn't know exist; §14 CI runs none of the round-3 invariant tests.
3. **Concurrency ordering / contract completion (7 findings).** R3 named concurrency primitives (AsyncChannel, withTaskGroup, actor MCPServerHandle) but left ordering of cooperating actors unspecified at several seams: ConfirmationBroker vs ConfirmationPresenter MainActor hops, barge-in replay-row ordering, pre-`.systemReady` audio-graph consumer, FD_CLOEXEC seam for MCP restart, readiness primitive double-spec (channel-suspend vs separate CheckedContinuation), retry turn-identity (fresh vs continuing), stream_truncated retry budget.
4. **Matrix incompleteness for voice rebuild triggers (5 findings).** R3-V5 promised pre-warm re-run on all four rebuild triggers; rev-3 spells out only SpeechAnalyzer + Orpheus warm-up, not the Orpheus format-probe re-run on AEC-fallback. Sustained-overflow threshold is prose ("beyond a brief burst") not a measurement. Variant B ducking-exit event not tied to `.ttsStopped`. Persisted-probe corruption/stale-read recovery undefined.
5. **Security boundary completion regressions (5 findings).** PLAN risks row 160 still carries the R3-Sec3-removed Keychain-hash text (direct regression — the row was not edited). IMPL §6 turn-loop pseudocode doesn't name the source of `toolCallEnd.preview`, so the R3-Sec2 "unwrapped previews" contract is unenforceable from the spec. Sanitize pipeline's call-site list (R3-Sec4) covers log/replay but not the tool-result bytes before they pack into `LLMMessage` history. `runModal` lint ban is scoped to `ConfirmationPresenter` only, not to all main-actor presentation paths. `ToolCallStart.args` pre-approval masking (R3-Sec13 — tracked C-tier) is actually an A-tier bus-contract gap.
6. **LLM protocol contracts (3 findings).** R3-L2 tool-choice policy did not land anywhere in IMPL — zero occurrences of `tool_choice` / `Tool-choice` in the doc. `stream_truncated` retry budget undefined (no `MAX_STREAM_TRUNCATED_RETRIES_PER_TURN`). `input_json_delta` byte-vs-string normalization unspecified at contract level (Anthropic SSE string-fragment bytes vs Ollama native-object bytes are both typed `Data`).
7. **Step-number drift in §17.1 (1 finding but wide blast radius).** Rev-3 expanded startup to 12 steps; cross-references in §17.0 narrative, §17.1 step 3, and PLAN decision-log R3-S4 still cite the old step-9 numbering.
8. **TCC envelope for `NSEvent.addGlobalMonitorForEvents(.keyDown)` missing (1 finding).** Input Monitoring is required for global-monitor `.keyDown` observation on Sequoia/Tahoe; §17.1 step 10 names the monitor pair but not the TCC prompt, denial-detection, or degraded-mode flow — the same gap R2-V10 closed for microphone, now open for hotkey.

---

## Findings — HIGH (22)

### R4-A · Architecture

**R4-A1 · `HudState` enum is missing four load-bearing cases.**
Swift `HudState` (§4) is `idle | listening | thinking | speaking`. PLAN precedence ladder and §8/§17 prose require `.booting` (R3-A12), `.awaitingConfirmation` (R2-A5), `.reconfiguring` (R3-V1). Single-writer precedence `awaitingConfirmation > speaking > listening > thinking > idle > booting` is not expressible against the current enum. **Fix:** expand Swift + TS mirror to `{ booting, idle, listening, thinking, speaking, awaitingConfirmation, reconfiguring }`; disambiguate `.reconfiguring` as either a publishable state or a coordinator-held flag (both are currently claimed).

**R4-A2 · TS `confirmRequest` still carries both `confirmId` and `toolCallId` after R3-A6 collapsed them.**
IMPL §4 Swift has single field; TS mirror still has both. First round-trip test fails. **Fix:** strike `confirmId` from the TS variant.

**R4-A3 · `TurnTerminator` mapping table in §12 uses `.modelStop` (not in enum — enum has `.endTurn`) and omits `.voiceBargeIn`, `.confirmationTimeout`, `.confirmationDenied`, `.internalError`.**
CHECK constraint and viewer switch driven from either source disagree with the other. **Fix:** rename to `.endTurn`; add missing rows; declare mapping exhaustive over the enum via compile-time `switch` with no `default`.

**R4-A4 · `ReplayEvent` type referenced but never defined; never-drop list names kinds (`reconfiguring`, `user_input`, `confirmation_requested/resolved`) that don't match `AgentOrchestrator.Event`.**
Back-pressure policy is uncodeable from the spec; `ReplayBackpressureTests` has no schema. **Fix:** define `ReplayEvent` with exhaustive case list; map each case to (producer, SQL `event_type` string, payload).

**R4-A5 · `VoiceController.events` enum is undefined.**
§17.1 step 9 requires the HUD coordinator to subscribe to it before emission; precedence and state-machine rules reference voice events (`.ttsStopped`, `.wakeDetected`, `.reconfiguring`, `.audioModeDegraded`, `.rawRingDrop`, VAD events) with no typed enum. **Fix:** add `public enum VoiceEvent: Sendable { ... }` to §8 and reference from §17.1 step 9; name the primitive (channel vs stream).

### R4-S · Swift/macOS

**R4-S1 · §17.1 step-number drift breaks every cross-reference to the hotkey step.**
Rev-3 expanded startup to 12 steps; prose in §17.0, §17.1 step 3, PLAN thread/actor model, PLAN decision log R3-S4 all still cite step 9 for hotkey (now step 10). Webview-ready cited as step 7 (now step 8). **Fix:** name dependencies, not step indices ("hotkey registration depends on the webview-ready barrier and on the orchestrator event-stream-subscription barrier"); drop numeric cross-references from prose; keep numbers only in step-number column.

**R4-S2 · Input Monitoring TCC envelope for `NSEvent.addGlobalMonitorForEvents(.keyDown)` unspecified.**
Observing `.keyDown` system-wide triggers a TCC prompt on first fire; a denied prompt silently converts the global monitor into a no-op. §17.1 step 10 names the monitor pair but no denial-detection, no HUD banner, no degraded-mode flow. **Fix:** treat Input Monitoring like microphone: probe via `IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)` or first-fire watchdog; add HUD "hotkey disabled — grant Input Monitoring" with System-Settings deep link; local-monitor-only degraded mode when global is denied; add to §17.2 ready-signals table.

### R4-V · Voice/audio

**R4-V1 · Pre-warm re-run matrix drops Orpheus format-probe on 3 of 4 rebuild triggers.**
§8 "Graph rebuild sequence" step 6 re-runs SpeechAnalyzer pre-warm and Orpheus warm-up, but not the format probe. Variant B spec re-runs the probe but doesn't enumerate the warm-up. These are distinct contracts (probe inspects `AVAudioFormat`; warm-up spins inference). **Fix:** in §8 step 6, add a 3-column matrix: trigger × {SpeechAnalyzer pre-warm, Orpheus probe, Orpheus warm-up}, with an unambiguous row per trigger. AEC-fallback triggers all three; device-change and mic re-grant trigger pre-warm + warm-up only (probed format stays valid).

**R4-V2 · Wake-word-during-confirmation routing pinned in §7 but not reciprocated in §8.**
§8 "Control-plane state machine" only pointer-cites R3-V6; it does not state that the wake-word DAG must stay live during `.awaitingConfirmation`, who decides the routing (`VoiceController` vs coordinator), or that the post-barge submit uses `cancelAndSubmit` (R3-A3), not bare `submit`. **Fix:** add a §8 subsection "Wake-during-confirmation routing (R3-V6)" pinning all three.

**R4-V3 · Orpheus format-probe persistence has no corruption / stale-read recovery.**
§17.1 step 6 skips the probe when `config.json: voice.orpheus.output_format` is present; nothing covers invalid JSON, semantically wrong values (sampleRate=0), or stale values from a prior `mlx-audio-swift` version. **Fix:** validate persisted fields at launch; on any failure, delete the subkey and re-probe. Version-stamp with `probedWithPackageVersion`; mismatch → re-probe. Policy for `config.json` wholly unparseable: log, use in-memory defaults, do not overwrite, force tier-1 until user repairs.

### R4-L · LLM streaming

**R4-L1 · R3-L2 tool-choice policy never landed.**
Zero occurrences of `tool_choice` / `Tool-choice` in PLAN or IMPL. §6 cap-recovery pseudocode makes "one more model call" with tools array still attached and `tool_choice` unset — provider is free to request another tool call and re-enter the loop. **Fix:** add `toolChoice: ToolChoice` parameter to `LLMProvider.stream(...)`; cap-recovery call sets `.none` (Anthropic: `tool_choice: {type:"none"}`; Ollama: omit tools array entirely); eval scenario asserts zero `toolUseRequested` on the recovery call.

**R4-L2 · `TurnSource` enum vs SQL column comment disagree on tokens.**
Swift enum `case text, voice, eval, replay`; SQL comment `"user" | "wake" | "eval" | "replay"`. No CHECK constraint on `turn_source` column, so ingest won't catch drift. **Fix:** pick one taxonomy (recommend `user | wake | eval | replay` — "voice" collides with TTS output elsewhere); update enum rawValue mapping; add SQL CHECK constraint.

**R4-L3 · `.retryStarted` and `.systemReady` have no `SwiftToJS` decoder path.**
§6 defines them on `AgentOrchestrator.Event`; §12 admits them as replay `event_type`; R3-L3 requires webview to render retry as replacement/continuation — but `SwiftToJS` and the TS mirror have neither case. TS `HudState` union also missing `'booting'`. **Fix:** add `case systemReady` and `case retryStarted(turnId: UUID)` to `SwiftToJS` + TS mirror; add `'booting'` to TS `HudState`.

**R4-L4 · `stream_truncated` retry budget undefined.**
IMPL §5 retry policy covers `overloaded_error` / `rate_limited` / `network` / 5xx with a 3-attempt cap; `stream_truncated` is in the ProviderError taxonomy but has no budget. `retry_of` forms a potentially unbounded chain. **Fix:** pin trigger (user-initiated via `JSToSwift.retry(turnId)` vs auto-retry); add `MAX_STREAM_TRUNCATED_RETRIES_PER_TURN = 1`; second truncation in same turn emits terminal `.providerError`, no further `.retryStarted`.

### R4-Sec · Security

**R4-Sec1 · PLAN risks row 160 still asserts the Keychain config-integrity hash that R3-Sec3 removed.**
Direct regression: rev-3 added the R3-Sec3 row with the honest disclaimer at line 171 but did not edit the R2-Sec6 row at line 160, which still reads "Config hash in Keychain; mismatch warns and reverts." A reader stopping at the first row implements the theater control R3-Sec3 condemned. Same residue in IMPL §6 line 816 parenthetical. **Fix:** strike the hash clause from both sites; mark R2-Sec6 row as superseded or merge with R3-Sec3 row.

**R4-Sec2 · `toolCallEnd.preview` source unspecified in §6 turn-loop pseudocode.**
R3-Sec2 requires previews to be unwrapped content with no nonce leakage. Pseudocode publishes `toolCallEnd(ok: !result.isError)` without naming which string feeds `preview`; both candidate values (`content` after `headTruncate`, `wrapped` after `wrapUntrusted`) carry `turnNonce` in their text. `NonceLeakageTests` will catch it but the contract should be airtight in the spec. **Fix:** introduce a named variable `rawForPreview = sanitize(result.content)` before truncation; derive `preview` from that (post-sanitize, pre-truncate, pre-wrap); publish `toolCallEnd(ok:..., preview: previewSlice(rawForPreview))`. Add a sentence to R3-Sec2 contract making this explicit.

### R4-B · Build/eval

**R4-B1 · §1 `scripts/` directory still lists only two scripts; R3-S15's six additions never landed.**
Missing from §1: `codesign.sh` (rename of `sign-and-notarize.sh`), `check-plist-parity.sh`, `verify-models.sh`, `verify-fixtures.sh`, `check-bus-protocol-version.sh`, `prime-tcc.sh`. Downstream sections reference all of these. **Fix:** expand §1 enumeration with one-line purpose comments per R3-S15.

**R4-B2 · `build-webview.sh` content-hash sentinel (R3-B9) not adopted; §9 still describes timestamp-newer sentinel.**
R3-B9 rejected `-nt` timestamp checks in favor of `shasum -a 256 pnpm-lock.yaml` → `.build/pnpm-lock.sha256`. §9 line 1424 still reads "Xcode skips when newer than inputs." **Fix:** rewrite §9 sentinel bullet to content-hash form; pin sentinel file as the Xcode Output File; add `.tool-versions` pnpm assertion (R3-B16).

**R4-B3 · §14 build flow does not mention the `MCPIntegrationTests` scheme pre-action or `MCP_BINARIES_DIR`.**
R3-B5 required §14 AND §15 to document; only §15 has it. **Fix:** add `xcodebuild test -scheme MCPIntegrationTests -destination 'platform=macOS'` to §14 Release build + CI lists; note the pre-action exports `MCP_BINARIES_DIR=$BUILT_PRODUCTS_DIR/Jarvis.app/Contents/Helpers`.

**R4-B4 · CI surface (§14) does not run any of the ten R3 invariant tests.**
§14 runs only `Core` and `LLMProviders` schemes; 6 of 10 invariants live in `Agent`, `WebviewBridge`, `MCPIntegrationTests`. **Fix:** expand CI list to run every owning scheme (add `Agent`, `WebviewBridge`, `MCPIntegrationTests`) or define an aggregate `AllTests` scheme.

**R4-B5 · Replay-roundtrip oracle masking helper under-specified + path typo.**
§13 "A diff helper is checked in under `evals/helpers/replay-diff.swift`" — §1 layout puts eval under `eval/` (singular); path typo. Mask set under-specified — is `messageId` masked? `tool_use_id`? `session_id`? `monotonic_ns`? **Fix:** correct path to `eval/helpers/replay-diff.swift`; enumerate full mask set (`row_id, session_id, turn_id, tool_use_id, message_id, ts, monotonic_ns, turn_nonce`); state tool-call parity is by sequence index, not literal string match.

**R4-B6 · Eval runner exit-code contract does not distinguish `.eval` vs `.replay` failures.**
§13 says "exits non-zero on any failure." CI cannot gate differently on deterministic replay-oracle failures vs flaky live-eval failures. **Fix:** `0 = pass, 1 = eval fail, 2 = replay-oracle fail, 3 = infra`. Pin `--source replay` / `--source eval` flag; CI fails hard on exit 2.

---

## Findings — MEDIUM (22)

### Architecture
- **R4-A6** · Startup readiness primitive double-spec. PLAN says `AsyncChannel.send` is the gate (blocks until consumer pumps); IMPL §17.1 step 9 adds a separate `CheckedContinuation`. Pick one; remove the other.
- **R4-A7** · Pre-`.systemReady` audio-graph has a producer (step-4 tap) but no specified consumer until step 12. Raw-ring overflow trigger could fire during startup and recurse. **Fix:** either start converter worker + wake-word DAG (discarding detections) at step 4, or defer engine start to step 12.
- **R4-A8** · Retry-continuation turn identity unspecified: same `turnId` continuing, or fresh `turnId` with `retry_of`? Affects TurnSnapshot inheritance and `MAX_TOOL_CALLS_PER_TURN` budget. **Fix:** pin "fresh turnId with `retry_of`; TurnSnapshot re-snapshot; tool-call budget resets" (or the opposite — pick and document). Add matrix rows for retry-success and retry-exhaustion.
- **R4-A9** · `.reconfiguring` has three roles (voice state, never-drop replay event, HUD-hold signal) with none fully defined. **Fix:** define `VoiceEvent.reconfiguringStarted / reconfiguringEnded`; map to ReplayEvent kind; coordinator policy: on start, hold current state; on end, re-emit last pre-reconfigure state.
- **R4-A10** · Voice barge-in → `bargeCancel` replay-row ordering unpinned: does the synthetic deny flow as a normal `tool_result` before `.voiceBargeIn`, or does barge short-circuit? Affects replay-roundtrip oracle determinism. **Fix:** pick one (recommend short-circuit: `.voiceBargeIn` closes immediately, no synthetic tool_result appended).

### Swift/macOS
- **R4-S3** · `ConfirmationBroker` wake-barge flow crosses three actors (broker, MainActor sheet, orchestrator) with no named transition authority. Two transitions racing on the same sheet land on a dead panel reference. **Fix:** broker is the sole transition authority; removes `toolCallId` entry atomically; hops once to a typed `@MainActor ConfirmationPresenter` sink for sheet close. Late hops no-op on missing entry.
- **R4-S4** · Long-lived parent FDs have no named `ChildSpawnGate` seam on MCP restart. A post-boot-opened FD without `FD_CLOEXEC` leaks into a restarted child. **Fix:** single `ChildSpawnGate` for every `Process()` instantiation; contract enforces every FD carries `FD_CLOEXEC` before `launch()`; debug assertion walks `/dev/fd`.

### Voice/audio
- **R4-V4** · Raw-ring sustained-overflow rebuild trigger has no measurement definition. "Beyond a brief burst" is prose. **Fix:** name `N consecutive worker wakes spanning ≥ T ms` + 30 s rebuild-loop guard. Exact N/T are C-tier; the shape (count + time + guard) is A-tier.
- **R4-V5** · Variant B ducking-aggressiveness exit not tied to `.ttsStopped`. If duck is lowered on `TTSEvent.finished` before the fade tail completes, wake-word self-triggers on the tail. **Fix:** "ducking is raised on `.speaking` entry and lowered **only** on `.ttsStopped`; `TTSEvent.finished` / `.playbackDrained` do not lower duck on their own."

### LLM streaming
- **R4-L5** · Confirmation-during-stream contract missing for Ollama multi-tool-call case. Anthropic stream terminates at `.stopReason(.toolUse)`, but Ollama native NDJSON can stream multiple tool calls before `done:true`. Pseudocode's `for try await` would keep pulling frames while broker await blocks. **Fix:** "while `confirmationBroker.response` is awaited, provider stream is not drained further; subsequent events buffered, re-processed on approve; discarded on deny/timeout."
- **R4-L6** · `replayToModel` provider-id reconstruction under-specified. §12 says "rebuilds provider id from stored value"; replay row payload format for `tool_call_start/end` is not enumerated. If only the local UUID is persisted, Anthropic 400s on replay (`tool_use_id` requires opaque `toolu_...`). **Fix:** spell out replay payload schema: `{ localId: UUID, providerId: String, name: String, args: JSON }`; `replayToModel` reads paired `tool_call_start` of same turn_id.
- **R4-L7** · `TurnSource.replay` MCP-dispatch and TTS suppression unspecified. Turn-loop unconditionally calls `mcpClient.callTool(...)` and publishes `.tokenDelta` — a `.replay` turn would re-execute AppleScript (side effect!) and re-speak. **Fix:** `.replay` routes through `ReplayMCPAdapter` returning recorded `tool_result` without real dispatch; `.replay` + `.eval` both suppress TTS subscription. Only `.user` / `.wake` dispatch + speak.
- **R4-L8** · `input_json_delta` byte-vs-string framing under-specified at contract level. `Data` type blurs Anthropic SSE string-fragment bytes vs Ollama native-object bytes. **Fix:** contract is "always UTF-8-encoded serialized JSON object." Anthropic decoder concatenates fragments, validates at `content_block_stop`. Ollama native decoder re-serializes to UTF-8. Cross-provider fixture asserts byte-identical `Data`.

### Security
- **R4-Sec3** · R3-Sec4 sanitize pipeline call-sites cover log + replay but not tool-result content before packing into `LLMMessage` history. Trojan-source bytes pass through `wrapUntrusted` into the model context. **Fix:** add `let sanitized = Sanitize.forModel(result.content)` before `headTruncate` in the turn-loop pseudocode; extend §11 call-site list.
- **R4-Sec4** · `runModal` lint ban is scoped to `ConfirmationPresenter` module only. Future confirmation surfaces (permission guidance, API-key setup sheet, AppleScript-compile-failure dialog) can re-create the R3-S3 bug. **Fix:** broaden the lint rule to every file reachable from `@MainActor` presentation paths while an orchestrator turn or voice state is active. Apply across `packages/Agent/`, `packages/Voice/`, AppKit layer in `apps/JarvisApp/`; narrow allowlist for fatal-error crash dialog from §17.4.
- **R4-Sec5** · `ToolCallStart.args` pre-approval masking is tracked C-tier (Sec13) but is actually an A-tier bus-contract gap. Full script ships to webview before confirmation even though the approve/deny is native. **Fix:** promote to A-tier; §4 contract: `ToolCallStart.args` for any tool in `requiresConfirmation` serializes as `{ "awaitingApproval": true }`; real args cross only to native `ConfirmationBroker` and post-approval `mcpClient.callTool`.

### Build/eval
- **R4-B7** · §15 invariant table missing "Owner target" column despite the line-1800 promise. Only 2 of 10 invariants have owners disclosed. **Fix:** add fourth column with explicit target names per test (SubmitOutcomeTests → AgentTests, etc.).
- **R4-B8** · `check-bus-protocol-version.sh` (R3-B18) not wired in §4 or §9. **Fix:** add §4 bullet "parity enforced at build time by `scripts/check-bus-protocol-version.sh` as an Xcode pre-build Run Script phase before Compile Sources"; mirror in §9.
- **R4-B9** · `verify-fixtures.sh` (R3-B17) not referenced from §8 or §13. A swapped fixture silently drifts `voice-mock-full-loop`. **Fix:** pin voice fixtures by SHA-256 in `eval/fixtures/voice/MANIFEST.json`; script runs as `MCPIntegrationTests` and `eval-runner` scheme pre-action.
- **R4-B10** · §1 still lists `sign-and-notarize.sh`; R3-S15 renamed to `codesign.sh --notarize`. **Fix:** rename in §1.
- **R4-B11** · §13 primary scenario coverage table has no Tier column; reader cannot see which scenarios require `prime-tcc.sh`. **Fix:** add Tier A/B column; mark `applescript-*` scenarios as Tier B.
- **R4-B12** · §15 top-level test-layer/target table has no row covering the R3 invariants; the 10 invariants are invisible to the canonical map. **Fix:** add row "R3 invariants | unit + integration | XCTest; per-contract owner target"; or fold the owner column into the top-level table.

---

## Items verified (non-findings, prevent re-litigation)

- AppDelegate single-owner for startup barrier chain (R3-S2): landed cleanly in §17.0.
- Main app's `automation.apple-events` entitlement removed (R3-S5): landed; post-build assertion cited.
- NSPanel focus model (R3-S10): landed.
- MCP helper link model (R3-S1) — static link chosen and pinned.
- Hotkey pair-monitor design (R3-S4): structure landed (except for step-number cross-ref drift R4-S1 and TCC envelope R4-S2).
- Non-blocking confirmation sheet (R3-S3): landed in `ConfirmationPresenter` (except for cross-actor-hop ownership R4-S3 and narrow lint scope R4-Sec4).
- Six-step audio-graph rebuild sequence: landed across all four triggers.
- AEC-on / AEC-off variant split: landed.
- TTS `withTaskGroup` + `channel.finish()` lifetime binding (R3-V4): landed.
- mcp-clipboard `NSPasteboardTypeFileURL` refusal (R3-Sec5): landed correctly at type-set check, not string-empty check.
- `run_applescript` skip-allowlist absence (R3-Sec6): landed; no regex-bypass path.
- SHA-256 digest over compiled bytes (R3-Sec7): landed.
- `replayToModel` single-entry helper (R3-Sec11): landed (except for provider-id reconstruction R4-L6).
- Webview hardening four-pack (R3-Sec1): landed as §9 design contracts.
- `Core/Logging/Sanitize.swift` pipeline (R3-Sec4): landed in §10 (except for tool-result-to-LLM call-site gap R4-Sec3).
- Ingestion back-pressure with `replay_overflow` marker (R3-A9): landed (except for undefined `ReplayEvent` type R4-A4).
- Terminator → stopReason → row-shape mapping (R3-A4): landed (except for enum case-name drift R4-A3).
- `SubmitOutcome` + `cancelAndSubmit` atomic entry (R3-A1, R3-A3): landed.
- `LaunchSnapshot` vs `TurnSnapshot` config bifurcation (R3-A2): landed in §17.5 (except for PLAN risks-row regression R4-Sec1).

---

## Convergence signal

Round-4 is not convergent: 22 HIGH + 22 MEDIUM A-tier findings exceed the R3-predicted ceiling by an order of magnitude. **But** the shape of the findings is consistent with "wiring not yet propagated" rather than "architecture is wrong":

- **36 of 44 findings** are schema/wiring completions of decisions R3 already made: rename an enum case, add the missing TS mirror row, extend §1 layout, wire the script into CI. These are mechanical.
- **6 findings** are ordering/contract completions the R3 fix-list called out but didn't fully pin (readiness primitive, retry turn identity, barge-in replay ordering, wake-during-confirmation §8 reciprocity, tool-result sanitize call-site, preview source).
- **2 findings** are genuine new A-tier gaps R3 missed: Input Monitoring TCC envelope for `NSEvent` global monitor (R4-S2), and tool-choice policy never landed in any section (R4-L1).

If rev-4 closes all 22 HIGH + 22 MEDIUM with surgical edits to the enums, the TS mirror, §1 layout, §12 mapping table, §14 CI, and the §17 cross-references, round-5 should return ≤3 A-tier MEDIUM and 0 A-tier HIGH — the original R3 prediction for round-4, offset by one round.

The C-tier implementation checklist from AUDIT-R3 carries unchanged into rev-4 work.
