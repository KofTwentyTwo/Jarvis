# AUDIT-R3 — Round-Three Whiteroom Findings

**Date:** 2026-04-17
**Reviewed:** `docs/PLAN-week-one.md` rev 2, `docs/IMPL-week-one.md` rev 2
**De-duped against:** `docs/AUDIT-R1.md`, `docs/AUDIT-R2.md`
**Source:** six parallel specialist reviewers (architecture / Swift·macOS / security / voice·audio / LLM streaming / build·eval)

## Scope clarification (applied 2026-04-17 mid-round)

The audit loop gates on **design and architecture correctness**, not code-level API-exactness. R3 findings are split into two tiers:

- **Architecture (A-tier)** — contradictions, missing contracts, missing schema, policy gaps, ordering/lifecycle design, decision points that require commitment. These block convergence.
- **Code-level (C-tier)** — specific API names, exact signature forms, shell-script edge cases, linter configs, Xcode settings, precise Info.plist keys. These are tracked in the implementation-time checklist (§Implementation checklist below) and do **not** block convergence.

Totals (A-tier / C-tier / combined):

| Namespace | A-tier HIGH | A-tier MEDIUM | C-tier (deferred) | Combined |
|---|---:|---:|---:|---:|
| R3-A (architecture) | 5 | 8 | 3 | 16 |
| R3-S (Swift/macOS) | 5 | 3 | 10 | 18 |
| R3-V (voice/audio) | 4 | 6 | 3 | 13 |
| R3-L (LLM streaming) | 0 | 3 | 4 | 7 |
| R3-Sec (security) | 6 | 3 | 4 | 13 |
| R3-B (build/eval) | 3 | 2 | 13 | 18 |
| **Total** | **23** | **25** | **37** | **85** |

**Exit criteria (unchanged from R2, refined by scope clarification):** Rev 3 of PLAN + IMPL must resolve all A-tier HIGH and A-tier MEDIUM findings (or defer with a written accepted-risk note). C-tier findings are captured in the implementation checklist and do not block round-N convergence.

---

## Cross-cutting architectural themes

1. **Partial-application regressions on R2.** Three R2 HIGHs were closed in the decision log but only partially landed in the spec body: Sec3 webview hardening (four required controls absent from IMPL), Sec6 config integrity (same-user forgeable = theater), Sec2 AppleScript allowlist (skip-allowlist reintroduced the regex-matching shape Sec2 condemned).
2. **Contract drift at enum/schema seams.** Replay terminator "crashed" isn't in the enum (A4); `.systemReady` event referenced but not defined (A11); no `.booting` HUD state (A12); `TurnSource` still missing `.eval`/`.replay` (A10); `ContentBlock.toolResult.id` lacks provider-id distinction (L7); `ConfirmRequest` duplicates `confirmId` and `toolCallId` (A6).
3. **Contradictions between spec sections.** §6 `TurnConfig` vs §17.5 hot-reload rules on `provider` (A2); confirmation-timeout row in lifecycle matrix uses `.endTurn` but names a different terminator (A7).
4. **Audio-graph rebuild sequencing.** R2 specified steady-state; R3 finds four rebuild triggers (device change, AEC fallback, mic re-grant, producer overflow) with no canonical teardown order (V1, V2, V5, V8) and no warm-up symmetry for Orpheus (V10) or pre-warm re-run after rebuild (V5).
5. **Concurrency contract gaps.** `PendingSubmission.continuation` can't express the displacement policy (A1); voice barge-in needs atomic cancel+submit (A3); MCP crash-restart needs dedupe (A13); `AsyncChannel` TTS seam deadlocks on producer cancel (V4); `ReplayLog` has no back-pressure (A9); startup readiness needs a named primitive, not "hold the producer" (A5).
6. **Confirmation flow is blocking when the design requires it to be cancellable.** `NSAlert.runModal()` pattern (S3) means voice barge-in can't cancel the modal; confirmation must be non-blocking by design.
7. **Webview security posture under-specified.** Nonce rotation rule not pinned (Sec2); replay-feed paths bypass the wrapping contract (Sec11); `toolCallStart.args` leaves the app before approval (Sec13 — C-tier, tracked).
8. **Threat-model isolation gaps.** Main app still holds `com.apple.security.automation.apple-events` after the helper restructure (S5); clipboard helper returns file-URL paths as plain text despite Sec13 (Sec5); skip-allowlist invites the regex-bypass Sec2 warned about (Sec6).
9. **Startup & window model ambiguity.** `@main App` vs `AppDelegate` ownership for the startup barrier chain (S2); panel focus/activation model (S10, S14); hotkey monitor pair as a design (S4); nested helper link model (S1).
10. **Streaming protocol contracts.** `tool_choice` unspecified (L2); retry doesn't bracket already-emitted tokens (L3); `input_json_delta` byte-vs-string semantics (L1).
11. **Eval/replay machinery.** Replay-roundtrip oracle undefined (B12); Tier-B TCC priming protocol missing (B8); test target kind unsettled (B5); `TurnSource` missing eval/replay case (A10).

---

## Architecture findings — HIGH (23)

### R3-A · AgentOrchestrator / lifecycle

**R3-A1 · Pending-submission displacement needs two signals per slot, not one.**
Policy requires both "resume displaced caller with false" and "park newcomer until turn starts" on the same slot. A single `CheckedContinuation<Bool, Never>` can't do both. **Fix:** Split into two continuations per pending entry — `displaceContinuation` (resolved `false` on displacement only) and `runContinuation` (resolved when the turn actually runs); caller awaits whichever fires first. Alternative: make `submit` return `enum SubmitOutcome { ran, superseded, rejected }` where the outer call is non-suspending after enqueue. Pick one. Invariant test: two consecutive `submit()` while a turn is active yields exactly one `.ran` and one `.superseded`.

**R3-A2 · Config snapshot vs §17.5 hot-reload contradict each other for `provider`.**
§6 puts `provider` inside the per-turn snapshot (hot-reload between turns). §17.5 lists `provider` as security-relevant, launch-snapshotted, no hot-reload. Both cannot be true. **Fix:** Bifurcate config into two explicit buckets:
- `launchSnapshot` (security): `applescript.*`, tool blocklist, `ollama.base_url` host allowlist, confirmation-policy knobs.
- `perTurnSnapshot` (non-security): `provider`, `ttsTier`, `sttUseWhisperKit`.
Attempting to include a security key in `perTurnSnapshot` fails a unit test. Update §6 and §17.5 to agree.

**R3-A3 · Voice barge-in requires atomic cancel+submit through a single orchestrator entry point.**
Two separate `await orchestrator.cancel()` + `await orchestrator.submit(...)` calls leave an actor-hop gap where a queued text submit can run. **Fix:** Add `AgentOrchestrator.cancelAndSubmit(userInput:source:) -> SubmitOutcome` — single actor hop. Voice barge-in uses this only. Remove "atomically" from the two-call comment; mark the two-call pattern as incorrect.

**R3-A4 · Replay-log crash-recovery synthesizes a terminator not in the `TurnTerminator` enum.**
§17.4 writes `turn_terminator = "crashed"`; enum has no such case. CHECK constraint or viewer switch fails. **Fix:** Add `TurnTerminator.crashRecovered`. Document the mapping table (terminator → stopReason → replay row shape) once in §12. `monotonic_ns: NULL` on synthesized rows is allowed; spell out the semantics: "row synthesized post-hoc; wall-clock ts is the only ordering."

**R3-A5 · Startup readiness needs a named concurrency primitive, not an unimplementable "hold producer" pattern.**
`AsyncStream.Continuation` is the producer side and can't be "held until consumer subscribes." **Fix:** Pick one primitive and state it: (a) `AsyncChannel` from swift-async-algorithms with explicit `send` that blocks until a consumer awaits, gated behind a readiness `CheckedContinuation` the coordinator resumes when its `for await` is pumping; or (b) `AsyncStream.unbounded` with documented buffering: "events emitted before the coordinator subscribes are buffered and delivered in order on first `for await`." Either works; name it in both §6 and §17.1.

### R3-S · SwiftUI / AppKit architecture

**R3-S1 · Nested helper binaries need an explicit link model (static vs dynamic) before layout is actionable.**
Each helper is a separately-signed Hardened-Runtime binary sharing Swift runtime + `MCP` SPM package. Default SwiftPM dynamic link → `@rpath/...` load failure. **Fix:** Pick one:
- (a) **Static everything** — smaller surface, ~20 MB/helper tax, simple runtime.
- (b) **Shared frameworks** — main app's `Contents/Frameworks/` is the single source, helpers use `LD_RUNPATH_SEARCH_PATHS = @executable_path/../../../../Frameworks`, same-Team-ID required on framework signatures.
Document the choice in §3. (Recommendation: (a) for week-one — simpler, no new failure modes during dev.)

**R3-S2 · Startup barrier chain requires `AppDelegate` as the single owner; SwiftUI `App` lifecycle events can't satisfy §17.**
`App.init` runs before `NSApplication`; `onAppear` on a hidden `Settings` scene under `LSUIElement=YES` never fires; webview inside a SwiftUI representable never instantiates until the HUD is visible — ping/pong barrier deadlocks. **Fix:** Pin the structure:
- `@main struct JarvisApp: App { @NSApplicationDelegateAdaptor var appDelegate: AppDelegate; var body: some Scene { Settings { EmptyView() } } }`.
- All §17.1 steps execute in `applicationDidFinishLaunching`.
- Webview is instantiated inside an `NSPanel` content view **hidden at launch**, not via a SwiftUI representable. WebKit loads without visibility.
- Hotkey registration (step 9) depends on webview-ready (step 7) so barge-in has a live bus on first keypress.

**R3-S3 · Confirmation flow must be non-blocking by design; a blocking modal collides with voice barge-in cancel.**
A nested modal event loop means the MainActor is parked and `HudStateCoordinator.dismissModal()` can't run. **Fix:** Model confirmation as a **sheet attached to a hidden dedicated `NSPanel`** that presents non-blockingly (the Swift-side analog of an `async` modal). `ConfirmationBroker.timeout()` / `.barge()` / `.approve()` / `.deny()` are the four legal transitions; any of them closes the sheet from a Task hop onto MainActor. Document that any future confirmation UI must follow this pattern; ban blocking-modal patterns in `ConfirmationPresenter`.

**R3-S4 · Global hotkey is a two-monitor design, not a single global monitor.**
A global-only monitor misses the app's own frontmost window. A local-only monitor misses every case the user isn't inside the HUD. **Fix:** Specify the hotkey as a **pair of monitors** (global + local) both registered at step 9. Local monitor returns the event or nil (swallow). Document that plain-modifier + alphanumeric is the only supported key shape week-one; the shortcut-recorder UI refuses function/media/Fn keys (which require Accessibility and change the TCC envelope).

**R3-S5 · Main app must not hold `com.apple.security.automation.apple-events` after the helper restructure.**
R2 S2 moved AppleScript into `mcp-applescript.app` to isolate the TCC principal. Keeping the entitlement on the main app defeats the isolation: a webview-XSS in the main process can send Apple Events bypassing `mcp-applescript`'s confirmation broker. **Fix:** Remove `com.apple.security.automation.apple-events` from `Jarvis.entitlements`. Keep it only on `mcp-applescript.entitlements`. Update §3 and the threat-model appendix.

### R3-V · Voice/audio architecture

**R3-V1 · Audio-graph rebuild needs a canonical teardown sequence, not just a debounce.**
A 250 ms debounce around `AVAudioEngineConfigurationChangeNotification` does not prevent corrupted state: converter worker, wake-word DAG, STT session, and TTS producer can all survive engine stop. **Fix:** Add §8 subsection "Graph rebuild sequence" covering all four triggers (device change, AEC fallback, mic re-grant, producer overflow). Canonical order:
1. Publish `.reconfiguring` (HUD holds last visible state).
2. Cancel converter worker; await termination.
3. Cancel wake-word DAG; drop mel + embedding rings.
4. Finalize any open STT session with `FinalizeReason.deviceChange` — name the policy (discard partial vs commit best-effort).
5. Cancel in-flight TTS via §8 V4 interrupt.
6. Stop engine, rebuild with new format, re-pre-warm SpeechAnalyzer, re-pre-warm Orpheus (if tier-2 active), restart.
Document that this sequence applies to every rebuild trigger.

**R3-V2 · AEC-off fallback is a different graph shape with its own invariants; they must be spec'd.**
On `setVoiceProcessingEnabled(true)` failure, post-AEC format becomes hardware-native (48 kHz stereo / 44.1 kHz USB), not 16/24 kHz. Wake-word mel-builder panics; SpeechAnalyzer pre-warm invalidated. **Fix:** Spec AEC-off as an explicit graph variant in §8:
- Resampler is **unconditionally present** (hardware-native ≠ 16 kHz wake target).
- SpeechAnalyzer pre-warm is **re-run** after the fallback graph is live.
- HUD publishes a user-visible warning: "AEC unavailable; degraded-mode active" so users understand occasional "stop while speaking" failures.
Same variant is the shape used by fixture-mode eval (see R3-V9).

**R3-V3 · Orpheus playback format must be probed before the graph is wired, not at first use.**
Player node needs a concrete `AVAudioFormat` at connection time; an unknown format either mismatches silently or forces an on-first-use rebuild (re-triggering AEC toggle). **Fix:** Add a boot-probe to §17.1 startup: on first launch with tier-2 enabled, synthesize one short fixed utterance, inspect the resulting buffer's format, persist to `config.json` under `voice.orpheus.output_format`. Gate step 8 graph wiring on presence of probed format. Tier-2 toggle at runtime forces a graph rebuild with the stored format. Tier-1-only graph uses `AVSpeechSynthesizer`'s output format.

**R3-V4 · TTS cancel is a lifetime-tied choreography, not a single producer cancel.**
Segmenter parked in `channel.send(...)` doesn't wake when the producer is cancelled; back-pressure deadlocks on barge-in when the channel is full. **Fix:** Tie segmenter and producer lifetimes under a single `withTaskGroup` owned by the TTS subsystem; barge-in cancels the group. Alternative: producer's cancel calls `channel.finish()` which wakes pending senders with nil. Document which. The choice is architectural — name it in §8.

### R3-Sec · Security architecture

**R3-Sec1 · R2 Sec3 webview hardening requires the concrete controls to land in IMPL, not just in the decision log.**
Four controls were promised and only one (API-key entry moved out of webview) is traceable in rev 2. **Fix:** IMPL §4/§9 must spell out, as design contracts not implementation code: (a) `WKWebView` preferences posture — file-URL access disabled, universal-access disabled, JS-open-windows disabled; (b) a Content-Security-Policy requirement on the webview HTML that forbids cross-origin script/connect/frame and restricts `default-src 'self'`; (c) API-key entry is a native SwiftUI `SecureField` flow — explicit statement "webview never holds the key on the JS heap"; (d) a project-wide React linter rule banning raw-HTML props on React elements. Exact values are C-tier (implementation checklist); the **requirement and the ban** are A-tier.

**R3-Sec2 · Nonce rotation and non-leakage are contract requirements, not prose.**
Rev-2 says "rotating per-turn" without pinning rotation locus. An implementer could cache per-session. **Fix:** Contract in IMPL §6:
- New `turnNonce` generated at every `submit()` entry.
- `turnNonce` never appears on any `SwiftToJS` bus payload (DevOverlay, `toolCallEnd.resultPreview`, `tokenDelta`). The previews shipped to the webview are built from **unwrapped** content.
- Unit test (listed in §15) asserts the nonce never appears in webview-bound payloads across a fixture turn containing tool-result quoting.

**R3-Sec3 · Config integrity needs a real protection or an honest disclaimer — not theater.**
A Keychain-stored hash is forgeable by any same-user process. **Fix:** Pick one:
- (a) Stronger Keychain ACL gating the hash entry (requires user presence to write), so a rogue process can't silently rewrite. Document this as the integrity control.
- (b) Drop the hash. Document that the real controls are: launch-snapshot whitelist for security keys, `ollama.base_url` host constraint, hard-coded confirmation for `run_applescript`.
Banner text must match reality. Week-one recommendation: (b).

**R3-Sec4 · MCP-child stderr must go through a sanitization pipeline before logging or replay.**
`NSAppleScript.errorInfo` can echo attacker-supplied bytes (clipboard-injected scripts) verbatim into `system.log` / replay. `redact()` only masks API keys. **Fix:** Introduce `Core/Logging/Sanitize.swift` (specified in IMPL §10) as a required stage for every byte stream crossing an MCP boundary: enforce UTF-8 validity, strip C0 controls except `\t`, strip bidi/zero-width code points, cap line length, escape remaining non-printables. Apply at both system-log write and `ReplayLog` ingestion. Pipeline is A-tier; the exact code-point table is C-tier.

**R3-Sec5 · `mcp-clipboard` must refuse pasteboards whose type set contains file URLs, not only whose string is non-empty.**
Finder selections return POSIX paths as `NSPasteboardTypeString`, so Sec13's non-text refusal never trips — file paths leak verbatim to the cloud provider. **Fix:** `mcp-clipboard` policy: if `NSPasteboardTypeFileURL` is present (even alongside string), return a redacted sentinel `"Clipboard contains N file paths; hidden for privacy."` Add a Tier-B eval scenario for the Finder-copy case.

**R3-Sec6 · Skip-allowlist reintroduces the regex-matching pattern R2 Sec2 condemned — remove it for week-one.**
"Narrow skip-allowlist" in prose invites a regex; a regex re-enables the Sec2 bypass (`& (do shell script "…")`). **Fix:** Week-one policy: **no skip-allowlist** — every `run_applescript` invocation requires the confirmation checkbox. Post-week-one, revisit when OSA-level AST (`OSAScript` / `AEGetAttributePtr`) is available to match at statement level. Update PLAN risks row Sec2 and IMPL §7.

---

## Architecture findings — MEDIUM (25)

### Architecture
- **R3-A6** · Collapse `ConfirmRequest.confirmId` and `ConfirmRequest.toolCallId` to a single field (`toolCallId`). Rev-2 intent was one UUID per logical operation; the bus schema shipped two.
- **R3-A7** · Split the "confirmation timed out" lifecycle-matrix row: the timeout event is not a turn termination; the eventual close (after synthetic tool_result + next model call) is. `stopReason` column for the synthetic-event row is blank.
- **R3-A8** · Orphan-turn detection needs a concrete store. Add `meta.crash_count` (table or column on `sessions`) with a deterministic increment in §17.4 step 3. Spell out the SQL for step 1's "last event is not turn_end" query in §12.
- **R3-A9** · `ReplayLog` needs bounded back-pressure. Use `AsyncChannel(capacity: 2048)` between orchestrator events and the ReplayLog writer. Overflow policy: drop `tokenDelta` oldest-first; emit a `replay_overflow { dropped: N, first_ts, last_ts }` marker event; `toolCall*` and `turnEnd` never dropped. Document in §12.
- **R3-A10** · Land `.eval` and `.replay` on `TurnSource` now (deferred from R2 L13 — this is round 3). Thread through DevMetrics and `events.turn_source` column. Eval runner submits with `source: .eval`; replay-runner with `source: .replay`.
- **R3-A11** · Add `case systemReady` to `AgentOrchestrator.Event`. Update §17 and the matrix to cite it.
- **R3-A12** · Add `.booting` to `HudState` as the pre-systemReady prefix state. Precedence becomes `awaitingConfirmation > speaking > listening > thinking > idle > booting`. Document the coordinator starting state.
- **R3-A13** · Per-server restart mutex in `MCPClient` — an inner actor or in-flight `Task` slot that subsequent concurrent `callTool` invocations await. Document in §7 crash handling.

### Swift/macOS
- **R3-S10** · Specify the HUD panel focus model: `JarvisPanel` overrides `canBecomeKey=true`, `canBecomeMain=false`; style mask includes `.nonactivatingPanel` and `.borderless`; panel level `.statusBar`; panel does not hide on deactivate. Webview receives input after `panel.makeKey()`. This is an architectural contract (focus ownership), not an API call.
- **R3-S14** · Shortcut-recorder UX requires a temporary `NSApp.setActivationPolicy(.regular)` flip for the duration of the recorder panel; restore `.accessory` on dismiss. Spec in §17.1 step 9.
- **R3-S15** · Close the file-layout naming drift: `scripts/codesign.sh` (single script, optional `--notarize`); add `scripts/check-plist-parity.sh`, `scripts/verify-models.sh`, `scripts/verify-fixtures.sh`, `scripts/check-bus-protocol-version.sh`, `scripts/prime-tcc.sh`. Documents referenced by other sections must appear in §1.

### Voice
- **R3-V5** · Pre-warm re-runs after every graph rebuild (initial boot, mic-permission-grant — first or weekly reprompt — device change, AEC fallback, Orpheus tier toggle). Add to §8 pre-warm list.
- **R3-V6** · Wake-word-during-confirmation is a first-class transition. During `awaitingConfirmation`, wake-word routes to `ConfirmationBroker.bargeCancel()` (synthetic deny + close modal + accept new submit). Document in §8 and §7.
- **R3-V7** · VAD contract: VAD **always** consumes the 16 kHz Float32 ring. On Sonoma where post-AEC is already 16 kHz, the "resampled ring" is an identity pass-through alias (not skipped). State this in §8 so wake-word and VAD share one resample path.
- **R3-V8** · Raw/resampled ring overflow policy is part of the RT-thread contract. Producer overflow increments an atomic `rawRingDrops` counter; consumer treats non-zero as a discontinuity edge per §8 V3 (`converter.reset()`, publish discontinuity event). Surface `rawRingDrops` in DevOverlay. Exact sizes are C-tier.
- **R3-V9** · Fixture-mode eval uses the AEC-off graph variant (R3-V2). Document explicitly: fixture mode does **not** cover the AEC branch; add a manual live-mic smoke checklist in §15.
- **R3-V10** · Orpheus warm-up is a startup contract analogous to SpeechAnalyzer's. Spec in §8: on app launch with tier-2 enabled, synthesize one short fixed phrase (output discarded) on a background task. Same warm-up at runtime tier-2 flip, **before** HUD reports the flag as "active."

### LLM
- **R3-L1** · Clarify `input_json_delta` semantics in §5: the accumulator collects the UTF-8 bytes of the decoded string value of `partial_json`, not raw SSE frame bytes. Add a parser fixture where `partial_json` contains escaped quotes / newlines.
- **R3-L2** · Add a "Tool-choice policy" subsection to §5. Default behavior uses the provider default. On tool-cap recovery (one-more-call-then-force-end), the request sets `tool_choice` to a no-tool mode on Anthropic and drops the tools array entirely on Ollama (which has no equivalent).
- **R3-L3** · Retry-bracketing contract in §6: on `stream_truncated` mid-turn, emit `.assistantMessageEnd` for the truncated message, flush the TTS sentence channel, publish `.retryStarted(of: turnId)` (or a fresh `.assistantMessageStart`), then call the provider. Webview renders retry as replacement/continuation.

### Security
- **R3-Sec7** · SHA-256 digest shown in confirmation UI must be over the **compiled** script bytes, not source bytes. Smart-quote normalization / identifier recomposition during compile means source-digest doesn't match runtime. Compilation failure → refuse without a digest.
- **R3-Sec10** · Heuristic keyword check for AppleScript injection is best-effort by design, not a security boundary. Week-one: drop the banner heuristic — checkbox wording is unambiguous regardless of provenance. Post-week-one: implement second-model check (R2 Sec11) non-optional, routing proposed script + originating tool result through a local Ollama call; unsure/no → higher-tier confirmation.
- **R3-Sec11** · Replay-feed paths must re-wrap content with the **current** turn's nonce before re-entering a model context. Add single-entry helper `replayToModel(row) -> LLMMessage` in §12; eval runner, memory extractor, and replay runner call this. Print-only viewers see raw content.

### Build/Eval
- **R3-B1** · Each `mcp-*` is an Xcode **Application** target (`LSUIElement=YES`, no storyboard/window), not a command-line tool. Reconcile §1 wording with §3 bundle layout.
- **R3-B4** · Info.plist parity check is an **Xcode build phase** on the main app (not only a deferred CI lint), and the allowlist of permitted Debug/Release deltas is a checked-in file with one key per line and a reason comment. This surfaces drift locally.
- **R3-B5** · `MCPIntegrationTests` is an Xcode test target in the main project, not an SPM test. Scheme pre-action sets `MCP_BINARIES_DIR` to the main app's `Contents/Helpers/`. Test target has explicit dependencies on helper app targets.
- **R3-B8** · Tier-B TCC priming protocol: `scripts/prime-tcc.sh` enumerates every `tell application` target touched by Tier-B scenarios (`Music`, `System Events`, others per scenario), launches the app once, triggers each prompt, exits. Required manually on any new dev machine before `--tier B` passes. Enumerate the target list in §13 per Tier-B scenario.
- **R3-B12** · `replay-roundtrip` oracle is defined: uses a `MockLLMProvider` that replays the recorded `LLMEvent` sequence. Assertions: (1) every `user_input → turn_end` subsequence matches byte-for-byte modulo new UUIDs and wall-clock ts; (2) emitted `toolCallStart/End` sequence matches; (3) no new `error` events. Tests the replay machinery, not the live model.

---

## Implementation checklist (C-tier — non-blocking)

Track these during the implementation loop. Each is real but concerns exact API form, shell-script edge cases, linter configs, naming, or Xcode settings — not architectural correctness.

**Swift/macOS API correctness**
- S6 · `Codable.encode(to:)` must flatten all keys into the parent's `CodingKeys`; no nested-payload-encode-to-same-encoder.
- S7 · `setVoiceProcessingEnabled(true)` must be called before any read of `inputNode.outputFormat`, `.inputFormat`, or any `engine.connect(inputNode, ...)` — `inputNode` is lazily materialized.
- S8 · Keychain "is key present" probe uses status-only check (no data materialization).
- S9 · Helper binary lookup uses `Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/...")` explicitly; `subdirectory:` arg searches Resources only.
- S11 · `NSStatusItem` stored as `var statusItem: NSStatusItem!` on `AppDelegate`; not a local.
- S12 · All `callAsyncJavaScript` callsites are `@MainActor`-isolated; enforce via a typed `WebviewSink`.
- S13 · Config hot-reload uses `FSEventStreamCreate` with `kFSEventStreamCreateFlagFileEvents` (path-based), not `DispatchSourceFileSystemObject` (vnode-based).
- S16 · Pick `NSApp` vs `NSApplication.shared` consistently.
- S17 · Helper Info.plist key set: `CFBundleIdentifier`, `CFBundleExecutable`, `CFBundlePackageType=APPL`, `CFBundleVersion`, `CFBundleShortVersionString`, `LSUIElement=YES`, `LSMinimumSystemVersion`.
- S18 · Panel level `.statusBar` to stay above other apps' floating panels.

**Voice polish**
- V11 · Gate `audioLevel` RMS timer on `AVAudioPlayerNode.isPlaying`; suspend while silent; hold last sample.
- V12 · WhisperKit weight download runs on a background `Task`; flag-reload handler returns immediately.
- V13 · Re-word wake-word end-to-end latency to include AEC + ring/scheduling (140–250 ms). Bump eval budget to 300 ms or document flakiness at 250 ms boundary.

**LLM polish**
- L4 · Decoder emits `.usage` before `.stopReason` on the same `message_delta` frame; fixture asserts ordering.
- L5 · Cache-control analysis: real order `[tools → system → messages]`; editing tools invalidates both; editing system invalidates system only. Swap the rev-2 bullet analysis.
- L6 · `NDJSONLineReader` buffers across `URLSession.AsyncBytes` chunk boundaries; fixture splits mid-object.
- L7 · `ContentBlock.toolResult.id` renamed `toolUseId`; doc-comment ties it to the provider id.

**Security polish**
- Sec8 · Document TCC envelope per hotkey path (`NSEvent.addGlobalMonitorForEvents` vs Accessibility vs Input Monitoring) in §17.1 step 9 and PLAN Sec7.
- Sec9 · Open long-lived parent FDs (SQLite WAL, log files) with `O_CLOEXEC` (or `fcntl(F_SETFD, FD_CLOEXEC)` right after open) to prevent MCP-child inheritance. Eval assertion validates.
- Sec12 · `redact()` patterns extended to `Authorization: Bearer \S+`, `AKIA[0-9A-Z]{16}`, `ghp_...`, `github_pat_...`.
- Sec13 · `ToolCallStart.args` for confirmation-gated tools is masked until approval (`{tool: "...", preview: "<awaiting approval>"}`).

**Build/sign/eval plumbing**
- B2 · Xcode Embed phase uses copy-only (no Code Sign On Copy) for helpers; helpers signed deepest-first with `--options=runtime --timestamp` in their own target; verifier asserts flags+entitlements+TeamID per helper.
- B3 · Commit `webview/inputs.xcfilelist`; `ENABLE_USER_SCRIPT_SANDBOXING=NO` on the webview Run Script phase.
- B6 · Model integrity is a separate Run Script phase before Copy Files, with explicit inputs/stamp outputs.
- B7 · Debug relaxes Hardened Runtime on helpers to avoid first-launch stalls on fresh profiles; Release keeps strict path.
- B9 · `build-webview.sh` skips install via content-hash sentinel (`shasum -a 256 pnpm-lock.yaml` vs stored hash), not `-nt`.
- B10 · Vite-down mid-session handled via a JS→Swift heartbeat in Debug; "Reload Webview" CTA.
- B11 · `streaming-latency-cold` uses `URLSession(configuration: .ephemeral)`; budget is best-effort warning-only.
- B13 · `config/{Shared,Debug,Release}.xcconfig` in §1 layout.
- B14 · Script names match §1 layout (see A-tier R3-S15).
- B15 · Eval runner exit codes: 0/1/2/3 = pass/fail/infra/args.
- B16 · Pin exact pnpm in `.tool-versions`; `build-webview.sh` asserts match.
- B17 · Voice fixtures hashed in a manifest; `scripts/verify-fixtures.sh` runs in pre-test phase.
- B18 · `scripts/check-bus-protocol-version.sh` enforces BUS_PROTOCOL_VERSION parity as an Xcode pre-build phase.

**Doc hygiene (A-LOWs collapsed)**
- A14 · Run MCP initialize concurrently, 3 s aggregate budget.
- A15 · Document `.assistantMessageStart` emission contract per provider in §5.
- A16 · Strike-through superseded R1 decision-log rows.

---

## Items verified (non-findings, prevent re-litigation)

From R3-L: `message_stop` canonical terminator; `ping` swallowing; `thinking_delta`/`redacted_thinking` handling; `done_reason` mapping; OpenAI-compat atomic `tool_calls`; retry cancellation via `Task.checkCancellation()` inside sleep; `tools/list_changed` deferred for week-one; stream-truncation cleanup iteration; ProviderError taxonomy (529/429 split, `context_length` recoverable, `stream_truncated` distinct).

---

## Convergence signal

Architecture-tier findings are concentrated at **three frontiers**:

1. **Concurrency contracts** (A1/A3/A5/A9/A13, V4) — the turn-loop, voice barge-in, MCP crash handling, startup readiness, and TTS back-pressure all need named primitives and explicit lifetime bindings. This is the densest cluster.
2. **Lifecycle/rebuild sequencing** (V1/V2/V3/V5/V10, S2/S3) — startup, confirmation flow, and audio-graph rebuild all need canonical order-of-operations documents rather than implied behavior.
3. **Schema completion** (A4/A6/A10/A11/A12) — small, mechanical enum and field additions that close contract drift.

If rev-3 resolves all 23 A-tier HIGH + 25 A-tier MEDIUM, I expect round-4 to return ≤3 A-tier MEDIUM and 0 A-tier HIGH. The C-tier checklist carries into the implementation loop, checked off as each feature lands.
