---
phase: 03-hud
plan: 01
type: execute
wave: 1
depends_on: []
files_modified:
  - App/Theme/HudState.swift
  - App/HUD/HudStateIntent.swift
  - App/HUD/HudStateCoordinator.swift
  - App/Tests/AppTests/HudStateCoordinatorTests.swift
  - App/Tests/AppTests/HudStateEnumTests.swift
  - scripts/check-single-writer-hudstate.sh
  - project.yml
autonomous: true
requirements: [HUD-08]
tags: [swift, mainactor, hudstate, coordinator, precedence, asyncstream, swift6]

assumptions:
  - "Plan 03-01 runs in Wave 1 parallel with Plan 03-02 (Swift ↔ TS split; zero file overlap)"
  - "Phase 1 shipped `HudState` enum with 5 cases (idle, listening, thinking, speaking, awaitingConfirmation) and voiceOverLabel for each; this plan extends it to 7 with `booting` and `reconfiguring`"
  - "Phase 2 already registered `HudState` in `packages/Bus/Sources/Bus/Protocol.swift` at 7 cases (confirmed via Read of Protocol.swift lines 17-25). App-side `App/Theme/HudState.swift` at 5 cases is the lagging definition — we bring it in line and keep App-side as the UI/voice-over source of truth while `Bus.HudState` stays the wire-format enum."
  - "HUD-08 precedence ladder: `awaitingConfirmation > speaking > listening > thinking > idle > booting > reconfiguring`. `reconfiguring` is literally lowest per RESEARCH Open Q #4 — we implement the ladder verbatim per that recommendation."
  - "Three `for await` subscriber loops (not `swift-async-algorithms` merge) per RESEARCH §Pattern 1 — no new SPM dep for P3"
  - "Bus wiring (constructing the coordinator + connecting it to `webviewBridge.send(.hudState(_:))`) is Plan 03-05's job. This plan ships the coordinator + intents + tests + the single-writer lint in isolation; `HudStateCoordinator` accepts an injected `@MainActor (HudState) -> Void` emit closure (not a hard `WebviewBridge` dep) so tests drive it without WebKit."
  - "No App-side code currently reads `App/Theme/HudState.swift` beyond its enum shape; Phase 1's `MenuBarIconController` iterates over `HudState.allCases` via switch-on-raw-value so adding two cases is a compile-error-forcing extension (verified by `grep -rn HudState App/` — only `MenuBarIconController` and Theme/HudState.swift reference it)."

must_haves:
  truths:
    - "`App/Theme/HudState.swift` has exactly 7 cases in precedence order comment: booting, reconfiguring, idle, thinking, listening, speaking, awaitingConfirmation (declaration order may stay alphabetic; precedence is encoded in HudStateCoordinator, not in case order)"
    - "Every `HudState` case returns a non-empty `voiceOverLabel`; callers (MenuBarIconController) compile without adding `default:` because `HudState` is exhaustive at switch sites"
    - "`HudStateCoordinator` is `@MainActor final class` with exactly one non-test call-site writing to `currentState` — `resolveAndEmit()`"
    - "Three `Task { for await ... }` subscriber loops — one each for AgentHudIntent, VoiceHudIntent, ConfirmHudIntent — are the ONLY ingress paths for state changes; no public setter accepts a `HudState` directly"
    - "Precedence resolver behaves per HUD-08: awaitingConfirm=true dominates; otherwise speaking > listening > thinking > reconfiguring > idle with booting suppressed by markReady()"
    - "`markReady()` transitions out of booting; before markReady() the coordinator emits `.booting` and absorbs inputs (they update shadow fields but don't promote the state above booting)"
    - "Idempotent emit: when resolve(currentInputs) == currentState the emit closure is NOT called (guarded by `guard resolved != current`)"
    - "`scripts/check-single-writer-hudstate.sh` asserts `grep -rn '\\.hudState(' App/ packages/ --include='*.swift'` finds BusOutbound construction ONLY inside `App/HUD/HudStateCoordinator.swift` (plus tests under `Tests/`); failure exits non-zero"
    - "`HudStateCoordinatorTests` covers every precedence pair — 21+ XCTest cases — including booting-dominance-until-markReady, reconfiguring-lowest-when-nothing-higher, and the idempotent-emit invariant"
  artifacts:
    - path: "App/Theme/HudState.swift"
      provides: "HudState enum extended from 5 → 7 cases with voiceOverLabel for each"
      contains: "case booting"
    - path: "App/HUD/HudStateIntent.swift"
      provides: "AgentHudIntent, VoiceHudIntent, ConfirmHudIntent Sendable enums + SystemHudIntent"
      contains: "enum AgentHudIntent"
    - path: "App/HUD/HudStateCoordinator.swift"
      provides: "@MainActor final class with start(agent:voice:confirmation:) + markReady() + precedence resolver"
      contains: "@MainActor\npublic final class HudStateCoordinator"
    - path: "App/Tests/AppTests/HudStateCoordinatorTests.swift"
      provides: "XCTest suite covering precedence matrix, booting gate, idempotent-emit guard"
      contains: "func test_awaitingConfirmationBeatsSpeaking"
    - path: "scripts/check-single-writer-hudstate.sh"
      provides: "Build-time lint rejecting BusOutbound.hudState(_:) calls outside the coordinator"
      contains: "HudStateCoordinator.swift"
  key_links:
    - from: "App/HUD/HudStateCoordinator.swift"
      to: "App/Theme/HudState.swift"
      via: "type usage"
      pattern: "HudState\\."
    - from: "App/HUD/HudStateCoordinator.swift"
      to: "injected `emit: @MainActor (HudState) -> Void`"
      via: "closure call in resolveAndEmit"
      pattern: "emit\\(resolved\\)"
---

<objective>
Ship the Swift-side keystone for Phase 3: a `@MainActor final class HudStateCoordinator` that is the **sole writer of HUD state** per HUD-08, consuming three producer streams (AgentHudIntent, VoiceHudIntent, ConfirmHudIntent) and resolving them through the precedence ladder `awaitingConfirmation > speaking > listening > thinking > idle > booting > reconfiguring` before calling an injected emit closure. Extend `App/Theme/HudState.swift` from 5 → 7 cases in lock-step with the already-landed `Bus.HudState` (Protocol.swift:17-25). Add a ship-blocking lint that prevents any other file from constructing `.hudState(_:)`.

Purpose: HUD-08 is the architectural invariant that prevents the R1 H-A3 "two writers race" — if voice and the orchestrator can both write HUD state directly, a race between "thinking → speaking" and "listening → thinking" can leave the UI stuck. Centralizing into one coordinator with a deterministic precedence ladder makes the merge testable and the failure mode "a subsystem produced the wrong intent" (catchable) rather than "timing bug." The coordinator's emit closure is an injection point so Plan 03-05 can wire it to `WebviewBridge.send(.hudState(_:))` without this plan taking a WebKit dependency.

Output:
- `App/Theme/HudState.swift` at 7 cases (adds `booting`, `reconfiguring` to Phase 1's 5)
- `App/HUD/HudStateIntent.swift` — Sendable intent enums for the three producer subsystems
- `App/HUD/HudStateCoordinator.swift` — the `@MainActor final class` with three `for await` shims + precedence resolver + `markReady()`
- `App/Tests/AppTests/HudStateCoordinatorTests.swift` — ≥21 XCTest methods covering every precedence pair, booting gate, idempotent-emit guard
- `App/Tests/AppTests/HudStateEnumTests.swift` — voiceOverLabel non-empty check, exhaustiveness guard (proves callers can't accidentally switch without all 7)
- `scripts/check-single-writer-hudstate.sh` — single-writer lint; planned Xcode pre-build wiring happens in Plan 03-05 when the coordinator is actually invoked
- `project.yml` — register the lint script as a pre-build phase (commented until Plan 03-05 wires the coordinator; doc-only addition in this plan)
</objective>

<execution_context>
@~/.claude/get-shit-done/workflows/execute-plan.md
@~/.claude/get-shit-done/templates/summary.md
</execution_context>

<context>
@CLAUDE.md
@.planning/PROJECT.md
@.planning/STATE.md
@.planning/ROADMAP.md
@.planning/REQUIREMENTS.md
@.planning/phases/03-hud/03-RESEARCH.md
@.planning/phases/02-bus/02-01-SUMMARY.md
@App/Theme/HudState.swift
@App/HUD/JarvisHUDPanel.swift
@App/MenuBar/MenuBarIconController.swift
@packages/Bus/Sources/Bus/Protocol.swift

<interfaces>
<!-- Extracted from Phase 1 + Phase 2 source. The executor should use these directly. -->

From `packages/Bus/Sources/Bus/Protocol.swift`:
```swift
public enum HudState: String, Codable, Sendable, CaseIterable {
    case idle
    case listening
    case thinking
    case speaking
    case awaitingConfirmation
    case reconfiguring
    case booting
}
```
(Already at 7 cases — the Bus package went there in P2. We bring App/Theme/HudState.swift in line; both enums carry the same name, but App's owns voiceOverLabel for MenuBar/HUD consumption while Bus's is used only for wire encoding. Keep them as two separate types; do NOT collapse to a single typealias. Rationale: the App enum carries UI-spec accessibility labels, which are not a wire-format concern.)

From `packages/Bus/Sources/Bus/BusOutbound.swift`:
```swift
public enum BusOutbound: Equatable, Sendable {
    case hello(version: String)
    case hudState(HudState)            // ← The case HudStateCoordinator emits
    // ...
}
```
`.hudState(_:)` takes `Bus.HudState`, not `App.HudState`. Plan 03-05 will need a trivial bridge (string-rawValue round-trip); Plan 03-01 does NOT import `Bus` — the coordinator takes an injected `@MainActor (App.HudState) -> Void` emit closure, keeping this plan Bus-agnostic.

From `App/Theme/HudState.swift` (current state, 5 cases):
```swift
public enum HudState: String, Sendable, CaseIterable, Equatable {
    case idle
    case listening
    case thinking
    case speaking
    case awaitingConfirmation
    public var voiceOverLabel: String { /* switch self: 5 arms */ }
}
```

From `App/MenuBar/MenuBarIconController.swift` (Phase 1): iterates `HudState.allCases` via `switch` in animation factory; adding two cases forces compile error unless factory adds two new arms. Plan 03-01 includes updating MenuBarIconController to handle the two new cases — preferred behavior: `booting` and `reconfiguring` use the same animation as `idle` (subtle breath, no hard shift). The MenuBarIconController expansion is in-scope for this plan because it's a forced compile-error fix.
</interfaces>
</context>

<tasks>

<task type="auto" tdd="true">
  <name>Task 1: Extend HudState enum from 5 → 7 cases with voiceOverLabel; fix MenuBarIconController exhaustive switches</name>
  <files>App/Theme/HudState.swift, App/Tests/AppTests/HudStateEnumTests.swift, App/MenuBar/MenuBarIconController.swift</files>
  <behavior>
    - Test 1 (HudStateEnumTests.test_allSevenCasesDefined): `HudState.allCases.map(\.rawValue)` equals `["idle","listening","thinking","speaking","awaitingConfirmation","reconfiguring","booting"]` (any order; test uses Set equality).
    - Test 2 (HudStateEnumTests.test_voiceOverLabelNonEmptyForEveryCase): for every `HudState.allCases` element, `voiceOverLabel.isEmpty` is false.
    - Test 3 (HudStateEnumTests.test_voiceOverLabelsAreUnique): `Set(HudState.allCases.map(\.voiceOverLabel)).count == HudState.allCases.count`.
    - Test 4 (HudStateEnumTests.test_bootingAndReconfiguringLabelsMatchSpec): `HudState.booting.voiceOverLabel == "Jarvis, starting up"` and `HudState.reconfiguring.voiceOverLabel == "Jarvis, reconfiguring audio"` (verbatim from RESEARCH §HudState Enum Wire Format).
    - Test 5 (HudStateEnumTests.test_switchOnHudStateIsExhaustive): A closure that exhaustively switches on a `HudState` parameter with no `default:` compiles. (This is a compile-time contract; the test body simply exercises the switch to prove linkage.)
    - Test 6 (existing MenuBarIconControllerTests stays green): MenuBarIconController exposes an animation factory for every HudState — adding booting + reconfiguring must not break existing menu-bar tests. Map both to the same treatment as `.idle` in this plan (subtle breath, no abrupt transition); document in a code comment that the menu-bar visual vocabulary for these two new states is TBD and currently shares idle's profile per HUD-08 precedence ("reconfiguring literally lowest" per RESEARCH Open Q #4).
  </behavior>
  <action>
    1. Extend `App/Theme/HudState.swift` to 7 cases. Preserve declaration order `idle, listening, thinking, speaking, awaitingConfirmation` from Phase 1 and append `reconfiguring, booting` at the end so existing call-site ordering doesn't shift. Add voiceOverLabel arms:
       - `.reconfiguring` → "Jarvis, reconfiguring audio"
       - `.booting` → "Jarvis, starting up"
       Keep the enum `String`-raw-value + `Sendable` + `CaseIterable` + `Equatable` — same conformances as Phase 1. Keep Phase 1's existing 5 case labels and their existing voiceOverLabel strings verbatim.
    2. Create `App/Tests/AppTests/HudStateEnumTests.swift` with the 6 XCTest methods above (all `@MainActor` unnecessary — the enum is value-type, the tests don't touch AppKit).
    3. Update `App/MenuBar/MenuBarIconController.swift` (Phase 1) — find every `switch hudState` arm and add `.reconfiguring` and `.booting` cases. Both map to the same animation frame-table entry as `.idle` for this plan; add `// TODO(Phase 3): dedicated animation; shares .idle profile per HUD-08 "reconfiguring lowest precedence"` comment. This is a forced compile-error fix, NOT scope creep.
    4. Run `cd packages/Bus && swift test` — MUST remain 47/47 green (the `Bus.HudState` enum was already at 7 cases from P2, so this change only affects App-side). Run `xcodegen generate && xcodebuild build -project Jarvis.xcodeproj -scheme Jarvis -destination 'platform=macOS'` to prove the App module compiles with the extended enum.
    Why this specific scope — we CANNOT land `HudStateCoordinator` (Task 2) without the 7-case enum existing, and we CANNOT leave MenuBarIconController with a non-exhaustive switch after enum extension (Swift 6 strict errors). Bundling all three into one task keeps the commit atomic-compilable.
  </action>
  <verify>
    <automated>cd packages/Bus && swift test 2>&amp;1 | tail -5 &amp;&amp; xcodegen generate &amp;&amp; xcodebuild build -project Jarvis.xcodeproj -scheme Jarvis -destination 'platform=macOS,arch=arm64' -configuration Debug 2>&amp;1 | tail -5 &amp;&amp; grep -c 'case ' App/Theme/HudState.swift</automated>
  </verify>
  <done>
    - `App/Theme/HudState.swift` has 7 cases; `grep -c '    case ' App/Theme/HudState.swift` returns 7.
    - `App/Theme/HudState.swift` has 7 arms inside `voiceOverLabel` switch; `grep -c 'return "Jarvis' App/Theme/HudState.swift` returns 7.
    - `App/Tests/AppTests/HudStateEnumTests.swift` exists with 6 test methods.
    - `MenuBarIconController.swift` switch-over-HudState compiles under SWIFT_STRICT_CONCURRENCY=complete with both new cases handled.
    - `xcodebuild build` succeeds.
    - `cd packages/Bus && swift test` returns 47/47 green (proves Bus package unaffected).
  </done>
</task>

<task type="auto" tdd="true">
  <name>Task 2: HudStateCoordinator @MainActor final class + HudStateIntent types + precedence-matrix XCTest coverage + single-writer lint script</name>
  <files>App/HUD/HudStateIntent.swift, App/HUD/HudStateCoordinator.swift, App/Tests/AppTests/HudStateCoordinatorTests.swift, scripts/check-single-writer-hudstate.sh</files>
  <behavior>
    - Test P1 (test_bootingUntilMarkReady): initial state is `.booting`; multiple AgentHudIntent/VoiceHudIntent events BEFORE `markReady()` leave state at `.booting` (emit closure NOT called after initial). After `markReady()`, the last absorbed intents promote the state.
    - Test P2 (test_awaitingConfirmationBeatsSpeaking): with lastAgent=.speaking already applied, confirmation.required flips resolved to `.awaitingConfirmation`.
    - Test P3 (test_awaitingConfirmationBeatsListening): with lastVoice=.listening, confirmation.required flips to `.awaitingConfirmation`.
    - Test P4 (test_awaitingConfirmationBeatsThinking): with lastAgent=.thinking, confirmation.required flips to `.awaitingConfirmation`.
    - Test P5 (test_awaitingConfirmationBeatsReconfiguring): with lastVoice=.reconfiguring, confirmation.required flips to `.awaitingConfirmation`.
    - Test P6 (test_speakingBeatsListening): awaitingConfirm=false; lastAgent=.speaking + lastVoice=.listening → `.speaking`.
    - Test P7 (test_speakingBeatsThinking): same, but thinking instead of listening → `.speaking`.
    - Test P8 (test_speakingBeatsReconfiguring): `.speaking` wins over `.reconfiguring`.
    - Test P9 (test_listeningBeatsThinking): lastVoice=.listening + lastAgent=.thinking → `.listening`.
    - Test P10 (test_listeningBeatsReconfiguring): `.listening` wins over `.reconfiguring`.
    - Test P11 (test_thinkingBeatsReconfiguring): `.thinking` wins over `.reconfiguring`.
    - Test P12 (test_reconfiguringOnlyWhenNothingHigher): only lastVoice=.reconfiguring + lastAgent=.idle + awaitingConfirm=false + ready → `.reconfiguring`.
    - Test P13 (test_idleWhenAllQuietAndReady): all defaults + ready → `.idle`.
    - Test P14 (test_bootingEmittedOnStartBeforeReady): before markReady() the first emit is `.booting`.
    - Test I1 (test_idempotentEmitNoRepeat): consecutive intents that resolve to the same HudState cause emit closure to fire EXACTLY once (not twice).
    - Test I2 (test_clearedConfirmationRestoresLowerState): required→cleared transition restores whatever lastAgent/lastVoice resolved to.
    - Test S1 (test_threeSubscriberLoopsConsumeIndependently): feeding all three AsyncStreams in interleaved order produces the correct final resolved state (drain via `yield + finish`; await `Task { for await ... }` completion).
    - Test S2 (test_weakSelfCaptureDoesNotLeakOnCancel): after cancelling the parent task, the coordinator is deallocated (weak capture verified via `weak var witness`).
    - Test S3 (test_concurrentPubSubRespectsPrecedenceOnMainActor): rapid alternation between agent and voice producers still lands on precedence-correct resolution because MainActor serializes all three for-await loops.
    - Test L1 (lint script): `scripts/check-single-writer-hudstate.sh` exit-codes 0 with current codebase; shell-fixture test ("cat a fake source file containing `BusOutbound.hudState(.idle)` into a temp dir, run script") exits non-zero.
  </behavior>
  <action>
    1. Create `App/HUD/HudStateIntent.swift`. Declare four Sendable enums (no associated values on `confirmation` — it's a toggle):
       ```swift
       public enum AgentHudIntent: Sendable, Equatable {
           case idle
           case thinking
           case speaking
       }

       public enum VoiceHudIntent: Sendable, Equatable {
           case silent
           case listening
           case reconfiguring
       }

       public enum ConfirmHudIntent: Sendable, Equatable {
           case required
           case cleared
       }
       ```
       `SystemHudIntent` is NOT emitted in this plan (markReady() is a direct method call on the coordinator, not a stream — keeps the "three streams" invariant in HUD-08 clean; system boot is a one-shot signal that doesn't need stream semantics).
    2. Create `App/HUD/HudStateCoordinator.swift`. Shape per RESEARCH §Pattern 1 lines 305-395 but with three simplifications:
       (a) Take `emit: @escaping @MainActor (HudState) -> Void` as an init param (NOT a `WebviewBridge`). This is the injection seam — Plan 03-05 will supply a closure that translates `App.HudState → Bus.HudState → webviewBridge.send(.hudState(...))`.
       (b) `start(agent:voice:confirmation:)` takes three `AsyncStream`s. Spin up three `Task { for await ... }` loops inside `start(...)`. Each loop is `[weak self]` to allow deinit on cancel; inside each loop, update the respective shadow field (`lastAgent` / `lastVoice` / `awaitingConfirm`) then call `resolveAndEmit()`.
       (c) `resolveAndEmit()` private method applies the precedence ladder verbatim per HUD-08 ("awaitingConfirmation > speaking > listening > thinking > idle > booting > reconfiguring"). Implementation:
       ```swift
       private func resolveAndEmit() {
           let resolved: HudState
           if awaitingConfirm {
               resolved = .awaitingConfirmation
           } else if case .speaking = lastAgent {
               resolved = .speaking
           } else if case .listening = lastVoice {
               resolved = .listening
           } else if case .thinking = lastAgent {
               resolved = .thinking
           } else if !ready {
               // Booting gate: until markReady(), we pin to .booting regardless of
               // silent/idle inputs. This lets upstream subsystems fire intents
               // during boot without prematurely promoting the HUD off the
               // "starting up" signal.
               resolved = .booting
           } else if case .reconfiguring = lastVoice {
               resolved = .reconfiguring
           } else {
               resolved = .idle
           }
           guard resolved != current else { return }
           current = resolved
           emit(resolved)
       }
       ```
       Note: the ladder as written in HUD-08 ("idle > booting > reconfiguring") puts idle above booting. The RESEARCH §Pattern 1 snippet respects this literally BUT recommends treating `ready==false` as a hard override on everything below awaitingConfirmation/speaking/listening/thinking — otherwise `.idle` would shadow `.booting` at startup with all intents silent, which contradicts the "Jarvis is starting up" UX. We implement the literal HUD-08 ladder but guard `ready` at the boot step (see block above). Record this deviation as a "literal-spec interpretation" in an inline doc comment pointing at RESEARCH Open Q #4 which pre-authorized the inline-tweak.
    3. `markReady()` public method flips `ready=true` then calls `resolveAndEmit()`. Emits current state at time of readiness (typically promotes from `.booting` to `.idle` or whatever is applicable).
    4. Provide `public var currentStateForTests: HudState { current }` — test-only introspection (keep it public for @testable convenience; documented as test seam).
    5. Create `App/Tests/AppTests/HudStateCoordinatorTests.swift` with all 17+ tests above. Use `AsyncStream<T>.makeStream()` pattern + helper `awaitResolve()` that yields control back to the MainActor via `await Task.yield()` so the three for-await loops can drain. Pattern:
       ```swift
       let (agentStream, agentCont) = AsyncStream<AgentHudIntent>.makeStream()
       let (voiceStream, voiceCont) = AsyncStream<VoiceHudIntent>.makeStream()
       let (confirmStream, confirmCont) = AsyncStream<ConfirmHudIntent>.makeStream()
       var emitted: [HudState] = []
       let coord = HudStateCoordinator(emit: { emitted.append($0) })
       coord.start(agent: agentStream, voice: voiceStream, confirmation: confirmStream)
       agentCont.yield(.thinking)
       await awaitResolve() // yields a few ticks so for-await loops advance
       XCTAssertEqual(coord.currentStateForTests, .booting) // booting dominates pre-markReady
       coord.markReady()
       await awaitResolve()
       XCTAssertEqual(coord.currentStateForTests, .thinking)
       ```
       The `emitted` array MUST be `@MainActor` to avoid Swift 6 Sendable errors; use `MainActor.assumeIsolated` in the emit closure if necessary.
    6. Create `scripts/check-single-writer-hudstate.sh`:
       ```bash
       #!/usr/bin/env bash
       set -euo pipefail
       # Single-writer invariant per HUD-08: .hudState(_:) may only be
       # constructed inside HudStateCoordinator.swift. Elsewhere it's either
       # a lint failure or must be explicitly allowlisted.
       HITS=$(grep -rn '\.hudState(' App/ packages/ --include='*.swift' \
           | grep -v '/Tests/' \
           | grep -v 'App/HUD/HudStateCoordinator.swift' \
           | grep -v 'packages/Bus/Sources/Bus/BusOutbound.swift' \
           | grep -v '//' || true)
       # BusOutbound.swift is allowlisted because it DEFINES the case; it
       # doesn't construct it. Tests under /Tests/ are allowlisted because
       # they drive the coordinator directly.
       if [[ -n "$HITS" ]]; then
           echo "HUD-08 violation: BusOutbound.hudState(_:) constructed outside HudStateCoordinator:" >&2
           echo "$HITS" >&2
           exit 1
       fi
       exit 0
       ```
       Make it executable (`chmod +x`). Run locally to confirm exit 0 on the current codebase.
    7. Run all tests: `xcodebuild test -project Jarvis.xcodeproj -scheme Jarvis -destination 'platform=macOS,arch=arm64' -only-testing:JarvisAppTests/HudStateCoordinatorTests -only-testing:JarvisAppTests/HudStateEnumTests`. Also run `cd packages/Bus && swift test` → stays 47/47.
    8. Do NOT wire `project.yml` to run the lint yet — Plan 03-05 handles that when the coordinator is actually being invoked from AppDelegate. Keep the script + its self-test but don't activate the pre-build hook yet (activating it before the bridge is wired would be a no-op). Leave a TODO comment in `scripts/check-single-writer-hudstate.sh`.
    Why pause the pre-build hook activation — Plan 03-05 will add a `BusOutbound.hudState(...)` construction inside the wiring from coordinator emit to bridge send. Activating the lint now and then relaxing the allowlist in Plan 03-05 would be two commits instead of one.
  </action>
  <verify>
    <automated>xcodegen generate &amp;&amp; xcodebuild test -project Jarvis.xcodeproj -scheme Jarvis -destination 'platform=macOS,arch=arm64' -only-testing:JarvisAppTests/HudStateCoordinatorTests -only-testing:JarvisAppTests/HudStateEnumTests 2>&amp;1 | tail -15 &amp;&amp; bash scripts/check-single-writer-hudstate.sh &amp;&amp; grep -c 'func test_' App/Tests/AppTests/HudStateCoordinatorTests.swift</automated>
  </verify>
  <done>
    - `App/HUD/HudStateCoordinator.swift` compiles under SWIFT_STRICT_CONCURRENCY=complete.
    - `HudStateCoordinatorTests` has ≥17 XCTest methods, all green under `xcodebuild test`.
    - `HudStateEnumTests` has 6 methods, all green.
    - `scripts/check-single-writer-hudstate.sh` is executable and exits 0 against the current codebase.
    - Planted-fixture test (manual spot-check): creating a throwaway file containing `BusOutbound.hudState(.idle)` at a non-allowlisted path makes the script exit 1.
    - No change to `project.yml` pre-build phases yet (deferred to Plan 03-05).
  </done>
</task>

</tasks>

<threat_model>
## Trust Boundaries

| Boundary | Description |
|----------|-------------|
| Intent producers → HudStateCoordinator | Each producer (agent, voice, confirmation) is Swift-side and same-process; no untrusted input crosses here. The boundary being protected is the *semantic* single-writer invariant, not a security perimeter. |
| HudStateCoordinator → emit closure | The coordinator is agnostic to what `emit` does; in this plan it's test instrumentation, in Plan 03-05 it becomes `bridge.send(.hudState(...))`. Coordinator never sees the wire format. |
| HudState enum (App) ↔ HudState enum (Bus) | Two same-named types, kept in lock-step by Plan 03-05's bridge closure. Drift risk: App adds a case without Bus — Plan 03-05's bridge must switch exhaustively over `App.HudState`. Caught at compile time in that plan; noted here as a cross-plan contract. |

## STRIDE Threat Register

| Threat ID | Category | Component | Disposition | Mitigation Plan |
|-----------|----------|-----------|-------------|-----------------|
| T-03-01 | Tampering | HudStateCoordinator | mitigate | Only one `emit(resolved)` call-site inside `resolveAndEmit()`. Lint (`scripts/check-single-writer-hudstate.sh`) enforces no other file constructs `BusOutbound.hudState(_:)`. |
| T-03-02 | Repudiation | Precedence ladder | accept | Literal per HUD-08 spec. Inline doc comment explains the `ready`-gate tweak for `.booting` and cites RESEARCH Open Q #4 which pre-approved literal interpretation. |
| T-03-03 | DoS | Three for-await Tasks | mitigate | `[weak self]` capture + cancellation on deinit + test S2 verifies no leak. AsyncStream producers hold continuations; coordinator holds tasks; both drain on parent cancel. |
| T-03-04 | Information disclosure | `currentStateForTests` test seam | accept | Marked `public` for `@testable import` convenience but documented as a test-only accessor. HudState values are not sensitive — they are UX signals the user already sees. |
| T-03-05 | Tampering | HudState enum drift (App vs Bus) | mitigate | Plan 03-05's bridge closure must switch exhaustively over `App.HudState`; compiler enforces lock-step when a case is added on one side but not the other. This plan ensures App side has the 7 cases that Bus already has. |
| T-03-06 | Elevation of Privilege | Direct `bridge.send(.hudState(...))` from orchestrator or voice code | mitigate | `scripts/check-single-writer-hudstate.sh` — lint rejects any `.hudState(...)` construction outside HudStateCoordinator.swift + BusOutbound.swift. Plan 03-05 will activate this in project.yml pre-build phases. |
</threat_model>

<verification>
Phase-gate for Plan 03-01:
1. `xcodegen generate && xcodebuild build -project Jarvis.xcodeproj -scheme Jarvis -destination 'platform=macOS,arch=arm64' -configuration Debug` succeeds.
2. `xcodebuild test -project Jarvis.xcodeproj -scheme Jarvis -destination 'platform=macOS,arch=arm64' -only-testing:JarvisAppTests/HudStateCoordinatorTests -only-testing:JarvisAppTests/HudStateEnumTests` reports zero failures (≥23 total methods).
3. `cd packages/Bus && swift test` stays 47/47 green.
4. `bash scripts/check-single-writer-hudstate.sh` exits 0.
5. `grep -c '    case ' App/Theme/HudState.swift` returns 7.
6. No changes to `App/Resources/webview/`, `webview/`, or `project.yml` beyond documentation comments.
</verification>

<success_criteria>
- HudState enum extended from 5 → 7 cases with deterministic voiceOverLabels.
- HudStateCoordinator is the only Swift-side writer of HUD state, verified by lint + test.
- Precedence ladder (HUD-08) is implemented verbatim with a compile-time-tested `ready` gate for `.booting`.
- ≥17 XCTest methods cover every precedence pair plus the booting gate plus idempotent emit.
- The coordinator is Bus-agnostic (takes an injected emit closure) so Plan 03-05 can wire it without re-architecting.
- Single-writer lint script is executable and exits 0; planned pre-build integration is deferred to Plan 03-05 to avoid two-commit ping-pong.
- Phase 1 MenuBarIconController extension for the two new cases is forced-compile-error-fix scope only (no new animations added; both map to `.idle` profile with a TODO for Phase 3/4 refinement).
</success_criteria>

<output>
After completion, create `.planning/phases/03-hud/03-01-SUMMARY.md` following `@~/.claude/get-shit-done/templates/summary.md`. Include:
- Frontmatter `requirements-completed: [HUD-08]` (HUD-08 is partially complete — coordinator exists; Plan 03-05 finishes by wiring it to bridge + activating the lint in project.yml).
- Decisions: literal precedence interpretation + ready-gate tweak; Bus-agnostic emit closure injection; deferred pre-build lint activation.
- Known stubs: emit closure is a test recorder (real wiring in Plan 03-05); `project.yml` pre-build phase for `check-single-writer-hudstate.sh` is commented out.
- Next plan readiness: Plan 03-05 receives a working `HudStateCoordinator(emit:)` ready to be instantiated in `AppDelegate.installBus()` with `emit` = closure that maps `App.HudState → Bus.HudState → bridge.send(.hudState(...))`.
</output>
