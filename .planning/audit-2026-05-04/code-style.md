# Code Style & Conventions Audit — 2026-05-04

## Verdict: MINOR-ISSUES

The codebase is internally consistent on the load-bearing project conventions: VOICE-14 grep gate holds (one production `cancelAndSubmit` site in `VoiceController`), T-06-05-03 transcript-redaction discipline holds (no PCM/transcript content reaches loggers), the new `check-no-leftover-stubs.sh` linter passes clean, force-unwraps in production are confined to `baseAddress!` at C-pointer boundaries (justified), and Swift-6 actor isolation, `@Sendable`, and `nonisolated(unsafe)` are used with annotated rationale. Today's 22-commit churn maintained the surrounding style well — no commit looks bolted-on. The minor issues are pervasive rather than dangerous: ticket-ID-laden WHAT comments, inconsistent test-double naming (Mock/Stub/Fake all in use for the same role), public test seams that should be `internal`+`@testable`, and a 2,112-line `AppDelegate.swift` that is approaching the point where surgical edits become risky.

## Findings by category

### Swift idioms

- **packages/Voice/Sources/Voice/VoiceController.swift:206 — STYLE-BUG — public test seam**: `public func _forceState(_:)` and `public func _testFireSpeechEnd(text:)` (line 211) leak test-only entry points into the package's public API. Anyone importing `Voice` can call them in production code. The convention used elsewhere (e.g., `packages/Vision/Sources/Vision/CameraCapture.swift:36 authStatusProbe`, `packages/AgentCore/Sources/AgentOrchestrator/AgentOrchestrator.swift:724 _testCurrentTurnId`) is `internal` + `@testable import`. Same issue: `packages/MCP/Sources/MCP/MCPClient.swift:192 _testHandle`, `packages/MCP/Sources/MCP/MCPServerHandle.swift:341 _testProcessIdentifier`. Prefer `internal` (or `@_spi(Testing) public`) so tests still see them but downstream callers don't.
- **packages/Voice/Sources/Voice/STT/WhisperKitSTT.swift:43-44 — STYLE-BUG — `nonisolated(unsafe) var` in instance state**: `audioBuffer: [Float]` and `finishedTranscript: String` are mutable instance state on a `@unchecked Sendable` class. The combination of `nonisolated(unsafe)` + mutable `var` + `@unchecked Sendable` on a long-lived object is a hand-rolled actor. If contention is real, make it an `actor`; if not, document the single-thread invariant the class relies on. The other `nonisolated(unsafe)` uses in production (`packages/Logging/Sources/JarvisLogging/FileLogHandler.swift:54-56`) are `static let` of an immutable formatter — that's the legitimate pattern.
- **App/AppDelegate.swift:2050-2053 — STYLE-NOISE — comment is correct and load-bearing**: `nonisolated(unsafe) private weak var coordinator: HUDBannerCoordinator?` is paired with a thoughtful WHY comment. Keep this pattern.
- **packages/Voice/Sources/Voice/AudioGraph/BufferBroadcaster.swift:114-122 — STYLE-NOISE — well-executed real-time discipline**: `publish(_:)` snapshots subscribers under `OSAllocatedUnfairLock` then iterates outside the lock. The threading note at lines 21-31 explains why. This is the right shape for the Core Audio tap thread; flag as a positive.
- **packages/Logging/Sources/JarvisLogging/Redact.swift:13 — STYLE-BUG — `try!` on regex from runtime input**: `return try! NSRegularExpression(pattern: raw)` force-throws if `raw` is malformed. The patterns are compile-time constants today, but the API takes `raw: String` — a future caller passing a runtime pattern crashes the redaction subsystem. Either narrow the input type to a `Regex<…>` literal or `do { try } catch { assertionFailure(); return …safe-no-op… }`.

### Project-specific conventions

- **VOICE-14 — CLEAN**: `grep -nE 'cancelAndSubmit' packages/Voice/Sources/Voice/VoiceController.swift | grep -v '//'` returns exactly one line (315). The grep gate documented at line 292-294 holds.
- **T-06-05-03 — CLEAN**: zero `logger.*transcript` / `log.*\.text` matches in `packages/Voice/Sources`. The `runVADInterceptor` at `VoiceController.swift:441-444` swallows VAD inference errors silently to avoid logging the chunk that caused them — correct under the discipline. Comment at line 373 (`T-06-05-03: transcript text is NEVER passed to logger`) is the canonical example of a WHY comment that earns its keep.
- **Dormant continuation pattern — CLEAN**: `dormantAgentContinuation` / `dormantVoiceContinuation` / `dormantConfirmContinuation` at `App/AppDelegate.swift:1805-1807` are real producer-stream retention with comments explaining "Phase 4 replaces…", and the linter explicitly allowlists `Dormant*` (`scripts/check-no-leftover-stubs.sh` lines describing the allowlist). Not abused.
- **Test seams — STYLE-BUG**: `_test*` prefix is used inconsistently. Public + underscore-prefixed (`MCPClient._testHandle`, `MCPServerHandle._testProcessIdentifier`, `VoiceController._testFireSpeechEnd`, `VoiceController._forceState`) coexists with `internal var …Probe` (`CameraCapture.authStatusProbe`, `AudioGraphOwner.authStatusProbe`, `CameraCapture.photoCaptureOverride`). The `Probe` form is the better pattern (no `_` prefix, no `public` leak). Today's `CameraCapture.photoCaptureOverride` at `packages/Vision/Sources/Vision/CameraCapture.swift:43` follows the good pattern; the `_test*` siblings should migrate.
- **Settled architecture — CLEAN**: today's commits did not relitigate the AudioGraph topology, RingBuffer SPSC contract, or Bus schema. `BufferBroadcaster` (Track B-7) extended the AudioGraph topology without changing the SPSC contract per-subscriber — exactly the right shape.

### Naming

- **Mock / Stub / Fake — CONVENTION-VIOLATION (new today)**: today's added tests deepened an existing inconsistency. Within a single test target the same role uses three names:
  - `packages/Memory/Tests/MemoryTests/RememberBrutusEndToEndTests.swift:35` — `actor FakeStore`
  - `packages/Memory/Tests/MemoryTests/RememberBrutusEndToEndTests.swift:71` — `actor StubEmbedder`
  - `packages/Memory/Tests/MemoryTests/MemoryExtractionOrchestratorTests.swift:28` — `class TimedMockProvider`
  - `packages/Voice/Tests/VoiceTests/VADGatedSessionTests.swift:57-63` (today) — `MockVADEngine`, `MockOrchestratorForController`, `MockTTSForController`, `MockBannerForController`, `MockBusEmitter`
  - `packages/Vision/Tests/VisionTests/FrameAttachConfirmSendWiringTests.swift:60-66` (today) — `StubCapture`, `StubSink` for the same role `FrameAttachControllerTests.swift:124,138` calls `FakeCapture`, `FakeReplaySink`.
  Repo-wide: 26 `Mock*` types, 21 `Fake*`, 12 `Stub*`. This was flagged in `2026-05-03` audit; today's tests cemented the inconsistency rather than starting to converge. Pick one (recommend **Fake** for "in-memory state-holding test double", **Stub** for "returns canned data, no behaviour", **Mock** for "records calls for verification") and document in `CLAUDE.md` or a per-package CODE_STYLE.md.
- **Acronym capitalization — CLEAN**: `STT`, `TTS`, `VAD`, `AEC`, `MCP`, `HUD`, `VPIO` all preserve case in type names (`MCPClient`, `STTProvider`, `TTSEngineActor`, `SileroVAD`, `AudioGraphOwner.preferAec`, `VPIOOrderingTests`). The lowercased forms in variable/method positions (`wantAec`, `vpioFailureCausesAecOffRebuild`, `ttsAdapter`) follow Swift API guidelines (acronyms lowercase at leading-camelCase position). A handful of compound tests (`packages/Harness/Sources/jarvis-eval/main.swift:75 struct McpCrash`) drop case in the middle of a compound but appear deliberate (matches `--mcp-crash` CLI flag); harmless.
- **File-name vs symbol parity — CLEAN**: spot-checked top files; one type per primary symbol. The "multiple public types per file" finding (`packages/Replay/Sources/Replay/ReplayEvent.swift` has 4) is for enum-case-bearing companion types, which is the right shape.

### Error handling

- **packages/Voice/Sources/Voice/VoiceController.swift:441-444 — STYLE-NOISE — silent swallow with WHY**: VAD inference failure is silently ignored. Comment explains "keep the session alive (prefer letting pttUp / explicit finalize close it)." Justified.
- **App/AppDelegate.swift:1534, App/AppBusForwarderSink.swift:26-36 — STYLE-NOISE — `try? await batcher.flushAndSend(...)`**: bus emission is best-effort for HUD presentation; failure of a single send must not crash the app or block the orchestrator. Justified.
- **packages/Voice/Sources/Voice/STT/WhisperKitSTT.swift:83,93,101 — STYLE-BUG — three `try? await self.bridge.transcribe`**: silently coalesces a transcription error into "no text emitted." Caller cannot distinguish "user said nothing" from "WhisperKit blew up." Should at minimum `logger.warning("WhisperKit transcribe failed: \(error)")` (no transcript content involved, T-06-05-03-safe). Same pattern at SpeechAnalyzerSTT:294 is fine — `try? finalizeAndFinishThroughEndOfInput()` runs at session-teardown when the bridge is being dropped anyway.
- **packages/Memory/Sources/Memory/MemoryStore.swift:200,203 — STYLE-NOISE — `try? conn.rollback()` after caught exception**: rollback failure inside an already-failing transaction is the textbook case for silent best-effort. Justified.
- **Custom error types — CLEAN**: `VoiceError`, `VisionError`, `MemoryError`, `MCPError`, `STTError`, `VADError`, `AudioGraphError` — every package has its own typed error. No `NSError` synthesis in production paths.

### Comment hygiene

- **CONVENTION-VIOLATION — pervasive ticket-ID and Plan/Track references**: `~/.ai/2-coding-style.md:41` says "Don't reference the current task, fix, ticket, or caller … That belongs in the PR description and rots fast." The codebase has:
  - 503 occurrences of `Plan [N]` / `RESEARCH-DELTAS` / `Phase [N]` in production sources
  - 102 occurrences of ticket IDs (`BLOCKER-`, `F-A`, `D-1`, `VOICE-`, `HUD-`, `MEM-`, `VISION-`, `TEXT-`) in production comments
  - Examples: `App/AppDelegate.swift:8-18` — every import has `// Plan 06-05: ...` / `// Plan 07-06: ...` / `// CR-02 (REVIEW 05): ...` / `// Track-D D-1: ...`. These will rot the moment the plan number changes.
  - This conflicts with the explicit global rule. Acknowledged: the project-local `CLAUDE.md` references plan IDs heavily as a workflow tool, so a per-repo override is reasonable — but the comments still need a half-life. Recommend a one-time pass to drop the import-line plan numbers and any comment that refers to a closed plan, keep only those that reference active or load-bearing structural decisions (e.g., "VOICE-14 single call site" — still active gate; "Plan 03-05 wires this..." — historical).
- **Stale comments — STYLE-NOISE — light**: `App/MenuBar/MenuBarIconController.swift:61` `// TODO(Phase 3/4): dedicated animations` is the only TODO-form comment in production. Linter caught no `Replaced in 0…` / `TODO: Plan ` / `TODO: 0X-` markers; the F2 gate is doing its job.
- **MARK: hygiene — CLEAN**: 728 `// MARK:` lines across the codebase, used for navigation in long files. Reasonable density.
- **WHAT vs WHY — MIXED**: The good — `BufferBroadcaster.swift:21-31`, `VoiceController.swift:347-351`, `MCPBusGatewayAdapter.swift:35-40` (late-binding rationale), `MissingT2Provider.swift:7-23` (the WHY of the explicit-missing pattern). The not-so-good — `App/AppDelegate.swift:8-18` import comments restate WHAT the import is for ("`// Plan 07-06: CameraCapture + PresenceMonitor + VisionRouter`"). The import line itself + the surrounding install-method docstring already say this.

### File organization

- **App/AppDelegate.swift:1 — STYLE-BUG — 2112 LOC**: 4× the 500-LOC threshold cited in the audit prompt. Today's commits added 269 lines (memory wiring + frame-attach handlers). The file holds: probe protocols (lines 22-34), AppDelegate (line 59) with menu-bar install, HUD/banner panels, bus install, voice install, vision install, memory install, agent install, hot-key wiring, chat handlers, dev-overlay, state-dump, banner adapters (line 1884+), and various private adapter classes (line 2050+). Each `installX()` is self-contained — the cleanest extraction is probably `AppDelegate+Voice.swift`, `AppDelegate+Vision.swift`, `AppDelegate+Memory.swift`, `AppDelegate+Agent.swift`, `AppDelegate+Bus.swift` (Swift extensions in separate files, `@MainActor` propagates). Not urgent but the next significant edit will hit merge-conflict / mental-load thresholds.
- **packages/AgentCore/Sources/AgentOrchestrator/AgentOrchestrator.swift:1 — STYLE-NOISE — 734 LOC, watching list**: still tractable, but at 734 LOC the next feature addition tips over.
- **packages/Memory/Tests/MemoryTests/MemoryExtractionOrchestratorTests.swift:1 — STYLE-NOISE — 565 LOC test file**: today's D-3 commit added 122 lines bringing it past 500. Test files are usually allowed more leniency; flag for awareness only.
- **One type per file — CLEAN**: The few files with multiple public types (`ReplayEvent.swift`, `OpenWakeWordSession.swift`, `Protocol.swift`) are companion-type clusters (enum + DTO + error), which is idiomatic Swift.

### Magic numbers

- **packages/Voice/Sources/Voice/VoiceController.swift:69 — CLEAN — `vadHangoverChunks: Int = 5`**: named constant with a WHY comment explaining "5 chunks = 160 ms." Right shape.
- **packages/Voice/Sources/Voice/VoiceController.swift:300 — STYLE-NOISE — `0.200` debounce literal**: hardcoded in the body of `bargeIn`; the comment line 47 calls it the "200ms barge-in debounce." Should be a named static constant (`bargeInDebounceInterval: TimeInterval = 0.200`) so the test (BargeInTests B4) and production share it instead of two literals drifting.
- **packages/Voice/Sources/Voice/AudioGraph/BufferBroadcaster.swift:81 — CLEAN**: `defaultSubscriberCapacityFrames: Int = 32_000` named, with comment explaining "2 s of 16 kHz mono."
- **packages/Voice/Sources/Voice/VAD/SileroVAD.swift:60,219 — CLEAN**: `static let sampleRate: Int32 = 16000` and `requiredChunkSize = 512` are named constants with RESEARCH-DELTAS comments. Right shape.
- **packages/Voice/Sources/Voice/AudioGraph/AudioGraphOwner.swift:316 — STYLE-NOISE — bare `.milliseconds(250)`**: `try? await Task.sleep(for: .milliseconds(250))` — pull into a named constant near the call site (e.g., `private static let degradationDebounce: Duration = .milliseconds(250)`) so it's discoverable in code review.
- **packages/Voice/Sources/Voice/TTS/TTSEngineActor.swift:141 — STYLE-NOISE — `sampleRate: 24000`**: comment one line up calls Orpheus 24 kHz; pull into a named `Orpheus.outputSampleRate` constant.

### Imports

- **App/AppDelegate.swift:1-18 — STYLE-NOISE — 18 imports**: Highest in the project. Unavoidable for the bootstrap; flag is informational. No unused imports detected by inspection.
- **Cross-package boundary — CLEAN**: `App/MCP/InProcessMemoryAdapters.swift:14-16` is the legitimate App-layer bridge between MCP and Memory — comment at lines 4-12 explains why the adapter must live here rather than in `packages/MCP/`. Good shape.

### Test code style

- **XCTest vs swift-testing — CONVENTION-VIOLATION light**: Voice tests are split — 11 swift-testing (`@Test`) files (`AECFallbackTests`, `BufferBroadcasterTests`, `RingBufferTests`, `TeardownTests`, `VpioOrderingTests`, `InputFormatProbeTests` …) coexist with 18 XCTest files (`VADGatedSessionTests` from today, `VoiceLoopE2ETests` from today, `VoiceControllerTests` …). Two of today's three voice-test additions are XCTest; one was BufferBroadcasterTests in swift-testing style. **Question for the team**: is this intentional (e.g., XCTest for `async throws` ergonomics, swift-testing for parameterized cases) or accidental? If intentional, document the criterion in `packages/Voice/Tests/CODE_STYLE.md`. If accidental, pick one for new tests.
- **Test naming — STYLE-NOISE — three styles in active use**:
  - `func testVAD1_speechEnd_after_hangover_finalizes_and_submits` (today, `VADGatedSessionTests`) — id-prefix + snake_case body
  - `func testE1_chunkPump_audio_reaches_orchestrator_as_transcript` (today, `VoiceLoopE2ETests`) — same shape
  - `func test_TET1_1_canConstructWithNilOrpheus` (`TTSEngineActorTier1Tests`) — `test_` prefix
  - `func testD3_priorFactsLookupDrivesUpdateOp` (today, `MemoryExtractionOrchestratorTests`) — id-prefix + camelCase body
  - `@Test("VAD-1: speechEnd + 5×silence → submit")` (swift-testing files) — string-form
  - Counts: 399 `testXxx`, 440 `test_xxx`, 85 `@Test`. Pick one and stick with it; today's commits straddled all four conventions.
- **`XCTAssertEqual` argument order — CLEAN spot-check**: `XCTAssertEqual(armedCount, 1, "...")` (App/Tests/AppTests/AppDelegateBusWiringTests.swift:133) follows actual-then-expected, the Apple-recommended order; consistent across recent tests.
- **`try!` in tests — STYLE-NOISE — fine**: 9 `try!` in test code, all on `JSONDecoder().decode(LaunchSnapshot.self, ...)` over byte literals embedded in the test. Justified — failure indicates a test fixture is wrong, which is the right time to crash.
- **`@unchecked Sendable` on test doubles — CLEAN**: pervasive (e.g., `App/Tests/AppTests/VoiceWiringTests.swift:144-175` has 5), each annotated with the comment template "fields are `let` / `var` for recording, but the protocol requires Sendable." Honest documentation.

### Today's churn quality

- **22 commits, 3253 insertions / 208 deletions**: Mostly additive (new wiring + tests). No commit looks bolted-on; new code matches surrounding style closely.
- **`MCPBusGatewayAdapter.swift` — CLEAN**: well-commented WHY (BLOCKER-INT-1 fix rationale, late-binding closure, SHA256-to-UUID derivation), no force-unwraps, idiomatic actor.
- **`InProcessMemoryAdapters.swift` — CLEAN**: 56 LOC, two adapters, file-header comment explains the cross-module-boundary rationale. Right shape.
- **`MissingT2Provider.swift` — CLEAN**: file-header explains "the explicit-missing pattern," not just what the type does.
- **`BufferBroadcaster.swift` — CLEAN**: see Swift idioms section.
- **`CameraCapture.swift` Track-C diff — STYLE-BUG light**: 272 added lines bring this to 395 LOC. Two new internal types (`PhotoCaptureProxy`, `VideoSampleDelegate`) live in the same file as `CameraCapture` actor — fine because they're tightly coupled to the actor's delegate interactions, but watch for further accretion.
- **`VoiceController.swift` Track-B-6 diff — CLEAN**: `runVADInterceptor` is well-organized, has WHY comments at the carry-buffer and `didTrigger` flag, doesn't introduce new test seams.
- **`scripts/check-no-leftover-stubs.sh` — CLEAN**: shellcheck-clean shape (`set -euo pipefail`, quoted expansions, mapfile), `#!/usr/bin/env bash`, `usage()` self-test mode. Matches `~/.ai/2-coding-style.md` shell section.
- **No new force-unwraps, no new `try!` in production**: spot-checked diff; the existing `baseAddress!` calls in `PCMBufferBuilder.swift` / `OpenWakeWordSession.swift` / `SileroVAD.swift` are legitimate C-pointer access at FFI boundaries.

## Top 5 issues to fix first

1. **Public test seams in `Voice` and `MCP`** — convert `_forceState`, `_testFireSpeechEnd` (VoiceController), `_testHandle` (MCPClient), `_testProcessIdentifier` (MCPServerHandle) from `public` to `internal` (with `@testable import` in tests) or `@_spi(Testing) public`. They're currently part of the package's public API, which is a concrete bug (anyone can call `_forceState(.speaking)` from `App/AppDelegate.swift`).
2. **Mock/Stub/Fake naming convergence** — pick one taxonomy and document in CLAUDE.md or a per-package CODE_STYLE.md. Today's commits added new variants (`StubCapture` in Vision tests next to existing `FakeCapture` for the same role); one more cycle of this and the test code becomes hostile to grep.
3. **Comment hygiene pass on plan/ticket references** — strip `// Plan NN-NN: …` / `// CR-NN (REVIEW NN): …` from import lines and from comments that refer to closed plans. Keep only comments that reference active gates (VOICE-14, T-06-05-03) or load-bearing structural decisions. A `~/.ai/2-coding-style.md:41` violation by the global style guide; per-project override is OK but the rot is real.
4. **`AppDelegate.swift` extraction plan** — at 2112 LOC it's the largest file in the codebase by 1378 lines. Extract `AppDelegate+Voice.swift`, `AppDelegate+Vision.swift`, `AppDelegate+Memory.swift`, `AppDelegate+Agent.swift`, `AppDelegate+Bus.swift` as `@MainActor extension AppDelegate` files. Each `installX` is already self-contained.
5. **`WhisperKitSTT.swift:83/93/101` `try? await transcribe` — log the error**: silent failure in the fallback STT path makes "user said nothing" indistinguishable from "WhisperKit crashed." Adding a `warning` log (no transcript content) costs nothing and pays back the first time a regression happens.

## Things that are actually good

- **`scripts/check-no-leftover-stubs.sh`** — well-shaped linter with a self-test mode, a documented allowlist for the legitimate `Dormant*` pattern, and shell-style hygiene. Catches a real anti-pattern (BLOCKER-INT-1's `NoopBusGateway`). The header comment explains the precision-over-recall tradeoff.
- **`BufferBroadcaster.swift`** — exemplary real-time-thread file. Explicit threading discipline in the docstring, `OSAllocatedUnfairLock` snapshot-and-iterate pattern, and the `@unchecked Sendable` rationale spelled out at lines 33-37.
- **`MissingT2Provider.swift`** — clean implementation of the "explicit-missing instead of silent-fallback" pattern. The WHY comment is exactly what comments should be: it explains the bug class being prevented, not what the type does.
- **VOICE-14 + T-06-05-03 enforcement** — both gates hold cleanly in production. Comments at the call sites cite the gate name so a reader knows the constraint exists; the test files exercise both behaviors. Right shape for invariants that need to survive across PRs.
- **`FrameAttachController.confirmSend` wiring (Track-C 5)** — the dual-handler symmetry between `handleChatSubmit` (line 1451) and `handleChatCancelAndSubmit` (line 1476) is annotated with `WARNING-4 parity with the existing phrase-trigger path` so a future change knows to update both. This is the kind of WHY comment that pays for itself.
- **`@unchecked Sendable` rationales** — every production usage carries a comment explaining the discipline (see `BufferBroadcaster.swift:33-37`, `App/AppDelegate.swift:2050-2052`, `packages/Replay/Sources/Replay/SQLiteConnection.swift:20-23`). This is the right contract for an unsafe escape hatch — opt-in unsafety with a documented invariant.
- **Custom error types per package** — `VoiceError`, `VisionError`, `MemoryError`, `MCPError`, `STTError`, `VADError`, `AudioGraphError` each carry the domain. No `NSError` reach-around. Boundary mapping happens in adapters (`HybridSearchAdapter`, `ForgetFactStoreAdapter` from today's D-2).
- **MARK organization** — long files use `// MARK: -` to navigate. Reading `VoiceController.swift` top-to-bottom is genuinely readable because the marks track sections.
