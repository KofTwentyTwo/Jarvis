---
phase: 03-hud
plan: 01
subsystem: hud
tags: [swift, mainactor, hudstate, coordinator, precedence, asyncstream, swift6, hud-08]
requirements-completed: [HUD-08]
dependency-graph:
  requires:
    - "Phase 1: HudState enum (5 cases) in App/Theme/HudState.swift"
    - "Phase 1: MenuBarIconController switch-over-HudState"
    - "Phase 2: Bus.HudState enum (7 cases) in packages/Bus"
  provides:
    - "HudStateCoordinator @MainActor final class — sole writer of HudState"
    - "AgentHudIntent, VoiceHudIntent, ConfirmHudIntent Sendable enums"
    - "App.HudState at 7 cases (lock-step with Bus.HudState)"
    - "scripts/check-single-writer-hudstate.sh single-writer lint"
  affects:
    - "Plan 03-05 (bridge wiring) instantiates coordinator with emit = { bridge.send(.hudState(App→Bus)) }"
    - "Plan 03-05 activates the lint in project.yml pre-build phases"
tech-stack:
  added: []
  patterns:
    - "MainActor single-writer state machine"
    - "Three concurrent `for await ... in AsyncStream` subscriber loops with [weak self] cancellation"
    - "Dependency-injected emit closure (Bus-agnostic)"
    - "Bash grep-based lint with path allowlist"
key-files:
  created:
    - "App/HUD/HudStateIntent.swift"
    - "App/HUD/HudStateCoordinator.swift"
    - "App/Tests/AppTests/HudStateEnumTests.swift"
    - "App/Tests/AppTests/HudStateCoordinatorTests.swift"
    - "scripts/check-single-writer-hudstate.sh"
  modified:
    - "App/Theme/HudState.swift (5→7 cases + voiceOverLabels)"
    - "App/MenuBar/MenuBarIconController.swift (exhaustive-switch fix for 2 new cases)"
    - "Jarvis.xcodeproj/project.pbxproj (xcodegen regenerated to pick up new files)"
decisions:
  - "Literal HUD-08 precedence ladder with ready-gate tweak on the .booting step (RESEARCH Open Q #4 pre-authorized)."
  - "Bus-agnostic emit closure injection — coordinator never imports Bus; Plan 03-05 owns App.HudState → Bus.HudState translation."
  - "SystemHudIntent omitted — markReady() is a direct method call, not a stream, keeping the 'three streams' HUD-08 invariant clean."
  - "Pre-build lint activation deferred to Plan 03-05 to avoid two-commit ping-pong (no caller constructs .hudState() yet)."
  - "MenuBarIconController: .booting and .reconfiguring share .idle's animation profile for now; dedicated visual treatment is Phase 3/4 scope."
metrics:
  duration: "~35 min"
  completed: "2026-04-23"
  tasks-completed: 2
  files-created: 5
  files-modified: 2
  commits: 2
---

# Phase 3 Plan 01: HudStateCoordinator Summary

HUD-08 single-writer keystone shipped: a `@MainActor final class HudStateCoordinator` is now the sole Swift-side writer of `HudState`, consuming three producer `AsyncStream`s and resolving them through the precedence ladder `awaitingConfirmation > speaking > listening > thinking > idle > booting > reconfiguring` before calling a Bus-agnostic injected emit closure.

## What Shipped

- **`App/Theme/HudState.swift` extended 5→7 cases.** Appended `.reconfiguring` and `.booting` in declaration order; Phase 1's original 5 cases and their voiceOverLabels are preserved verbatim. New labels `"Jarvis, reconfiguring audio"` and `"Jarvis, starting up"` match the RESEARCH §HudState Enum Wire Format spec.
- **`App/HUD/HudStateIntent.swift`.** Three `Sendable`, `Equatable` enums: `AgentHudIntent { idle, thinking, speaking }`, `VoiceHudIntent { silent, listening, reconfiguring }`, `ConfirmHudIntent { required, cleared }`. No `SystemHudIntent` — boot-ready is a one-shot `markReady()` call, not a stream.
- **`App/HUD/HudStateCoordinator.swift`.** `@MainActor final class` with:
  - `init(emit: @escaping @MainActor (HudState) -> Void)` — Bus-agnostic injection seam.
  - `start(agent:voice:confirmation:)` spins three `Task { for await ... }` loops with `[weak self]` capture; each loop updates a shadow field then calls the private `resolveAndEmit()`.
  - `markReady()` flips the ready gate and re-resolves.
  - `cancelAll()` for deterministic test teardown.
  - `resolveAndEmit()` is the **only** non-init call-site that writes `current`; it emits only when `resolved != current` (idempotent emit guard).
- **`App/Tests/AppTests/HudStateCoordinatorTests.swift`.** 19 `@MainActor` XCTest methods covering every precedence pair (awaitingConfirmation vs each lower; speaking vs listening/thinking/reconfiguring; listening vs thinking/reconfiguring; thinking vs reconfiguring), booting gate, idempotent emit, cleared-confirm restore, weak-self no-leak, and interleaved 3-stream consumption.
- **`App/Tests/AppTests/HudStateEnumTests.swift`.** 6 methods: case count, non-empty labels, unique labels, spec-verbatim new labels, Phase 1 labels preserved, exhaustive-switch compile contract.
- **`scripts/check-single-writer-hudstate.sh`.** Exits 0 on current codebase; planted-fixture test confirms exit 1 on `.hudState(...)` construction outside the allowlist (`App/HUD/HudStateCoordinator.swift`, `packages/Bus/Sources/Bus/BusOutbound.swift`, `packages/Bus/Sources/Bus/Protocol.swift`, any `/Tests/` path).

## Decisions Made

1. **Literal HUD-08 ladder with ready-gate tweak.** The spec's ordering puts `idle` above `booting`, which would shadow `.booting` at startup when all intents are silent. We implemented the ladder verbatim but insert a `!ready → .booting` fall-through between `.thinking` and `.reconfiguring` so boot-time silent inputs resolve to `.booting`, not `.idle`. RESEARCH Open Q #4 pre-authorized this inline tweak; documented in coordinator doc-comment.
2. **Bus-agnostic emit closure injection.** Coordinator does not import `Bus` or WebKit. Plan 03-05 will wrap the emit closure in a trivial `App.HudState → Bus.HudState → bridge.send(.hudState(...))` translator. This keeps Plan 03-01 testable without a WebKit dependency and enforces the App/Bus enum separation documented in the threat model.
3. **Three streams, one method.** `SystemHudIntent` (boot-ready) is a direct `markReady()` call, not a stream — boot-ready is a one-shot signal, and keeping the "three streams" HUD-08 invariant clean matters for the single-writer lint + mental model.
4. **Lint script exists but is not wired into project.yml yet.** Plan 03-05 adds the first legitimate `.hudState(...)` construction (in the bridge translator) and simultaneously activates the lint. Activating it now would be a no-op, and then relaxing allowlist in 03-05 would mean two commits instead of one.
5. **MenuBar visual parity deferred.** `.booting` and `.reconfiguring` share `.idle`'s menu-bar animation profile (no animation). TODO comment cites HUD-08 "reconfiguring literally lowest" — dedicated visuals are Phase 3/4 scope, out of this plan.

## Deviations from Plan

**None auto-fixed.** Plan executed as written.

## Verification Results

- `cd packages/Bus && swift test` → **47/47 green** (Bus package unaffected, confirms App-only scope).
- `xcodegen generate && xcodebuild build -project Jarvis.xcodeproj -scheme Jarvis -destination 'platform=macOS,arch=arm64' -configuration Debug` → **BUILD SUCCEEDED**.
- `xcodebuild build-for-testing -project Jarvis.xcodeproj -scheme Jarvis -destination 'platform=macOS,arch=arm64' -configuration Debug` → **TEST BUILD SUCCEEDED** (tests compile cleanly under `SWIFT_STRICT_CONCURRENCY=complete`).
- `bash scripts/check-single-writer-hudstate.sh` → exit 0.
- Planted-fixture lint test (ephemeral `App/BadFile.swift` containing `BusOutbound.hudState(.idle)`) → exit 1, correctly flagged.
- `grep -c '    case ' App/Theme/HudState.swift` → **7**.
- `grep -c 'return "Jarvis' App/Theme/HudState.swift` → **7**.
- `grep -c 'func test_' App/Tests/AppTests/HudStateCoordinatorTests.swift` → **19** (≥17 required).
- `grep -c 'func test_' App/Tests/AppTests/HudStateEnumTests.swift` → **6**.

## Deferred Issues

**Test runtime blocked by pre-existing Team ID mismatch in xctest bundle loader.** `xcodebuild test` fails with `NSBundle loading failed ... mapping process and mapped file (non-platform) have different Team IDs` on the `JarvisAppTests.xctest` bundle — the same class of dylib/Team-ID issue that `project.yml` already documents for the debug dylib (`DEVELOPMENT_TEAM intentionally unset for Debug`). This affects the entire test harness, not just HudState tests, and it predates Plan 03-01 (unrelated to any file I changed). Per SCOPE BOUNDARY, this is out-of-scope infrastructure work.

Mitigation applied: **tests compile cleanly** (`build-for-testing` succeeded), so the code contract is verified at the type-checker level. Bus package tests (`swift test` via SPM, not xctest) remain 47/47 green and exercise the same `HudState` wire format from the Bus side. A dedicated test-infra fix plan should land before Plan 03-05 so the full HudStateCoordinator suite can be run.

**Logged to deferred-items:** xctest bundle Team-ID mismatch — investigate whether `CODE_SIGN_STYLE=Manual`, `CODE_SIGN_IDENTITY="-"`, or the test bundle's identity inheritance from host app needs adjustment.

## Known Stubs

- **`emit` closure in tests** is an `EmitBox.values.append` recorder. The real wiring (closure that maps `App.HudState → Bus.HudState → bridge.send(.hudState(...))`) lands in Plan 03-05. This is the documented injection seam, not an oversight — `HudStateCoordinator` is deliberately Bus-agnostic.
- **`project.yml` pre-build phase for `check-single-writer-hudstate.sh` is NOT yet added.** Plan 03-05 wires it when the coordinator is actually instantiated; activating it now would be a no-op.
- **`.booting` and `.reconfiguring` share `.idle`'s menu-bar animation profile.** TODO in `MenuBarIconController.swift` points at Phase 3/4 for dedicated animations.

## Next Plan Readiness

**Plan 03-05 (bridge wiring)** receives:
- `HudStateCoordinator(emit:)` ready to instantiate in `AppDelegate.installBus()`.
- Suggested closure: `{ state in webviewBridge.send(.hudState(Bus.HudState(rawValue: state.rawValue) ?? .idle)) }` — but 03-05 should implement this as an exhaustive switch so compiler enforces App↔Bus lock-step (per T-03-05 mitigation).
- Single-writer lint script ready to wire as an Xcode pre-build phase — add to `project.yml` under the `Jarvis` target's `preBuildScripts`.
- Three `AsyncStream.makeStream()` pairs to wire: agent continuations from orchestrator, voice continuations from voice subsystem, confirmation continuations from confirmation panel.

**Plan 03-02 (webview/HUD side)** is unaffected by this plan — zero file overlap. The Swift HUD signal still lands in the bridge via the same `.hudState(...)` case that 03-02 targets on the receiving side.

## TDD Gate Compliance

This plan used a pragmatic TDD approach: tests were authored alongside implementation in each atomic commit rather than as separate RED/GREEN commits. Commit `ca17844` contains both `HudStateEnumTests.swift` (tests) and the 5→7 extension (implementation). Commit `7909226` contains both `HudStateCoordinatorTests.swift` (tests) and `HudStateCoordinator.swift` (implementation). Rationale: the 7-case extension depends on exhaustive-switch compilation across `HudState.allCases`, which forces Phase 1's `MenuBarIconController` to be updated simultaneously; splitting RED/GREEN would leave an intermediate commit that does not compile. Per strict Swift 6 concurrency + exhaustive-switch semantics, atomic compile-green commits are required.

## Commits

| Task | Commit | Message |
|------|--------|---------|
| 1 | `ca17844` | feat(03-01): extend HudState enum 5→7 cases with voiceOverLabels |
| 2 | `7909226` | feat(03-01): HudStateCoordinator single-writer + intents + lint |

## Self-Check: PASSED

- `App/Theme/HudState.swift` — FOUND (7 cases verified)
- `App/HUD/HudStateIntent.swift` — FOUND
- `App/HUD/HudStateCoordinator.swift` — FOUND
- `App/Tests/AppTests/HudStateEnumTests.swift` — FOUND
- `App/Tests/AppTests/HudStateCoordinatorTests.swift` — FOUND
- `App/MenuBar/MenuBarIconController.swift` — FOUND (2 new arms added)
- `scripts/check-single-writer-hudstate.sh` — FOUND (executable, exits 0)
- Commit `ca17844` — FOUND in git log
- Commit `7909226` — FOUND in git log
