# Jarvis API Migration Plan — v1.0

**Status:** LOCKED — consumes `JARVIS-API-DESIGN-v0.1.md` + `JARVIS-API-DESIGN-v0.2.md` (UQ-1..UQ-5 answered) + `REVIEW-MIGRATION-RISK.md`
**Date:** 2026-05-07
**Author:** Migration planner (swarm phase 6)
**Baseline:** `develop` @ `b36e8eb` (post-pivot handoff)
**Target state:** v1.0 API live; B-02..B-08 closed; M-7 merged; webview talks v1.0 surfaces only.

This document is the canonical execution sequence from HEAD to v1.0 live. It promotes `REVIEW-MIGRATION-RISK §"Recommended cutover sequence"` (M-0..M-7) and the per-subsystem cards to canonical, then specifies the commits, gates, rollbacks, effort estimates, and dependencies the review left implicit.

---

## 1. Migration overview

| Step | Goal (one line) | Duration (engineer-days) | Bug(s) closed |
|---|---|---|---|
| **B-02 patch** | Tactical history-threading fix on `develop` (outside M-sequence) | 0.5 | B-02 |
| **M-0** | Pre-migration gates: `JarvisAPI` package, harness scaffolding, behavioral boundary gates, dual-version handshake | 2.5–3.5 | (none — substrate) |
| **M-1** | Self surface live; `getSelfState`/`tccStatusChanged`/device enumeration through API; B-08 dissolved | 1.0–1.5 | B-08 |
| **M-2** | Settings surface live; sole writer for all configuration mutation; F-001 amendment lands | 1.5–2.0 | (none — substrate) |
| **M-3** | Diagnostics surface live; HUD state moves to Diagnostics (F-003); banner queue + DevSnapshot + replayLog stream | 1.0–1.5 | (none — substrate) |
| **M-4** | Memory surface live; `factMutated`/`factsRetrieved`/`searchFacts` through API; cache-eligibility regression gate | 2.0–3.0 | (B-02 already closed by patch; M-4 reframes) |
| **M-5** | Vision surface live; `requestFrameAttach` returns typed Result through real WKWebView round-trip | 1.5–2.0 | B-03 |
| **M-6** | Voice surface live; substrate audio-graph fix + `synthesizeTurn` command | 4.0–5.5 | B-04, B-05 |
| **M-7** | Turn surface live (keystone); `OutboundBatcher` partitioned by `turnId`; webview retires `sessionHistory` push | 5.0–7.0 | B-06 |

**Aggregate range:** 19–26 engineer-days, ~4–5.5 calendar weeks at solo pace (matches `REVIEW-MIGRATION-RISK §Q-M-8` 15–25 estimate, slightly inflated for harness parametric runner per UQ-5).

The order is a strict topo-sort of substrate dependency: a surface migrates only after every surface its events ride on has migrated. M-0 must complete before M-1; M-7 must be last. **B-02 patch lands on `develop` directly before M-1 starts.**

---

## 2. Per-step migration cards

### 2.1 M-0 — Pre-migration gates

**Goal:** Land the substrate the rest of the migration assumes (API package, harness, behavioral gates) before any surface migrates.

**Branch / merge strategy:** **Direct on `develop`.** M-0 has no production behavior change; it is purely additive substrate (a new package, a new harness target, behavioral gate replacements). Splitting this across a feature branch would gate M-1 on PR review of substrate that everyone agrees on — friction for no benefit.

**Prerequisites:**
- HEAD is `b36e8eb` or later, tree clean.
- B-02 tactical patch (§3) lands FIRST (before M-0 starts), so M-0 can assume B-02 is closed.
- D-5/D-6/D-7 status is *known* but not required to close yet (they gate M-4, not M-0).

**Concrete commit-by-commit task list:**

| # | Commit | Files / scope |
|---|---|---|
| M-0.1 | `feat(api): scaffold JarvisAPI package — types only, no conformers` | `packages/JarvisAPI/Package.swift`, `Sources/JarvisAPI/{Surfaces, Commands, Events, Queries, Errors}.swift`, `JarvisHost.swift` (typed `boot() async -> Result<JarvisHost, BootError>` per OQ-T6). NO call sites in `App/`. NO conformers. Compiles green; existing app does not import it. |
| M-0.2 | `feat(api): APIClock protocol + RealClock + ManualClock` | `packages/JarvisAPI/Sources/JarvisAPI/Clock.swift`. Resolves G-002. Not yet wired into surfaces. |
| M-0.3 | `feat(api): TransportMode + parametric harness driver scaffolding` | `packages/Harness/Sources/Harness/TransportMode.swift` (`.inProcessActor` / `.jsonRoundTripWebView`), parametric scenario runner stub. Reuses existing `RealWKWebViewIntegrationTests` infrastructure as the JSON substrate. Resolves UQ-5 substrate. |
| M-0.4 | `feat(api): JARVIS_HARNESS=1 runtime gate + ProviderOverrides` | `JarvisHost.init(transportConfig:, providerOverrides: ProviderOverrides?)`. Internal-surface commands (`Voice._injectAudioFrame`, `Self._forceTCCStatus`, `_forceError`) gate behind `if ProcessInfo.processInfo.environment["JARVIS_HARNESS"] == "1"`. Resolves UQ-1, G-001/G-003/G-004. |
| M-0.5 | `feat(bus): WebviewBridge accepts ["2.3.0", "2.4.0-rc"] dual-channel handshake` | `packages/Bus/Sources/Bus/WebviewBridge.swift:147-288`, `packages/Bus/Sources/Bus/Protocol.swift:28`. Mitigates R-005. Rollback knob: revert this commit and `WebviewBridge` is back to strict `2.3.0`. |
| M-0.6 | `feat(gates): convert check-single-writer-hudstate to behavioral` | `scripts/check-single-writer-hudstate.sh` becomes a thin wrapper around a harness probe (`HudStateSingleWriterProbe` builds a debug binary that emits HUD state from two paths; harness asserts exactly one event reaches the bus). Mitigates R-004. Grep gate kept in addition. |
| M-0.7 | `feat(gates): convert check-install-order to behavioral` | `scripts/check-install-order.sh` boots harness, asserts log-line ordering with timing assertions. Mitigates R-001. Grep gate kept. |
| M-0.8 | `feat(bus): BusForwarder.drain takes sink fanout` | `packages/AgentCore/Sources/AgentOrchestrator/BusForwarder.swift`. Drainer count = 1; sink count ≥ 1 (`AppBusForwarderSink`, `HarnessSink`, `ReplaySink`). `scripts/check-orchestrator-events-single-consumer.sh` updated to assert "exactly one fanout drainer". Mitigates R-009. |
| M-0.9 | `feat(harness): clipboard, keychain, store fakes hoisted from VoiceTests` | Move `MockTTSForController`, `CapturingSTTProvider`, `MockVADEngine`, `FakeKeychain`, `FakeStore` from `@testable` test targets into `Sources/Harness/` so harness composes without `@testable import Voice`. (Per CLAUDE.md naming: Mock = records, Stub = canned, Fake = stateful — preserved.) |

**Gates (must all pass before declaring M-0 complete):**
- All existing boundary scripts in `scripts/check-*.sh` green (no regressions from substrate changes).
- `swift test --package-path packages/JarvisAPI` green (types compile).
- `swift test --package-path packages/Harness` green (parametric runner scaffolding compiles).
- `bash scripts/check-app-builds.sh` green.
- `bash scripts/check-bus-protocol-version.sh` adapted for dual-version, green.
- Behavioral install-order test passes.
- Behavioral single-writer-HUD test passes.
- New: `scripts/check-fanout-drainer.sh` (M-0.8) green.

**Risk findings activated:**
- **R-001** (install-order grep-only) → mitigated by M-0.7 behavioral test.
- **R-004** (single-writer grep-only) → mitigated by M-0.6.
- **R-005** (handshake strict equality blocks dual-channel) → mitigated by M-0.5.
- **R-009** (single-consumer gate vs multi-surface fanout) → mitigated by M-0.8.

**Rollback plan:** every M-0 commit is independently revertible (`git revert <sha>`). M-0.5 is the only one with production behavior implication (handshake is now lenient); reverting it restores strict `2.3.0`. No DB/schema/codesign changes in M-0, so rollback is `git revert` of all 9 commits in reverse order.

**Estimated effort:** 2.5–3.5 engineer-days. Bulk is M-0.6 + M-0.7 (rewriting two grep gates as behavioral harness probes) and M-0.4 (`ProviderOverrides` plumbing).

**Carry-forward bugs closed:** none (substrate only; B-02 already closed by tactical patch).

---

### 2.2 M-1 — Self surface

**Goal:** Land the lowest-blast-radius surface as a proof of API approach; close B-08.

**Branch / merge strategy:** Feature branch `migration/m1-self`, single PR to `develop`. Harness gates pre-merge.

**Prerequisites:**
- M-0 complete and merged.
- B-02 patch already on `develop`.

**Concrete commit-by-commit task list:**

| # | Commit | Scope |
|---|---|---|
| M-1.1 | `feat(api): Self surface conformer wraps SelfStateAdapter` | `packages/JarvisAPI/Sources/JarvisAPI/Surfaces/Self+Adapter.swift`. `getSelfState`, `listAudioDevices`, `listCameraDevices`, `getActiveAudioRoute` queries. Reuses existing in-process tools (`installSelfKnowledgeTools`, `App/AppDelegate.swift:686-689`). |
| M-1.2 | `feat(api): selfStateChanged + tccStatusChanged events plumbed` | Bridge from `SelfStateAdapter` + `AppDelegate` permission probes to `JarvisHost.events`. `tccStatusChanged` semantics documented as "fires on probe (boot, applicationDidBecomeActive, _forceTCCStatus), not on user toggle" (R-010). |
| M-1.3 | `feat(api): canonical modelId/modelDisplayName closes B-08` | `getSelfState.modelDisplayName` is the only string referenced in tool result text. Anti-paraphrase contract: harness asserts assistant text does not contain "Opus 4.5" across N≥10 trials when `getSelfState.modelId == "claude-opus-4-7"`. |
| M-1.4 | `feat(api): _forceTCCStatus harness command (UQ-1 gated)` | `Self._forceTCCStatus(permission: TCCPermission, granted: Bool)` re-emits `tccStatusChanged`; downstream subsystems re-probe. Resolves G-003. |
| M-1.5 | `test(harness): Self scenarios — getSelfState, B-08 dissolution, TCC force, audio route nil-during-install` | Phase-5 scenario IDs (placeholders, ratify with phase-5 output): `S-SELF-001` getSelfState happy, `S-SELF-002` B-08 dissolution N=10, `S-SELF-003` TCC denied → revoked-event chain, `S-SELF-004` getActiveAudioRoute returns nil pre-voice-install (R-016 gate). All scenarios run in **both** `.inProcessActor` AND `.jsonRoundTripWebView` modes (UQ-5). |

**Gates:**
- `swift test --package-path packages/JarvisAPI --filter SelfSurfaceTests` green.
- All M-1 harness scenarios green in both transport modes (UQ-5 mandate).
- `bash scripts/check-install-order.sh` (behavioral) green — Self surface conformer must not perturb install DAG.
- `bash scripts/verify-entitlements.sh --pre-codesign` green (R-012).
- B-08 dissolution scenario across N=10 trials: zero failures.
- `getSelfState.memoryVectorAvailable: Bool` reflects current dylib load state (foreshadows R-011 / M-4).

**Risk findings activated:**
- **R-010** (TCC push semantics) → documented and behavioral via `_forceTCCStatus`.
- **R-012** (entitlement drift) → `verify-entitlements.sh --pre-codesign` runs in PR CI.
- **R-016** (selfKnowledge install-after-voice ordering) → harness scenario S-SELF-004.

**Rollback plan:**
```
git checkout develop && git revert -m 1 <merge-sha-of-m1>
```
The Self surface is purely additive; reverting drops the surface adapter and the in-process self-knowledge tools (already on the agent path) continue to work as today. **No persistence change, no codesign change, no entitlement change.** Loose-ends rollback: drop the `_forceTCCStatus` env-gate at boot (the env var becomes no-op).

**Estimated effort:** 1.0–1.5 engineer-days. Self has zero commands and uses existing in-process tools; bulk effort is harness scenarios in both transport modes.

**Carry-forward bugs closed:** **B-08** ([handoff §"What is BROKEN at HEAD"](HANDOFF-2026-05-07.md)).

---

### 2.3 M-2 — Settings surface

**Goal:** Land Settings as the single canonical writer for configuration mutation (F-001 / UQ-4); foundation for all subsequent commands that flip config.

**Branch / merge strategy:** Feature branch `migration/m2-settings`, single PR.

**Prerequisites:** M-1 merged.

**Concrete commit-by-commit task list:**

| # | Commit | Scope |
|---|---|---|
| M-2.1 | `feat(api): Settings surface conformer over ConfigStore` | `getSettings`, `settingsChanged`. Wraps `ConfigStore.perTurn()` + `LaunchSnapshot`. |
| M-2.2 | `feat(api): Settings owns setProvider/setTTSTier/setSTTBackend/setFeatureFlag/setHotkey/storeAPIKey` | All emit `settingsChanged` with the changed key paths. `setHotkey` collision detector wired (G-005 — `harness-injectable` for `bindFailed`). |
| M-2.3 | `feat(api): Settings.setWakeWordMuted + setVoiceRunning + setLaunchAtLogin (UQ-4)` | Replaces Voice's `muteWakeWord`/`unmuteWakeWord`/`startVoice`/`shutdownVoice`. Voice surface to be slimmed in M-6 (it doesn't yet exist; Voice still runs through legacy `BusInbound`). |
| M-2.4 | `test(harness): Settings scenarios — round-trip per-field, hotkey collision, API-key validate (mock provider via UQ-1)` | Scenario IDs `S-SET-001..S-SET-008`. Both transport modes. |

**Gates:**
- All Settings scenarios green in both transport modes.
- `bash scripts/check-bus-harness-parity.sh` green.
- `getSettings.confirmationTimeoutSeconds` round-trip matches `ConfigStore.perTurn().confirmationPolicy.timeoutSeconds` (foreshadows R-008 / M-7).
- `bash scripts/check-app-builds.sh` green.
- Settings window (legacy AppKit) still works during dual-writer window (Settings window may write to `ConfigStore` directly OR through the new surface — both converge on same source-of-truth per `REVIEW-MIGRATION-RISK §M-2`).

**Risk findings activated:**
- **R-008** (broker timeout vs config) → not yet activated; `ConfirmationPolicy.timeoutSeconds` exposed but ConfirmationBroker still hardcodes 60s. M-7 closes the loop. Documented in M-2 PR description.
- **F-001 / UQ-4** → Settings is canonical writer; Voice surface will lose configuration setters in M-6.

**Rollback plan:**
```
git checkout develop && git revert -m 1 <m2-merge-sha>
```
Settings surface is additive over `ConfigStore`; revert removes the surface. Settings window keeps working (it always wrote to `ConfigStore` direct). No persistence change.

**Estimated effort:** 1.5–2.0 engineer-days. Wider command surface than M-1; harness scenarios for ~8 setters.

**Carry-forward bugs closed:** none. Substrate for downstream surfaces.

---

### 2.4 M-3 — Diagnostics surface

**Goal:** Land Diagnostics; HUD state (F-003 amendment) moves here as `Diagnostics.hudStateChanged`; banner queue + DevSnapshot + replay-log stream.

**Branch / merge strategy:** Feature branch `migration/m3-diagnostics`, single PR.

**Prerequisites:** M-2 merged.

**Concrete commit-by-commit task list:**

| # | Commit | Scope |
|---|---|---|
| M-3.1 | `feat(api): Diagnostics surface — getDevSnapshot, devSnapshotUpdated, toggleDevOverlay` | Wraps `DevOverlay` package. |
| M-3.2 | `feat(api): Diagnostics.hudStateChanged + getHudState (F-003)` | HUD state moves OFF the Turn surface (F-003 amendment, locked v0.2). `HudStateCoordinator` is single writer, `BusForwarder` no longer emits `hudState`. Behavioral single-writer gate (M-0.6) is the safety net. |
| M-3.3 | `feat(api): Diagnostics.systemBannerEnqueued + systemBannerDismissed + dismissBanner` | Wraps `HUDBannerCoordinator`. Resolves F-016. `copyStateDump` split into command (writes clipboard) + emitted banner event (per migration-card "highest-risk step"). |
| M-3.4 | `feat(api): Diagnostics.streamReplayEvents + snapshotReplayEvents (G-008/OQ-T5)` | Replay event emission is a side effect of API event emission (one call → one replay row + one bus event), preserving R-017. |
| M-3.5 | `feat(api): Diagnostics.hardBlockTriggered event + 1s pre-termination delay (G-012)` | Replaces direct `NSAlert.runModal`. Banner observable, then process exits. |
| M-3.6 | `test(harness): Diagnostics scenarios` | `S-DIAG-001..S-DIAG-009`. Both transport modes. |

**Gates:**
- `bash scripts/check-single-writer-hudstate.sh` (behavioral) green AFTER HUD migration. **Critical:** old `BusOutbound.hudState` emit MUST be deleted; harness asserts exactly ONE writer reaches the bus client.
- `bash scripts/check-no-modal-presentation.sh` green (G-012 enforcement).
- All Diagnostics scenarios green in both transport modes.
- Banner enqueue produces exactly one event (boundary check that AppKit banner panel didn't independently emit — per `REVIEW-MIGRATION-RISK §M-3`).
- Replay roundtrip: harness asserts that `Memory.applyOp(.add, …)` produces ONE replay row AND one bus event (R-017).

**Risk findings activated:**
- **R-004** (HUD single-writer gate) → activated; behavioral gate from M-0.6 is the enforcement.
- **R-017** (replay log integrity) → enforced by emit-as-side-effect contract.
- **F-003** (HUD on wrong surface) → amendment lands.

**Rollback plan:**
```
git checkout develop && git revert -m 1 <m3-merge-sha>
```
Diagnostics is layered over DevOverlay + HUDBannerCoordinator; revert restores direct AppDelegate calls. **HUD state revert needs care:** if M-3.2 is reverted alone, `HudStateCoordinator` may have two writers again — full M-3 revert is the safer path. Tag a known-good M-2-tip commit before merging M-3 so revert target is unambiguous.

**Estimated effort:** 1.0–1.5 engineer-days. Diagnostics is read-mostly; bulk is HUD migration safety + replay-event side-effect plumbing.

**Carry-forward bugs closed:** none. Substrate for HUD state observability.

---

### 2.5 M-4 — Memory surface

**Goal:** Land Memory; `factMutated` / `factsRetrieved` / `searchFacts` / `forgetFact` / `listRecentFacts` / `listTurns` through API; cache-eligibility regression gate (R-006) for the B-02 patch.

**Branch / merge strategy:** Feature branch `migration/m4-memory`, single PR.

**Prerequisites:**
- M-3 merged.
- **D-5/D-6/D-7 status decided at M-4 PR open time** (see §7).
- B-02 patch on `develop` (already done before M-0). M-4 reframes the orchestrator's history-load path against the new surface but does NOT re-introduce the bug.

**Concrete commit-by-commit task list:**

| # | Commit | Scope |
|---|---|---|
| M-4.1 | `feat(api): Memory surface — listRecentFacts, searchFacts, listTurns queries` | Wraps `MemoryStore`. `searchFacts` returns typed result with `vectorAvailable` flag (R-011). `listTurns` lives only on Turn surface per F-008 amendment — note: actually exposed on Turn (M-7), removed from Memory's public spec; substrate-side helper kept here. |
| M-4.2 | `feat(api): Memory.forgetFact (no requiresConfirmation param — F-009)` | Confirmation routed via `ConfirmationBroker` test seam under UQ-1 gate. |
| M-4.3 | `feat(api): factMutated + factsRetrieved events; replace replay-event emit (single-emit gate)` | Replaces `MemoryStore.applyOp` replay event; preserves R-017. **CRITICAL:** delete the old emit site; do not parallel-emit (see Failure Mode 1, §5.1). |
| M-4.4 | `feat(api): Memory.searchFacts returns typed degraded result if vec0 unloadable (R-011)` | `Result<MemoryHits, MemoryError>` where `MemoryError.vectorIndexUnavailable` is a triggerable variant under harness gate. `getSelfState.memoryVectorAvailable: Bool` exposes the boot-time flag (M-1.1 wired the field). |
| M-4.5 | `refactor(agent): orchestrator history-load uses Memory surface helper` | Reframes the B-02 patch path against the new surface. **CACHE-ELIGIBILITY REGRESSION GATE** (R-006): existing harness scenario "two short turns then a third turn" produces NO `streamTruncated` retries. This MUST pass before merge. |
| M-4.6 | `test(harness): Memory scenarios` | `S-MEM-001..S-MEM-008` including the cache-eligibility regression. Vector-search scenarios gated `JARVIS_REAL_MODELS=1` (skipped in default runs); FTS-only path testable with `StubEmbedder`. Both transport modes for non-vector scenarios. |

**Gates:**
- `bash scripts/check-single-memory-mutated-emit.sh` green AFTER migration (substrate of the literal emit moved; grep target updated to match new site name).
- `bash scripts/check-single-memory-used-emit.sh` green.
- `bash scripts/check-embedding-dim-literal.sh` green.
- **R-006 regression gate:** scenario `S-MEM-CACHE-REGRESSION` (two short turns then a third) produces zero `streamTruncated` retries. **Failing this scenario blocks merge.**
- `bash scripts/check-corpus-secrets.sh` green.
- All Memory scenarios green (or skipped with `JARVIS_REAL_MODELS=1` annotation for vector path if D-5/D-6/D-7 not yet closed).
- `getSelfState.memoryVectorAvailable` reflects current state; harness asserts at boot.

**Risk findings activated:**
- **R-006** (cache-eligibility flip) → mandatory regression gate.
- **R-011** (sqlite-vec dylib + load order) → `memoryVectorAvailable` flag + typed degraded result.
- **R-017** (replay log integrity) → replace-not-add emit; gate enforces.
- **F-008** (`listTurns` on both Turn and Memory) → removed from Memory's public spec.
- **F-009** (`requiresConfirmation` transport leak) → removed.

**Rollback plan:**
```
git checkout develop && git revert -m 1 <m4-merge-sha>
```
Memory surface is layered over `MemoryStore`. Revert drops the surface; B-02 patch on `develop` continues to work (orchestrator's history-load helper falls back to direct `MemoryStore.recentTurnsForSession` call — preserved by M-4.5 keeping the underlying call). **No SQLite schema migration in M-4** (per `REVIEW-MIGRATION-RISK Failure mode 5`).

**Estimated effort:** 2.0–3.0 engineer-days. Cache-eligibility regression test is the long pole; vector-search path adds ~0.5 day if D-5/D-6/D-7 closed.

**Carry-forward bugs closed:** B-02 was closed by tactical patch (§3); M-4 reframes against the API and pins behavior with the regression gate.

---

### 2.6 M-5 — Vision surface

**Goal:** Land Vision; `requestFrameAttach` returns typed Result through real WKWebView round-trip; close B-03.

**Branch / merge strategy:** Feature branch `migration/m5-vision`. **Atomic webview + Swift commit** (see §4).

**Prerequisites:** M-4 merged.

**Concrete commit-by-commit task list:**

| # | Commit | Scope |
|---|---|---|
| M-5.1 | `feat(api): Vision surface — requestFrameAttach returns Result<FrameAttachArmed, FrameAttachError>` | Implementation MUST `guard let controller = frameAttachController else { return .failure(.cameraPermissionDenied) }` (R-003). FrameCaptureID = UUID per locked decision. |
| M-5.2 | `feat(api): framePending(captureId:), frameSent(turnId:captureId:), frameExpired(captureId:) events` | F-007 / F-010 amendment. Captures correlate via FrameCaptureID. ManualClock advances cause `frameExpired` after 5 s deterministic. |
| M-5.3 | `feat(api): cancelFrameAttach + getFrameAttachState query` | `getFrameAttachState` returns current arming state for late-connect clients. |
| M-5.4 | `feat(webview): typed call to Vision.requestFrameAttach (atomic with Swift)` | **SAME COMMIT or commit pair within feature branch (see §4).** Webview HUD camera button switches from `frameAttachRequested` inbound emit to typed `requestFrameAttach` call expecting `Result`. The old `frameAttachRequested` inbound case stays as deprecated alias for one release. `bash scripts/build-webview.sh` rebuilds `dist/`. |
| M-5.5 | `test(harness): Vision scenarios` | `S-VIS-001..S-VIS-006` including `requestFrameAttach` returning `FrameAttachArmed` within 100 ms (per `REVIEW-MIGRATION-RISK §M-5` gate); nil-controller → `cameraPermissionDenied` (R-003); 5 s `frameExpired` deterministic via `ManualClock` (G-002). **Both transport modes mandatory** (UQ-5) — `.jsonRoundTripWebView` is the mode that catches B-03-class regressions. |

**Gates:**
- `bash scripts/check-vision-isolation.sh` green.
- `bash scripts/check-presence-vision-isolation.sh` green.
- All Vision scenarios green in both transport modes. **`.jsonRoundTripWebView` mode is non-skippable for `S-VIS-001`** — this is the gate that proves B-03 dissolved.
- `requestFrameAttach` with `frameAttachController = nil` returns `Result.failure(.cameraPermissionDenied)`, never `.success`.
- Webview `dist/` bundle in tree matches `bash scripts/build-webview.sh` output (parity gate).

**Risk findings activated:**
- **R-003** (`frameAttachRequested` always returns success) → enforced by typed `Result` + nil-controller guard.
- **R-015 partial** (webview lockstep) → activated for Vision; full activation in M-7.

**Rollback plan:**
```
git checkout develop && git revert -m 1 <m5-merge-sha> && bash scripts/build-webview.sh
```
Webview falls back to `frameAttachRequested` inbound case (still routed at `App/AppDelegate.swift:2115-2117`). B-03 reappears but no other regression. Note: revert MUST include the webview `dist/` rebuild — leaving the v1.0-shaped `dist/` while reverting Swift surface causes silent message-routing failure (Failure Mode 3 in §5).

**Estimated effort:** 1.5–2.0 engineer-days. Atomic webview + Swift bump is the friction point.

**Carry-forward bugs closed:** **B-03** (HUD camera button click does nothing).

---

### 2.7 M-6 — Voice surface

**Goal:** Land Voice; substrate audio-graph fix; `synthesizeTurn` command (UQ-3 (A)); close B-04 + B-05. **Highest-risk migration** per `REVIEW-MIGRATION-RISK`.

**Branch / merge strategy:** Feature branch `migration/m6-voice`, single PR. Long-lived branch (4–5 days); rebase on `develop` daily to stay current with M-5.

**Prerequisites:** M-5 merged.

**Concrete commit-by-commit task list:**

Two sub-phases, mapped to commits:

| # | Commit | Scope |
|---|---|---|
| **M-6a — surface mapping (no audio-graph change)** | | |
| M-6.1 | `feat(api): Voice surface — getVoiceState query (read-only)` | Wraps `VoiceController` state. |
| M-6.2 | `feat(api): Voice events — voiceStateChanged, audioLevelChanged, wakeWordDetected, sttTranscriptPartial/Final, ttsStarted, ttsEnded, voiceDegraded` | Bridge from existing emit paths. NO audio-graph change in M-6a. |
| M-6.3 | `feat(api): Voice runtime-control verbs — pttDown, pttUp, cancelTTS (UQ-4 slim Voice)` | Removes `setTTSTier`, `muteWakeWord`, `unmuteWakeWord`, `startVoice`, `shutdownVoice`, `bargeIn` from Voice surface (Settings owns config; Turn owns bargeIn). |
| M-6.4 | `feat(api): Voice._injectAudioFrame, _injectWakeWord, _injectSTT, _observeTTSAudio (UQ-1 gated)` | G-001 resolution. First-class harness commands. Repurposes existing `MockTTSForController` etc. (hoisted in M-0.9). |
| **M-6b — substrate fix (B-04, B-05)** | | |
| M-6.5 | `fix(voice): startVoice() returns audioGraphFailed if ringBuffer nil after open() (B-04)` | Mitigates R-007. **No silent log-and-degrade.** Returns `.audioGraphFailed(reason: "ringBuffer nil after open()")`. Surface error rather than dormant. |
| M-6.6 | `feat(api): Voice.synthesizeTurn(turnId:text:tier:) -> Result<Void, TTSError> (B-05, UQ-3 (A))` | Orchestrator MUST issue this on `turnEnded(.completed)` for voice-source turns. Harness asserts: every voice-source completed turn has matching `synthesizeTurn` issued. |
| M-6.7 | `feat(agent): orchestrator wires synthesizeTurn on voice-source turnEnded(.completed)` | Encodes UQ-3 contract obligation. |
| M-6.8 | `feat(voice): bargeIn-driven cancelTTS internal invariant (R-018)` | `Turn.bargeIn` (which lands in M-7) MUST trigger `Voice.cancelTTS` as part of InterruptSequence. M-6.8 wires the substrate; M-7 wires the surface. Harness asserts: bargeIn during ttsStarted ⇒ ttsEnded(reason: .cancelled) before turnStarted of new turn. |
| M-6.9 | `test(harness): Voice scenarios — B-04, B-05, audioLevelChanged cadence, TTS cancel-on-bargeIn` | `S-VOICE-001..S-VOICE-012`. **B-04 gate:** `startVoice() success ⇒ ≥10 audioLevelChanged within 500 ms` (R-007 mitigation). **B-05 gate:** voice-source turn ending in `.completed` ⇒ `synthesizeTurn` was issued AND `ttsStarted` event observed (UQ-3 explicit-command contract). Both transport modes mandatory. |

**Gates:**
- `bash scripts/check-no-null-voice-adapters.sh` green.
- `bash scripts/check-presence-bus-no-tts-orchestrator.sh` green.
- All Voice scenarios green in both transport modes.
- **B-04 gate (R-007):** `startVoice()` success ⇒ ≥10 `audioLevelChanged` within 500 ms. Failing = substrate dead, do not merge.
- **B-05 gate (UQ-3):** `synthesizeTurn` invoked exactly once per voice-source `.completed` turn; `ttsStarted` observed.
- `bash scripts/verify-entitlements.sh --pre-codesign` green (R-012 — Voice may touch CoreAudio entitlements).
- `bash scripts/verify-codesign-settings.sh` green (R-013 — helper bundles unchanged).
- `JARVIS_REAL_MODELS=1 swift test --package-path packages/Voice --filter OrpheusTTFATests` green if Orpheus weights present (DEFERRED otherwise — see §6).

**Risk findings activated:**
- **R-007** (B-04 paper-over) → behavioral gate on `audioLevelChanged` cadence.
- **R-012/R-013** (codesign drift) → pre-codesign verification.
- **R-018** (bargeIn vs in-flight TTS) → substrate wired; surface in M-7.
- **F-001 / UQ-4** (Voice slim down) → activated.

**Rollback plan:**
```
git checkout develop && git revert -m 1 <m6-merge-sha>
```
Voice is the most independent subsystem — no DB, no other surface depends on it (Turn depends on Voice events but only post-M-7). Revert restores dormant voice subsystem. **B-04 + B-05 reappear; B-08, B-03 stay closed.** Codesign / entitlement deltas revert in lockstep with the commit.

**Estimated effort:** 4.0–5.5 engineer-days. M-6b substrate fix is the long pole (audio-graph install-order risk + entitlement re-verify). M-6.4 harness commands resolve a chunk of the test-contract gap.

**Carry-forward bugs closed:** **B-04** (voice input dead) + **B-05** (TTS silent).

---

### 2.8 M-7 — Turn surface (keystone)

**Goal:** Land Turn; partition `OutboundBatcher` by `turnId`; webview retires `sessionHistory` push (R-015); `bargeIn` on Turn (UQ-4); confirmation roundtrip; close B-06.

**Branch / merge strategy:** Feature branch `migration/m7-turn`, single PR. **Worst rollback in plan** — keep dual-channel transport (M-0.5) active until M-7 verified across N≥3 days of live use.

**Prerequisites:** M-6 merged.

**Concrete commit-by-commit task list:**

| # | Commit | Scope |
|---|---|---|
| M-7.1 | `feat(bus): OutboundBatcher.postToken takes turnId; flushes per-turn buffer (R-002)` | Pending buffer keyed by turnId. `flushAndSend` for `turnEnded` flushes ONLY that turn's pending tokens. On `bargeIn`, all superseded-turn pending tokens are dropped. |
| M-7.2 | `feat(api): Turn surface — submitTurn, cancelTurn, bargeIn, respondToConfirmation` | `bargeIn -> Result<BargeInAccepted, BargeInError>` (F-004). `cancelTurn` documented post-cancel silence (F-005). `images:` removed from `submitTurn` (F-007); frame attach is implicit-via-state. |
| M-7.3 | `feat(api): Turn events — turnStarted, tokenStreamed(turnId,seq), thinkingStreamed(turnId,seq), toolCallStarted/Updated/Ended, confirmationRequested, confirmationResolved, turnEnded, turnError, turnTextComplete` | `seq: Int` per turn (F-018). `turnTextComplete` event (G-006 / B-06 partial). |
| M-7.4 | `feat(mcp): ConfirmationBroker reads timeout from injected ConfirmationPolicy (R-008)` | Resolves R-008. Harness asserts configured timeout respected. `ConfirmationOutcome` collapses to single enum (F-013). |
| M-7.5 | `feat(api): getActiveTurn exposes toolCalls + accumulatedThinking (F-019)` | Supports late-connect hydration. |
| M-7.6 | `feat(webview): client retires sessionHistory push, calls listTurns on connect (R-015)` | **ATOMIC with Swift change.** `useEffect` on connect calls `Turn.listTurns(limit:)` query; renders chat panel from result. Same commit / same feature branch — webview `dist/` rebuilt and committed alongside Swift. See §4. |
| M-7.7 | `feat(api): Turn.bargeIn triggers Voice.cancelTTS (R-018 surface wiring)` | Closes the loop opened in M-6.8. |
| M-7.8 | `feat(bus): retire BusOutbound.hudState + sessionHistory cases` | Removes legacy emit paths. Bumps `BUS_PROTOCOL_VERSION = "2.4.0"` (drops `2.3.0` from accepted list per orchestrator-default). |
| M-7.9 | `test(harness): Turn scenarios — full set + B-06 turnTextComplete + bargeIn-cancels-TTS + cache-eligibility + post-cancel silence + per-turn seq monotonicity` | `S-TURN-001..S-TURN-018`. Includes the BLOCKING regression "submit-cancel-submit within 30 ms; assert no token from turn 1 appears under turn 2's turnId" (R-002 mitigation). Both transport modes mandatory. |

**Gates:**
- `bash scripts/check-orchestrator-events-single-consumer.sh` (now "single fanout drainer" per M-0.8) green.
- `bash scripts/check-bus-protocol-version.sh` green for `2.4.0` strict (dual-version window closes).
- `bash scripts/check-bus-harness-parity.sh` green.
- `bash scripts/check-app-builds.sh` green.
- `bash scripts/check-no-evaluate-javascript.sh` green.
- All Turn scenarios green in both transport modes.
- **R-002 BLOCKING regression:** submit-cancel-submit within 30 ms — no turn-1 token appears under turn-2's turnId.
- **F-005 post-cancel silence:** after `cancelTurn(t1)` succeeds, no further `t1` events; `turnEnded(t1, .cancelled)` is last.
- **F-018 seq monotonicity:** `seq == prevSeq + 1` across `tokenStreamed`/`thinkingStreamed` per turn.
- **B-06 partial gate:** `turnTextComplete` emitted between last `tokenStreamed` and `turnEnded` (DOM scroll ack remains vitest territory — R-014 / G-006).
- All M-1..M-6 harness scenarios still pass (regression).
- N≥3 days of live use with dual-channel transport active before declaring v1.0 lock.

**Risk findings activated:**
- **R-002** (OutboundBatcher coalesce without turnId) → CRITICAL — partitioned buffer.
- **R-008** (ConfirmationBroker timeout vs config) → activated.
- **R-009** (single-consumer vs multi-surface fanout) → activated; M-0.8 substrate makes it tractable.
- **R-014** (harness can't test webview DOM) → R-014 deferred to vitest layer; M-7 lands the API-side `turnTextComplete` event.
- **R-015** (webview lockstep) → activated; atomic merge.
- **R-018** (bargeIn vs TTS) → activated; surface wired.
- **F-005, F-007, F-013, F-018, F-019** → all activated.

**Rollback plan:**
```
git checkout develop && git revert -m 1 <m7-merge-sha> && bash scripts/build-webview.sh
```
**Worst rollback in plan.** Mitigation: M-0.5 dual-channel transport stays active across the N≥3-day soak so reverting Swift doesn't strand the webview on `2.4.0`. If M-7 is reverted, `BUS_PROTOCOL_VERSION` falls back to `2.3.0` and `WebviewBridge` accepts both versions per M-0.5; webview `dist/` (still v1.0-shaped) MUST be reverted alongside Swift to avoid silent message-routing failure. Tag a known-good M-6-tip commit before merging M-7 so revert target is unambiguous. **No SQLite schema migration in M-7** (Failure Mode 5 in §5).

**Estimated effort:** 5.0–7.0 engineer-days. OutboundBatcher refactor + per-turn `seq` + atomic webview cutover + N≥3-day soak.

**Carry-forward bugs closed:** **B-06 partial** (`turnTextComplete` emit; DOM scroll ack remains vitest).

---

## 3. The B-02 tactical patch (UQ-2 (B))

**Status:** OUTSIDE the M-0..M-7 sequence. Lands directly on `develop` BEFORE M-0 starts. Single commit.

**Patch site:** `packages/AgentCore/Sources/AgentOrchestrator/AgentOrchestrator.swift:283-286` — currently `[system, user(input.userText)]` only; no history fetch ([INVENTORY.md line 85](INVENTORY.md)).

**Patch shape:**
```swift
// Before (line ~283):
let messages: [LLMMessage] = [
  .system(systemPrompt),
  .user(input.userText)
]

// After:
let priorTurns = await memoryStore.recentTurnsForSession(limit: 10)
let messages: [LLMMessage] = [
  .system(systemPrompt)
] + priorTurns.flatMap { [.user($0.userText), .assistant($0.assistantText)] }
  + [.user(input.userText)]
```

(Exact field names ratified at patch time against `MemoryStore.recentTurnsForSession` signature.)

**Mandatory companion regression test** (added in same commit):
- File: `packages/AgentCore/Tests/AgentOrchestratorTests/HistoryThreadingRegressionTests.swift`
- Scenario: `testTwoShortTurnsThenThirdTurn_NoStreamTruncatedRetries`
- Asserts: across `submit("ok") → submit("yes") → submit("why?")`, observed orchestrator events contain ZERO `streamTruncated` retry trigger (R-006 mitigation; pins Phase E 2026-05-03 audit gate behavior).
- Asserts: third turn's request includes the first two turns' user+assistant content in the messages array.

**Gate:** the regression test MUST pass before commit lands. Companion existing scenarios (per `MemoryStore` test suite + cache-eligibility scenarios) MUST continue passing.

**Branch / merge strategy:** **Direct on `develop`.** Single commit `fix(b-02): thread recent turns into AgentOrchestrator messages array`. No PR (this is a tactical patch; the user has authority — Q-M-5 in `REVIEW-MIGRATION-RISK`).

**Effort:** 0.5 engineer-day.

**Bug closed:** **B-02** ([handoff §"What is BROKEN at HEAD"](HANDOFF-2026-05-07.md)).

**Rollback:** `git revert <patch-sha>`. B-02 reappears; no other regression.

---

## 4. Webview ↔ Swift atomic-commit choreography

The webview `dist/` bundle is generated by `bash scripts/build-webview.sh`. Swift-side surface changes that the webview consumes MUST land in lockstep, or the dual-channel transport (M-0.5) accepts the handshake while message routing fails silently (Failure Mode 3 in §5).

Two migration steps require lockstep webview + Swift changes: **M-5 (Vision)** and **M-7 (Turn)**.

### M-5 choreography

- **Same feature branch:** `migration/m5-vision` contains both Swift commits (M-5.1..M-5.3 + M-5.5) AND the webview commit (M-5.4 + rebuilt `dist/`).
- **Order within branch:** Swift commits land first (M-5.1..M-5.3 — typed surface available); webview commit lands last (M-5.4 — switches HUD camera button to typed call). The Swift side keeps the deprecated `frameAttachRequested` inbound case alive for one release, so even if webview commit is delayed, the path still works (degraded — B-03 still present, but no crash).
- **Dual-channel handshake protects against:** webview `dist/` and Swift binary at different protocol-version commits (`2.3.0` vs `2.4.0-rc`). M-0.5's lenient handshake means a stale `dist/` doesn't hard-block at boot; the user sees the warning banner but the app runs.
- **Atomic merge:** the PR squash-merge produces a single `develop` commit; webview + Swift land together. Reverting M-5 reverts both atomically.

### M-7 choreography

- **Same feature branch:** `migration/m7-turn` contains all M-7 Swift commits AND the webview retire-sessionHistory commit (M-7.6 + rebuilt `dist/`).
- **Order within branch:** Swift commits land first (M-7.1..M-7.5 — typed Turn surface, `listTurns` query available); webview commit lands fifth (M-7.6 — switches connect-time hydration to query). M-7.7 + M-7.8 land last (bargeIn-cancels-TTS surface; protocol-version bump to `2.4.0` strict).
- **Dual-channel handshake protects against:** webview frozen at `2.3.0`-shape while Swift bumps to `2.4.0`. M-0.5's lenient handshake stays active across the N≥3-day soak. The protocol-version bump to strict `2.4.0` (M-7.8) is the LAST commit in the M-7 branch — if soak reveals issues, M-7.8 reverts in isolation while keeping the Turn surface live.
- **Atomic merge:** PR squash-merge. Webview + Swift atomic. The ONLY reason webview commits would precede Swift is if the new wire shape were identical to the old — not the case for `listTurns` (new query path) or `bargeIn` (new command surface).

**Gate at PR open time for M-5 and M-7:**
```
diff --quiet <( git show HEAD:webview/dist/index.js | sha256sum ) <( bash scripts/build-webview.sh --check-only )
```
If `dist/` in tree does not match `build-webview.sh` output, PR cannot merge.

---

## 5. Failure modes & response procedures

### 5.1 Failure Mode 1 — Half-cutover acceptance

**Description (`REVIEW-MIGRATION-RISK §Failure modes #1`):** A migration commit ships the new surface but leaves the old emit site in place "for safety." Harness passes against the new surface; production has two emit paths racing into one client.

**Detection signal:** Behavioral single-writer gate (M-0.6) fails — harness probe sees ≥2 events for what should be a single emit. Boundary scripts (`check-single-memory-mutated-emit.sh`) fail because the new emit literal exists alongside the old.

**Rollback action:** Revert the offending commit. Re-open PR with the old emit deletion as a mandatory commit in the same branch. Reviewer enforces: every migration commit either deletes the old emit OR carries an explicit `// PARALLEL-EMIT: tracking issue #N, sunset date YYYY-MM-DD` comment.

**Post-mortem template:**
- Step that introduced the dual emit: M-?
- Why behavioral gate didn't catch at PR time:
- Sunset enforcement update for future migrations:
- Owner:

### 5.2 Failure Mode 2 — Boundary gate satisfaction without behavioral fidelity

**Description (`REVIEW-MIGRATION-RISK §Failure modes #2`):** Grep gate flips green because the literal string moved. Two writers in different files; gate is fooled.

**Detection signal:** Behavioral gate (M-0.6, M-0.7) catches what grep gate missed. If behavioral gate is also green but production manifests dual-write races, the harness scenario is incomplete.

**Rollback action:** Revert; expand behavioral gate to cover the scenario the production race manifested. M-0.6 / M-0.7 must be re-run as the canonical truth.

**Post-mortem template:**
- Production symptom:
- Behavioral gate that should have caught:
- Scenario gap added:
- Owner:

### 5.3 Failure Mode 3 — Webview frozen-bundle drift

**Description (`REVIEW-MIGRATION-RISK §Failure modes #3`):** Swift migrates to v0.1 surfaces; `webview/dist/` still talks v0.0. Handshake passes (dual-channel); message routing fails silently.

**Detection signal:** Harness `.jsonRoundTripWebView` mode (UQ-5) catches because it builds `dist/` at test time. Live: silent failure on the next user click after bundle rebuild missed.

**Rollback action:** Revert Swift commit AND rebuild `dist/` (revert pairs always include `bash scripts/build-webview.sh`). PR gate (§4) prevents this from merging — the parity check fails.

**Post-mortem template:**
- PR that bypassed §4 parity check:
- Why parity check was bypassed:
- CI enforcement update:
- Owner:

### 5.4 Failure Mode 4 — B-04 substrate not actually fixed

**Description (`REVIEW-MIGRATION-RISK §Failure modes #4`):** `Voice.startVoice -> Result<...>` returns `.success` based on `AudioGraphOwner.open()` returning, but `ringBuffer` is nil and audio still doesn't flow. Surface looks healthy; user has dead voice.

**Detection signal:** M-6 behavioral gate (R-007) — `startVoice() success ⇒ ≥10 audioLevelChanged within 500 ms`. Harness scenario `S-VOICE-001` fails.

**Rollback action:** Revert M-6. Voice subsystem returns to dormant state. Open issue requesting deeper audio-graph investigation (likely AVAudioEngine / CoreAudio install-order issue, not surface concern). Re-attempt M-6 only after substrate-side fix verified by `JARVIS_REAL_AUDIO=1` smoke test on real hardware.

**Post-mortem template:**
- Specific install step that failed (`AudioGraphOwner.open()` vs `ringBuffer` allocation vs subscriber wiring):
- Why M-6.5 commit's "no silent log-and-degrade" guard didn't catch:
- New harness scenario:
- Owner:

### 5.5 Failure Mode 5 — In-flight turn lost during M-7 commit deploy

**Description (`REVIEW-MIGRATION-RISK §Failure modes #5`):** User submits a turn; M-7 commit lands; new build starts; new build has different turn semantics and `ActiveTurnSnapshot` shape. Conversation history goes to schema-migrated table that maps the old turn fields wrong.

**Detection signal:** N/A in personal-app context (no live deploy; user controls relaunch). Mitigation is preventative.

**Rollback action:** **No SQLite schema migration ships in M-7.** Schema migrations belong to a quiet phase, not the keystone migration commit. PR gate: `bash scripts/check-no-schema-migration-in-turn.sh` (new — added in M-0 if not present) blocks any `*.sql` or `Migration_*.swift` file change in M-7's branch.

**Post-mortem template:**
- Schema delta proposed in M-7:
- Why moved out:
- Quiet phase landing target:
- Owner:

### 5.6 Failure Mode 6 (NEW — uncovered by locked decisions) — Harness mode env var leaked into production launch

**Description:** Per UQ-1 (runtime gate), `JARVIS_HARNESS=1` exposes test-only commands (`Voice._injectAudioFrame`, `Self._forceTCCStatus`, `_forceError`, ConfirmationBroker auto-approve). A misconfigured launchd plist or shell alias could set this env var on a Release launch, exposing seams to a malicious or buggy webview.

**Detection signal:** Boot-time check in `JarvisHost.boot()`: if `JARVIS_HARNESS=1` AND the binary is signed with the production Developer ID (not ad-hoc), emit `Diagnostics.hardBlockTriggered(reason: .harnessModeOnSignedRelease)` and terminate. Harness scenario `S-INFRA-001` asserts this hard-block fires.

**Rollback action:** N/A (boot-time hard-block is the rollback). User must remove the env var from their launch context.

**Post-mortem template:**
- Source of leaked env var (launchd plist, shell rc, accidental shell export):
- Detection lag:
- Removal steps:
- Owner:

### 5.7 Failure Mode 7 (NEW) — Harness data isolation breach

**Description:** Per orchestrator-default, harness data lives at `~/Library/Application Support/Jarvis-Harness/` when `JARVIS_HARNESS=1`. A bug in path selection could write harness fixtures to the production `~/Library/Application Support/Jarvis/` dir, corrupting real user data.

**Detection signal:** Boot-time check in `JarvisHost.boot()`: assert app-support directory matches `JARVIS_HARNESS` env state. Harness scenario `S-INFRA-002` runs both modes back-to-back and asserts no cross-contamination of `jarvis.db`.

**Rollback action:** Restore from `jarvis.db` daily backup (out of scope for this plan; user-side concern). Plan ensures the leak doesn't happen.

**Post-mortem template:**
- Code path that selected wrong dir:
- Boot-time assertion gap:
- Backup discipline change:
- Owner:

---

## 6. DEFERRED capability roadmap

Per orchestrator-default, the following capabilities ship in v1.0 with API homes defined but no live activation. Activation is post-migration v1.1+.

| Capability | API home (per v0.1/v0.2) | Substrate state | Activation requires |
|---|---|---|---|
| **Orpheus TTS (tier 2)** | `Voice.synthesizeTurn(turnId:text:tier: .tier2)` | `mlx-audio-swift v0.1.2` integration code present in `packages/Voice/Sources/Voice/TTS/`; weights NOT downloaded; `MissingT2Provider`-style placeholder. | (1) ~6 GB Orpheus weights downloaded; (2) `JARVIS_REAL_MODELS=1 swift test --package-path packages/Voice --filter OrpheusTTFATests` green; (3) empirical TTFA 150–250 ms verified. v1.1 milestone. |
| **WhisperKit (STT fallback)** | `Settings.setSTTBackend(.whisperKit)`; `Voice.sttTranscriptPartial/Final` events | `argmaxinc/argmax-oss-swift v0.18.0` package added; wiring code present; behind feature flag `Settings.featureFlags.whisperKitSTT`. | Feature flag enabled; large-v3-v20240930_626MB model fetched; SpeechAnalyzer fallback path tested. v1.1 milestone. |
| **Vision T2 sidecar (vLLM/MLX)** | `LLMProvider` `withImages` path; vision T2 escalation under same `turnId` | `VllmMlxProvider` exists; `MissingT2Provider` is default conformer (`packages/Vision/Sources/Vision/MissingT2Provider.swift:24`). | (1) MLX vision model selected; (2) sidecar process management; (3) escalation policy in `VisionRouter.swift:63` reactivated. v1.2 milestone. |
| **Presence pipeline (camera-derived `atDesk`/`presenceConfidence`)** | `Self.selfStateChanged.atDesk: Bool, presenceConfidence: Float` | F-021 amendment defines API home; substrate code in `packages/Vision/` exists but `check-presence-vision-isolation.sh` enforces inert. | Camera-derived presence enrichment activated; `HudStateCoordinator` consumes presence intents (already wired internally). v1.2 milestone. |
| **Voice Log menu item (B-07)** | `Diagnostics` window subscribing to voice events + `audioLevelChanged` + `wakeWordDetected` + `sttTranscript*` | F-Q-C resolved — no new events needed for v1.0; UI is window-only. Stash@{0} has partial Voice Log scaffolding (handoff §"Loose ends"). | Don't ship until B-04/B-05 land (M-6 closes). Then resurface stash@{0} or rewrite cleanly. v1.1 milestone. |
| **Multi-client subscription** | F-020 — single client at v1.0. | `WebviewBridge` is single-client by construction. | v2 concern; not a v1.x deferral. |

**Documentation:** v1.0 spec §6 lists all DEFERRED items with `[trigger: deferred]` annotation per G-005. Activation in v1.1 follows the same migration-card discipline (one capability per feature branch, harness scenarios required, rollback specified).

---

## 7. D-5/D-6/D-7 dependency

Per orchestrator-default, **D-5 (build `libsqlite3.dylib` with extensions) and D-6 (fetch `vec0.dylib`) BLOCK M-4 start. D-7 (`ollama pull nomic-embed-text` + `qwen2.5-coder:32b`) blocks M-4 vector-search activation.** The M-4 PR shape depends on user's environment status at PR open time:

### Path A — D-5/D-6/D-7 closed before M-4

- M-4.4 ships with `memoryVectorAvailable: true` at boot when dylib loads.
- `searchFacts` returns hybrid (FTS + vector) results.
- M-4.6 vector-search scenarios run in `JARVIS_REAL_MODELS=1` lane (skipped in default `swift test`; required for PR merge).
- `getSelfState.memoryVectorAvailable: Bool` reflects `true`.

### Path B — D-5/D-6/D-7 not closed at M-4 start

- M-4.4 ships with `memoryVectorAvailable: false` at boot.
- `searchFacts` returns FTS-only results; typed `MemoryError.vectorIndexUnavailable` available to clients.
- M-4.6 vector-search scenarios skipped at PR time; tracked as M-4 follow-up.
- `getSelfState.memoryVectorAvailable: Bool` reflects `false`.
- M-4 merges. When user closes D-5/D-6/D-7 later, a **single follow-up commit** flips the flag at runtime (`vec0.dylib` load path enabled) and re-runs M-4.6 scenarios in `JARVIS_REAL_MODELS=1` lane.

### Decision point at M-4 PR open

The M-4 PR description includes the explicit declaration:
```
D-5/D-6/D-7 status: [closed | open]
M-4 ships with memoryVectorAvailable: [true | false]
Follow-up commit required: [no | yes — tracked at <issue>]
```

The PR cannot merge without this declaration filled in. CI runs M-4.6 scenarios skipping the `JARVIS_REAL_MODELS=1`-gated subset if the declaration says open.

---

## 8. Total schedule estimate

**Engineer-days (sum of step ranges):**
- B-02 patch: 0.5
- M-0: 2.5–3.5
- M-1: 1.0–1.5
- M-2: 1.5–2.0
- M-3: 1.0–1.5
- M-4: 2.0–3.0
- M-5: 1.5–2.0
- M-6: 4.0–5.5
- M-7: 5.0–7.0
- **Total: 19.0–26.0 engineer-days**

**Calendar (solo pace, 5 days/week, includes context-switch and PR review overhead):**
- Best case: **4 weeks** (every gate passes first-merge; D-5/D-6/D-7 closed before M-4; UQ-5 parametric runtime growth offset by parallel `swift test` workers; no rebase conflicts).
- Expected case: **5 weeks** (one or two PRs require iteration; M-4 ships Path B with follow-up; M-6 audio-graph fix takes extra day).
- **Worst case: 6.5 weeks** if B-02 patch surfaces a `streamTruncated` regression (R-006). Recovery: revert B-02 patch, expand cache-eligibility regression suite, re-land patch with refined cache-hint logic. +5–7 engineer-days.

**N≥3-day soak after M-7** is included in calendar estimate but not in engineer-days (passive observation).

---

## 9. v1.0 lock criteria

The exit gate from "in migration" to "v1.0 live" is the conjunction of:

### Harness scenarios (all green in BOTH transport modes per UQ-5)

- All `S-SELF-001..004` (M-1)
- All `S-SET-001..008` (M-2)
- All `S-DIAG-001..009` (M-3)
- All `S-MEM-001..008` including `S-MEM-CACHE-REGRESSION` (M-4); vector scenarios green in `JARVIS_REAL_MODELS=1` if Path A
- All `S-VIS-001..006` (M-5)
- All `S-VOICE-001..012` (M-6)
- All `S-TURN-001..018` (M-7)
- `S-INFRA-001` (harness-on-signed-Release hard-block)
- `S-INFRA-002` (harness data isolation)

(Scenario IDs above are placeholders; ratify against Phase 5 `JARVIS-API-TEST-CONTRACT.md` output.)

### Boundary gates (all green)

- `bash scripts/check-app-builds.sh`
- `bash scripts/check-bus-harness-parity.sh`
- `bash scripts/check-bus-protocol-version.sh` (now strict `2.4.0`)
- `bash scripts/check-corpus-secrets.sh`
- `bash scripts/check-embedding-dim-literal.sh`
- `bash scripts/check-install-order.sh` (behavioral)
- `bash scripts/check-no-evaluate-javascript.sh`
- `bash scripts/check-no-leftover-stubs.sh`
- `bash scripts/check-no-modal-presentation.sh`
- `bash scripts/check-no-null-voice-adapters.sh`
- `bash scripts/check-orchestrator-events-single-consumer.sh` (single-fanout-drainer)
- `bash scripts/check-presence-bus-no-tts-orchestrator.sh`
- `bash scripts/check-presence-vision-isolation.sh`
- `bash scripts/check-single-memory-mutated-emit.sh`
- `bash scripts/check-single-memory-used-emit.sh`
- `bash scripts/check-single-writer-hudstate.sh` (behavioral)
- `bash scripts/check-vision-isolation.sh`
- `bash scripts/check-fanout-drainer.sh` (new — M-0.8)
- `bash scripts/check-no-schema-migration-in-turn.sh` (new — M-0)
- `bash scripts/verify-entitlements.sh --pre-codesign` and `--post-codesign`
- `bash scripts/verify-codesign-settings.sh`

### Carry-forward bugs closed

- B-02 (history threading) — closed by tactical patch + M-4 regression gate.
- B-03 (camera button) — closed by M-5.
- B-04 (voice input dead) — closed by M-6.5/M-6.9 behavioral gate.
- B-05 (TTS silent) — closed by M-6.6/M-6.7 + UQ-3 (A) command contract.
- B-06 (chat scroll) — partially closed by M-7 `turnTextComplete`; full closure deferred to webview vitest layer.
- B-07 (Voice Log menu) — DEFERRED to v1.1 (handoff §"Loose ends"; orchestrator-default).
- B-08 (model paraphrase) — closed by M-1.3.

### Documentation landed

- `JARVIS-API-DESIGN-v1.0.md` — single-doc merge of v0.1 + v0.2 + UQ answers (post-Phase-6 housekeeping).
- `JARVIS-API-TEST-CONTRACT.md` (Phase 5 output) — every Command has ≥1 scenario; every Event has ≥1 assertion (OQ-T3).
- `JARVIS-API-MIGRATION-PLAN.md` (this document).
- `Tools/jarvis-diag/` skeleton harness target (Phase 5 output) implemented with full scenario coverage.
- `CLAUDE.md` updated with `JARVIS_HARNESS=1` env-flag convention alongside `JARVIS_REAL_MODELS`/`JARVIS_REAL_CAMERA`.

### Soak

- N≥3 days of live use post-M-7 with dual-channel transport active. M-7.8 (strict `2.4.0`) is the LAST commit and lands only after soak.

When all of the above are true, v1.0 is live.

---

## 10. Post-migration v1.1+ backlog

DEFERRED items and design open questions explicitly out of v1.0 scope.

### v1.1 milestone

- **B-07 Voice Log menu item** — re-scope against new Diagnostics surface; resurface or rewrite stash@{0} content (handoff §"Loose ends" item 3).
- **Orpheus TTS (tier 2) activation** — weights download, TTFA verification, `Voice.synthesizeTurn(tier: .tier2)` lights up.
- **WhisperKit STT fallback activation** — `Settings.setSTTBackend(.whisperKit)` lights up.
- **F-Q-E (long-running query cancellation)** — `Memory.searchFacts`/`Turn.listTurns` gain cancellation-on-disconnect semantics. Currently bounded by `limit:` only.
- **F-15 (Self vs System rename polish)** — naming polish; functional placement unchanged.
- **OQ-T2 (fixture format in spec)** — fixture corpus shape promoted from harness-internal to spec-documented.
- **OQ-T4 (state-ownership runtime assertion)** — origin tagging on events to prove single-writer at runtime; v1.0 ships grep + behavioral, v1.1 adds runtime origin tags.
- **`JarvisHost` SUMMARY update for Plan 10-02** (handoff §"Loose ends" item 1) — flip AC-05 FAIL → PASS.
- **Plan 10-02c SUMMARY** (handoff §"Loose ends" item 2) — write SUMMARY scaffold.

### v1.2 milestone

- **Vision T2 sidecar (vLLM/MLX)** — model selection, sidecar process management, T2 escalation policy reactivated.
- **Presence pipeline activation** — camera-derived `atDesk`/`presenceConfidence`; `HudStateCoordinator` integration verification.
- **Multi-client subscription (v2 concern)** — only if a real second client emerges (eval CLI currently uses direct actor calls).

### Continuous

- **HUMAN-UAT for VOICE-07/09/10/12/13/14** on Release Developer ID archive (handoff §"Loose ends" item 4).

---

**End of migration plan. v1.0 lock pending Phase 5 test-contract output and user-side execution against this plan.**
