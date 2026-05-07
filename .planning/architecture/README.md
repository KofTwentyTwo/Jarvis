# `.planning/architecture/` — API design swarm output

The artifacts in this directory are the output of the 6-agent design swarm that ran on 2026-05-07 (synthesis evening + Phases 5/6) following the architectural pivot to API-first.

## Authoritative reading order

For implementation work, load these in order:

1. **`HANDOFF-2026-05-07.md`** — why this swarm exists; the boundary between the bug-fix loop and the API design pivot.
2. **`INVENTORY.md`** — every capability Jarvis exposes today (~190), file:line cited, ALIVE/DEAD/DEFERRED/RETIRED-CANDIDATE classifications.
3. **`JARVIS-API-DESIGN-v0.1.md`** — the API surface (7 surfaces, CQRS framing, TurnID correlation, typed Results, lifecycle).
4. **`JARVIS-API-DESIGN-v0.2.md`** — synthesis delta over v0.1: every critic finding dispositioned (ACCEPT / DEFER / USER-DECISION) plus the locked answers to UQ-1..UQ-5 in §5.
5. **`JARVIS-API-MIGRATION-PLAN.md`** — the canonical execution sequence (M-0..M-7 + B-02 tactical patch).
6. **`JARVIS-API-TEST-CONTRACT.md`** — every harness scenario the migration must keep green.

## The "v1.0 contract" is a triplet, not a single doc

v1.0 = `v0.1` + `v0.2 (with UQ-1..UQ-5 answered)`. There is no `JARVIS-API-DESIGN-v1.0.md` single-doc merge — that is post-migration v1.1 polish. v0.2 is the binding amendment doc. Where v0.1 and v0.2 conflict, **v0.2 wins**.

## Critic reports (substrate for v0.2 synthesis)

These are reference, not contract. They drove the v0.2 amendments:

- **`REVIEW-API-CORRECTNESS.md`** — 21 findings (2 BLOCKING, 5 HIGH).
- **`REVIEW-MIGRATION-RISK.md`** — 19 findings (1 BLOCKING, 7 HIGH); subsystem migration cards consumed by Phase 6.
- **`REVIEW-TEST-CONTRACT.md`** — 16 findings (2 BLOCKING, 5 HIGH); harness shape consumed by Phase 5.

## The skeleton at `Tools/jarvis-diag/`

Phase 5 also produced a Swift Package skeleton at `Tools/jarvis-diag/` containing:

- `JarvisTestHarness` actor signature (transport, clock, providerOverrides, errorInjector, tcc overrides)
- `TransportMode` / `APIClock` / `ProviderOverrides` / `ErrorInjector` type signatures
- 12 scenario files under `Sources/JarvisDiag/Scenarios/` corresponding to test-contract scenario IDs

The skeleton compiles green (`swift build` under `Tools/jarvis-diag/`) — type signatures only, no implementation. M-0 step 3 (per the migration plan) wires the skeleton against the real `packages/JarvisAPI/` types.

## Locked decisions at v1.0 (UQ-1..UQ-5)

Restated for quick reference; full context in `JARVIS-API-DESIGN-v0.2.md §5`.

1. **UQ-1:** Test seams gated at runtime via `JARVIS_HARNESS=1` env at boot. Single binary.
2. **UQ-2:** B-02 (history threading) is a tactical patch outside the M-sequence + regression test for `streamTruncated`. B-04 stays in M-6.
3. **UQ-3:** B-05 is solved by an explicit `Voice.synthesizeTurn(turnId:text:tier:)` command issued by the orchestrator on voice-source `turnEnded(.completed)`.
4. **UQ-4:** Settings owns ALL configuration mutation. Voice retains only runtime-control verbs (`pttDown`, `pttUp`, `cancelTTS`, `synthesizeTurn`). `bargeIn` migrates to Turn.
5. **UQ-5:** Every harness scenario runs in both `.inProcessActor` AND `.jsonRoundTripWebView` modes (parametric runner mandated).

Plus four orchestrator-decided defaults documented in v0.2 §5: identifier types are UUID strings; harness data isolation is `~/Library/Application Support/Jarvis-Harness/`; confirmation auto-approve via `Settings._setConfirmationDefault(.approve | .deny)` defaulting to `.deny`; bus protocol accepts `["2.3.0", "2.4.0-rc"]` during M-0..M-7.

## What happens next

1. **Cross-AI peer review** of the v1.0 contract (GPT-5 Pro / Gemini 2.5 Pro / fresh Opus instance). Likely tomorrow per handoff §"After tonight." Iterate to v1.1 if findings warrant.
2. **B-02 tactical patch** lands on `develop` directly before M-1 starts. Single commit + regression test.
3. **M-0 (pre-migration gates)** lands directly on `develop`. Creates `packages/JarvisAPI/`, lifts `RealWKWebViewIntegrationTests` to a public harness runner, promotes grep gates to behavioral.
4. **M-1 through M-7** each on its own feature branch + PR. Harness gates pre-merge.
5. **v1.0 lock criteria** specified in `JARVIS-API-MIGRATION-PLAN.md §9`.

Total estimated migration: 19–26 engineer-days (~4–5.5 calendar weeks at solo pace).
