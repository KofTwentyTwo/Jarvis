# jarvis-diag

Programmatic test harness for the Jarvis API contract (v1.0).

## What this is

`jarvis-diag` is the codified shape of the harness described in
[`JARVIS-API-TEST-CONTRACT.md`](../../.planning/architecture/JARVIS-API-TEST-CONTRACT.md).
It is the **boundary-level harness** — every scenario drives `JarvisTestHarness` (the
actor in `Sources/JarvisDiag/JarvisTestHarness.swift`) and asserts on Commands /
Events / Queries from the v1.0 surface set, never on substrate internals.

At **Phase 5** (this commit) the package is **type-signatures only**. Every Swift
file in `Sources/JarvisDiag/` is doc-commented with the test-contract scenario IDs
it covers. Method bodies are `fatalError("not implemented — IMPL: <scenario-id>")`.
The package compiles green; tests are empty.

Implementation lands during the migration (M-0 .. M-7) per
`.planning/architecture/JARVIS-API-MIGRATION-PLAN.md`.

## Relation to `packages/Harness/`

`packages/Harness/` is the **substrate-level harness** — `MockLLMProvider`,
`WakeHysteresisRunner`, `MCPCrashRunner`, `AudioGraphRebuildRunner`, fixture corpora,
oracles. These types are still useful: most of them get rehoused as concrete
implementations of `ProviderOverrides` collaborators or as `_inject*` test seam
adapters that `JarvisTestHarness` composes. See REVIEW-TEST-CONTRACT §"Relation to
existing packages/Harness/" for the lift plan.

The new `Tools/jarvis-diag/` is **API-boundary tests**, the `packages/Harness/`
library is **substrate runners** that `jarvis-diag` consumes.

## Harness mode

All test seams (`_injectAudioFrame`, `_forceTCCStatus`, `_forceError`,
`ProviderOverrides`, `setConfirmationDefault`, etc.) are gated by `JARVIS_HARNESS=1`
runtime env (UQ-1 lock). Production launches don't set the var; the gate fails
closed with a typed `HarnessGateClosed` error.

When `JARVIS_HARNESS=1` is set, the host writes to
`~/Library/Application Support/Jarvis-Harness/` so harness runs never touch
production state.

## Transport modes

Per UQ-5, every scenario runs in two modes:

- `.inProcessActor` — direct Swift actor calls
- `.jsonRoundTripWebView` — Commands as JSON, real WKWebView, Events read via `WKScriptMessageHandler`

`ScenarioRunner.run(_:in:)` parametrizes scenarios across both modes by default.
Mode-restricted scenarios (provider-stub-only, transport-only) declare their
restrictions explicitly. See test contract §9.

## Layout

```
Tools/jarvis-diag/
├── Package.swift
├── README.md (this file)
├── Sources/JarvisDiag/
│   ├── JarvisTestHarness.swift   — main actor; surface accessors; test seams
│   ├── ProviderOverrides.swift   — mock LLM / embedder / extractor doubles
│   ├── APIClock.swift            — APIClock protocol; RealClock + ManualClock
│   ├── ErrorInjector.swift       — _forceError plumbing
│   ├── TransportMode.swift       — .inProcessActor | .jsonRoundTripWebView
│   └── Scenarios/
│       ├── ScenarioRunner.swift          — parametric runner
│       ├── B02HistoryThreading.swift     — X-004 + B02-fix
│       ├── B03CameraButton.swift         — Vis-001 + B03-fix
│       ├── B04VoiceLoop.swift            — V-006 + B04-fix
│       ├── B05TTSSynthesize.swift        — X-003 + B05-fix
│       ├── B08ModelParaphrase.swift      — Sf-001 + B08-fix
│       ├── CrossSurfaceVoiceTurn.swift   — X-001
│       ├── CrossSurfaceVisionTurn.swift  — X-002
│       ├── CrossSurfaceMultiTool.swift   — X-005
│       ├── CrossSurfaceProviderSwap.swift — X-006
│       ├── CrossSurfaceTCCRevoke.swift   — X-007
│       └── ReplayRoundtripOracle.swift   — X-008
└── Tests/                                — empty at Phase 5
```

## Building

```bash
cd Tools/jarvis-diag
swift build           # type-check only — bodies are fatalError
swift test            # no tests yet
```
