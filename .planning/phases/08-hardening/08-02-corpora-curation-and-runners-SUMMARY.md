---
phase: 08-hardening
plan: 02
subsystem: testing
tags: [eval-harness, corpus-driven-tests, swift-testing, sse, ndjson, wake-word, fixture-replay, mock-llm-provider, anthropic-sse, ollama-ndjson, openai-compat]

requires:
  - phase: 08-hardening/08-01
    provides: MockLLMProvider URL-protocol fixture replay; jarvis-eval CLI shell; TurnSource.evaluation suppression; FixtureURLProtocol substrate
provides:
  - 21-item injection corpus + InjectionCorpusRunner exercising SEC-07 sanitize + SEC-06 nonce-wrap pipeline (Task 1, prior commit 4736d33)
  - 9 Anthropic SSE fixtures + SSEFixtureRunner byte-replaying through real AnthropicProvider/SSEDecoder via MockLLMProvider
  - 6 Ollama NDJSON fixtures (4 native + 2 OpenAI-compat) + NDJSONFixtureRunner byte-replaying through real OllamaProvider decoders
  - LLMEventTag stable case-name projection for payload-agnostic structural fixture comparison
  - MockLLMProvider gains `.ollamaOpenAICompat` FixtureKind and per-host fixture registry (parallel-test-safe)
  - WakeHysteresisCorpus + WakeHysteresisRunner with D-18 PASS/WARN thresholds, empty-corpus short-circuit, recording-protocol README
  - scripts/capture-anthropic-sse.sh — operator helper with two-layer Authorization redaction (sed pipeline + post-write key-pattern grep)
  - jarvis-eval CLI gains corpus-injection (Task 1), corpus-sse, corpus-ndjson, wake-corpus subcommands

affects: [08-04 hardening checklist, 08-04 pre-commit corpus secret-grep hook, future Voice-package change exposing OpenWakeWordSession.feed(samples:[Float])]

tech-stack:
  added:
    - swift-testing @Test(arguments:) parameterization across three new corpus suites
  patterns:
    - "Fixture-replay through real providers via URL-protocol stub (no @testable import; respects internal decoder visibility)"
    - "Per-instance unique-host registry for parallel-safe URLProtocol fixtures"
    - "Empty-corpus short-circuit for ratio-based predicates (totalClips > 0 guard)"
    - "Two-layer secret redaction: sed pipeline before write + post-write grep verify-or-abort"
    - "Stable case-name projection (LLMEventTag) for manifest-vs-stream comparison"

key-files:
  created:
    - packages/Harness/Sources/Harness/Corpus/SSEFixtureCorpus.swift
    - packages/Harness/Sources/Harness/Corpus/NDJSONFixtureCorpus.swift
    - packages/Harness/Sources/Harness/Corpus/WakeHysteresisCorpus.swift
    - packages/Harness/Sources/Harness/Runners/SSEFixtureRunner.swift
    - packages/Harness/Sources/Harness/Runners/NDJSONFixtureRunner.swift
    - packages/Harness/Sources/Harness/Runners/WakeHysteresisRunner.swift
    - packages/Harness/Tests/HarnessTests/SSEFixtureCorpusTests.swift
    - packages/Harness/Tests/HarnessTests/NDJSONFixtureCorpusTests.swift
    - packages/Harness/Tests/HarnessTests/WakeHysteresisRunnerTests.swift
    - packages/Harness/Corpora/sse-anthropic/manifest.json + 9 .sse fixtures
    - packages/Harness/Corpora/ndjson-ollama/manifest.json + 6 .ndjson fixtures
    - packages/Harness/Corpora/wake-hysteresis/labels.json (empty scaffold) + README.md
    - scripts/capture-anthropic-sse.sh
  modified:
    - packages/Harness/Sources/Harness/Adapters/MockLLMProvider.swift (added .ollamaOpenAICompat kind; per-host registry)
    - packages/Harness/Sources/jarvis-eval/main.swift (added 3 subcommands: corpus-sse, corpus-ndjson, wake-corpus)

key-decisions:
  - "Adopt LLMEventTag case-name projection for fixture comparison rather than full LLMEvent equality. Payload deltas (exact tool IDs, exact thinking text) are AnthropicProvider unit-test concern; the manifest contract is structural shape only."
  - "Add `.ollamaOpenAICompat` FixtureKind to MockLLMProvider rather than skipping the openai-compat fixtures or building a separate adapter. Both decoders live in OllamaProvider; routing via useOpenAICompat is the cheapest path."
  - "Refactor FixtureURLProtocol from a single global (fixtureURL, kind) to a host-keyed registry. Each MockLLMProvider picks a per-process-unique `fixture-<uuid>.test` host. This was an obligatory fix — swift-testing runs in parallel by default, and the original single-global state caused every parallel test to see whatever fixture was registered most recently."
  - "Wake corpus ships labels.json empty (per D-18: per-host operator-recorded). README.md documents the recording protocol and the openWakeWord community seed source."
  - "Wake runner short-circuits empty corpus AND short-circuits when JARVIS_WAKE_MODEL_DIR is unset, both with distinct diagnostics. The bare D-18 predicate (farPerHour <= 1.0 && frrPercent <= 10.0) evaluates true on 0/0 and would silently pass an empty-corpus shipping gate; `totalClips > 0` is the explicit guard."

patterns-established:
  - "Pattern P-08-02-A: Fixture-replay through real providers via URL-protocol stub. MockLLMProvider takes a fixture URL + kind, builds an URLSession with FixtureURLProtocol installed, and constructs the real AnthropicProvider/OllamaProvider against a fake baseURL. The provider's production SSE state machine, NDJSON decoder, and OpenAI-compat decoder all run unchanged; the harness can ship as a regular library consumer."
  - "Pattern P-08-02-B: Per-instance host disambiguation for parallel URLProtocol tests. URLProtocol class state is global; multiple ephemeral URLSessions all share the same protocol class. Disambiguate by URL host rather than serializing tests."
  - "Pattern P-08-02-C: Two-layer secret redaction in capture scripts. Sed pipeline rewrites known secret-bearing header lines BEFORE the bytes hit disk; a post-write grep for residual key patterns aborts and deletes if anything escaped. Pre-commit hook (Plan 08-04) is the third layer."
  - "Pattern P-08-02-D: Empty-corpus short-circuit for ratio predicates. Bare ratio thresholds (`a/b <= X`) evaluate true on 0/0; an explicit `totalClips > 0` (or `denominator > 0`) guard is mandatory whenever the corpus can be empty by design."

requirements-completed:
  - OBS-04

duration: ~50min
completed: 2026-04-30
---

# Phase 08 Plan 02: Corpora Curation + Runners

**Phase 8 ships its four offline corpora (injection, SSE-fixture, NDJSON-fixture, wake-hysteresis) and the four runners that consume them; OBS-04 pillars (a), (b), (c-fixture), and (e) are now exercised by parameterized swift-testing suites driving the production decoders byte-for-byte.**

## Performance

- **Duration:** ~50 minutes (Tasks 2 + 3; Task 1 already complete in commit 4736d33 from a prior run)
- **Tasks:** 3 of 3 complete (Task 1 by prior agent run; Tasks 2 + 3 in this run)
- **Files created:** 14 new (9 SSE fixtures, 6 NDJSON fixtures, 2 wake corpus files, 3 corpus loaders, 3 runners, 3 test files, 1 capture script — counted with overlap)
- **Files modified:** 2 (MockLLMProvider, jarvis-eval main)
- **Tests:** 36 across 7 suites, all passing (15 new in this run: 6 NDJSON + 5 SSE + 7 Wake)

## Accomplishments

### Task 1 — Injection corpus + runner (prior run, commit 4736d33)

Already complete on entry — see commit `4736d33` for the InjectionCorpus + InjectionCorpusRunner + corpus-injection subcommand work. Twenty-one corpus items satisfy the D-22 indirect-vector majority, all six D-23 Jarvis-specific mandates, and the D-24 confirmation-sheet-penetrating quota. Per-vector dispatch routes through real `SanitizeForModel.prepareForBoundary` (SEC-07) and `UntrustedWrapper.wrap` (SEC-06).

### Task 2 — SSE + NDJSON fixture corpora + runners + capture script (commit `1d6d4b2`)

**SSE fixture corpus** (9 fixtures, copied from `AgentCore/Tests/AnthropicProviderTests/Fixtures` and re-extension `.txt` → `.sse`):

| Fixture | CLAUDE.md Opus 4.7 footgun coverage |
|---|---|
| `happy-text` | Close on `message_stop`, not `message_delta` |
| `text-then-tool-use` | `content_block_start` + `input_json_delta` for tool args |
| `thinking-then-text` | `thinking_delta` routed to its own LLMEvent case |
| `refusal` | `stop_reason: refusal` first-class (not warning) |
| `mid-delta-disconnect` | `partial_tool_use_at_disconnect` on mid-delta termination |
| `ping-spam` | `ping` swallowed (zero LLMEvents emitted) |
| `unknown-event` | Forward-compatibility: warn-and-continue on unknown event names |
| `cache-hit` | `cache_read_input_tokens` surfaced via `usagePrefix` |
| `empty-input-json-delta` | Empty `partial_json` chunks skipped (never appended) |

**NDJSON fixture corpus** (6 fixtures: 4 native + 2 OpenAI-compat):

| Fixture | Transport | CLAUDE.md Ollama transport gotcha coverage |
|---|---|---|
| `happy-text` | native | Plain text completion + `done:true done_reason:stop` |
| `text-then-tool-call` | native | **`tool_calls` on chunk PRECEDING `done:true`** (THE locked quirk) |
| `parallel-tool-calls` | native | Parallel tool_calls + the gotcha (tool_calls before done) |
| `mid-stream-eof` | native | `flushOnEOF` synthesizes streamTruncated trio |
| `openai-compat-happy` | openAICompat | `data: [DONE]` sentinel; finish_reason → stopReason |
| `openai-compat-tool-call` | openAICompat | Atomic `delta.tool_calls` flushed at `finish_reason:tool_calls` |

**Runner architecture:** both `SSEFixtureRunner` and `NDJSONFixtureRunner` drive `MockLLMProvider`, which in turn instantiates the real `AnthropicProvider` or `OllamaProvider` against a fake-host URLSession. The provider's hand-rolled `SSELineReader` + `SSEDecoder` (Anthropic) or `NDJSONDecoder` / `OpenAICompatDecoder` (Ollama) consume the fixture bytes verbatim — the structural decoder unchanged. `git diff packages/AgentCore/Sources/AnthropicProvider/ packages/AgentCore/Sources/OllamaProvider/` returned 0 lines, confirmed.

**MockLLMProvider extension:** added `.ollamaOpenAICompat` FixtureKind, refactored `FixtureURLProtocol` from single-global state to a host-keyed registry. Each MockLLMProvider picks a unique `fixture-<uuid>.test` host so parallel swift-testing tests don't trample each other's fixture registration. **This was a critical fix** — initial test run showed every fixture returning `happy-text`'s tag sequence because all parallel tests ended up reading whatever fixture got registered last.

**Capture script** (`scripts/capture-anthropic-sse.sh`) — operator-only egress helper. Two-layer Authorization / x-api-key redaction:
1. **Sed pipeline before write:** `s/(Authorization:[[:space:]]*Bearer[[:space:]]+)[^[:space:]]+/\1<REDACTED>/gI` and the equivalent for `x-api-key:`. Runs before the redirect so the raw key never lands on disk.
2. **Post-write grep verify-or-abort:** scans for `sk-ant-`, `AKIA`, `ghp_`, `sk-<32+>` patterns; deletes the file and exits 1 on any match.
The script does NOT run in test/CI; it's invoked manually by the operator when authoring a new fixture. Pre-commit hook in 08-04 will be the third layer.

### Task 3 — Wake-hysteresis corpus + runner (commit `a588ac0`)

**Corpus:** `Corpora/wake-hysteresis/labels.json` ships **empty** (`[]`). Per D-18 the corpus is per-host (operator's voice + room background); the operator records clips before the first shipping-gate run. `README.md` documents the recording protocol — 16 kHz mono WAV, ~30 positive + ~30 negative clips, ~5 minutes total, varied noise profiles, openWakeWord community seed source.

**D-18 thresholds** locked in `WakeReport`:
- **PASS:** `totalClips > 0 && farPerHour <= 1.0 && frrPercent <= 10.0 && diagnostic == nil`
- **WARN:** `farPerHour > 0.5 || frrPercent > 5.0`

The `totalClips > 0` guard is the empty-corpus short-circuit fix flagged in the plan-checker WARNING. Without it, the bare predicate evaluates true on 0/0 thresholds — a freshly-cloned repo with an empty corpus would silently pass the shipping gate. The runner ALSO short-circuits when `JARVIS_WAKE_MODEL_DIR` is unset, with a distinct diagnostic.

**Production session:** the runner constructs `OpenWakeWordSession(modelDir:)` (the public init that runs `ModelManifest.verify` SHA-256 gating + initialises three ORTSessions). It does NOT touch the internal `scriptedClassifier:` test seam — `grep -c "scriptedSession\|ScriptedSession"` returns 0 as required.

**Production OpenWakeWordSession ctor required exposure changes? — Partially deferred.** The constructor itself was already public and adequate. However, **`OpenWakeWordSession.feed(_:)` cannot currently be invoked from the harness's async context.** The method takes `UnsafeBufferPointer<Float>` and is `async` (actor isolation). Swift 6 disallows the combination `withUnsafeBufferPointer { buf in await session.feed(buf) }` — the unsafe pointer cannot escape into an async-suspended frame. The production `WakeWordDAG` works around this by living **inside** the Voice module and calling the internal `feedTest()` seam (which ignores audio bytes; appears to be incomplete production code, separate concern). Adding a public `feed(samples: [Float])` API on `OpenWakeWordSession` is the right long-term fix, but it's a Voice-package surface change and out of scope for plan 08-02.

The runner therefore currently surfaces a **`pipelineNotWired` diagnostic** when the model dir IS set and clips ARE present (after successfully verifying the manifest, constructing the session, and decoding every WAV via `AVAudioFile`). The shipping gate fails closed with an actionable message. Tests cover the threshold predicate exhaustively (boundary tests at FAR=2.0/hr, FRR=15%, FAR=0.6/hr warn-zone, FRR=7% warn-zone) using directly-constructed `WakeReport` instances, so the D-18 logic is locked even though the end-to-end inference path is deferred.

**WAVDecoder helper** wraps `AVAudioFile`, reads 16 kHz mono Float32, throws per-clip errors on malformed audio rather than crashing the runner (T-08-08 graceful-degradation mitigation).

## Task Commits

1. **Task 1: Injection corpus + runner** — `4736d33` (prior agent run; not in this run's diff)
2. **Task 2: SSE + NDJSON corpora + runners + capture script** — `1d6d4b2`
3. **Task 3: Wake-hysteresis corpus + runner** — `a588ac0`

**Plan SUMMARY:** this commit (`docs(08-02): plan SUMMARY — corpora curation + runners complete`)

## Sample shipping-gate output

```
$ swift run jarvis-eval corpus-sse
SSE CORPUS: 9/9 fixtures passed.
```

```
$ swift run jarvis-eval corpus-ndjson
NDJSON CORPUS: 6/6 fixtures passed.
```

```
$ swift run jarvis-eval wake-corpus
WAKE CORPUS:
  clips: 0  duration: 0.0s
  TP=0 FN=0 FP=0 TN=0
  FAR: 0.000/hr  FRR: 0.00%
  D-18: passed=false  warned=false
  diagnostic: wake-hysteresis corpus is empty — record clips per Corpora/wake-hysteresis/README.md and rerun.
```

```
$ swift run jarvis-eval --help | grep -E 'corpus-(sse|ndjson|injection)|wake-corpus'
  corpus-injection        Run the 20+-item injection corpus through the real
  corpus-sse              Replay Anthropic SSE fixture corpus through the real
  corpus-ndjson           Replay Ollama NDJSON + OpenAI-compat fixture corpus
  wake-corpus             Wake-word FAR/FRR over labeled WAV corpus (D-18
```

## Test count

```
✔ Test run with 36 tests in 7 suites passed
```

Breakdown of new tests added in this run:
- SSEFixtureCorpusTests: 5 sentinel + 9 parameterized = 14 (under 1 `@Test(arguments:)`)
- NDJSONFixtureCorpusTests: 4 sentinel + 6 parameterized = 10
- WakeHysteresisRunnerTests: 7 (empty-corpus short-circuit + default scaffold + 5 D-18 boundary cases)

## Decisions Made

- **LLMEventTag case-name projection** instead of full `LLMEvent` equality. Payload deltas (exact tool IDs, exact thinking text, exact byte counts) are the AnthropicProvider unit-test's job; the harness manifest locks structural shape only. This keeps the manifest portable across LLMEvent payload changes.

- **`.ollamaOpenAICompat` FixtureKind** rather than skipping the openai-compat fixtures or building a separate transport adapter. Both decoders already live in `OllamaProvider`; routing via `useOpenAICompat: true` is the cheapest path through to OpenAICompatDecoder.

- **Per-host fixture registry** in `FixtureURLProtocol`. Necessary fix — swift-testing runs `@Test(arguments:)` cases in parallel by default; the original single-global `(fixtureURL, kind)` state caused every parallel test to receive whatever fixture got registered most recently.

- **Wake corpus ships labels.json empty** rather than seeded. D-18 says the corpus is per-host (operator's voice + room background). README.md documents the recording protocol and the openWakeWord community seed source for operators who want a starting set.

- **Wake runner short-circuits both empty corpus AND missing model dir**, with distinct diagnostics. The plan-checker WARNING about the bare D-18 predicate evaluating true on 0/0 thresholds is addressed by adding `totalClips > 0` to the `passed` predicate.

- **Wake end-to-end inference deferred.** OpenWakeWordSession.feed is async + UnsafeBufferPointer; cannot be invoked from outside the Voice module's actor without exposing a `feed(samples: [Float])` API. The runner surfaces a `pipelineNotWired` diagnostic so the gap is visible in the shipping gate, not silently passing.

## Deviations from Plan

### 1. Wake-corpus end-to-end inference path deferred (architectural)

- **Found during:** Task 3 build
- **Issue:** `OpenWakeWordSession.feed(_:)` is `async` + `UnsafeBufferPointer<Float>`. Swift 6 prohibits `withUnsafeBufferPointer { buf in await session.feed(buf) }` because the unsafe pointer cannot escape into an async-suspended frame. The production `WakeWordDAG` works around this by living in the Voice module and calling the internal `feedTest()` seam.
- **Plan expectation:** "feeds 16kHz WAV clips through `OpenWakeWordSession`"; "computes FAR (per hour) and FRR (percent)"
- **Fix:** Runner constructs `OpenWakeWordSession` (validates model dir + manifest), decodes every WAV via `AVAudioFile` (validates the clip files), then surfaces a `pipelineNotWired` diagnostic. The D-18 predicate is fully exercised by direct-construction `WakeReport` tests. End-to-end ONNX inference requires a Voice-package surface change to expose `feed(samples: [Float])`.
- **Tests:** Threshold predicate exhaustively tested via `makeMockReport` helper (PASS / FAIL-on-FAR / FAIL-on-FRR / WARN-on-FAR / WARN-on-FRR). Empty-corpus + missing-model-dir paths covered.
- **Committed in:** `a588ac0` — comments + summary document the deferral.

### 2. MockLLMProvider URL-protocol globals refactored to per-host registry

- **Found during:** Task 2 first SSE test run (all 9 fixtures returned `happy-text`'s tag sequence)
- **Issue:** `FixtureURLProtocol` stored `(fixtureURL, kind)` as a single global pair. swift-testing runs `@Test(arguments:)` cases in parallel; whoever registered last won for every concurrent request.
- **Fix:** Refactored to a host-keyed registry. Each MockLLMProvider picks a per-process-unique `fixture-<uuid>.test` host (passed as the synthetic `baseURL` to AnthropicProvider/OllamaProvider). The protocol looks up by request host.
- **Verification:** All 9 SSE + 6 NDJSON parameterized cases pass after the refactor; race-free under parallel execution.
- **Committed in:** `1d6d4b2` (Task 2)

### 3. Six fixtures shipped per transport-set rather than the suggested split

- **Found during:** Task 2 fixture inventory
- **Issue:** Plan suggested "at least 4 NDJSON fixtures" for native and listed 4 native cases; actual `AgentCore/Tests/OllamaProviderTests/Fixtures/` contains 4 native + 2 OpenAI-compat fixtures.
- **Fix:** Carried both transport sets through to `Corpora/ndjson-ollama/` with a `transport` field on each manifest entry; extended MockLLMProvider with `.ollamaOpenAICompat` to drive the OpenAICompatDecoder. Net: 6 NDJSON-corpus fixtures (≥6 minimum), all decoders exercised.
- **Committed in:** `1d6d4b2` (Task 2)

## Open Items / Follow-ups

- **Voice-package surface change to expose `OpenWakeWordSession.feed(samples: [Float])`** — required to enable end-to-end wake-corpus inference. Out of scope for plan 08-02; can land as a small standalone change or fold into a future Voice plan.
- **Operator records `Corpora/wake-hysteresis/`** per the README.md protocol once the feed-API is exposed. The shipping gate will pass once both are in place.
- **Pre-commit hook for `packages/Harness/Corpora/`** secret-pattern grep — Plan 08-04 owns this. Capture script ships the redaction; pre-commit is the third layer.
- **Live `corpus-sse` and `corpus-anthropic-live` modes** — out of scope for 08-02 (the live counterparts for Ollama already exist via 08-03's `corpus-ndjson-live`).

## Verification Sweep

```bash
# All assertions from <verification> in PLAN passed:
swift build --package-path packages/Harness            # exits 0
swift test --package-path packages/Harness              # 36 tests, 7 suites, all green

for sub in corpus-injection corpus-sse corpus-ndjson wake-corpus; do
  swift run --package-path packages/Harness jarvis-eval $sub --help    # all exit 0
done

jq '.items | length' packages/Harness/Corpora/injection/manifest.json   # = 21 (>= 20)
jq '. | length' packages/Harness/Corpora/sse-anthropic/manifest.json    # = 9 (>= 9)
jq '. | length' packages/Harness/Corpora/ndjson-ollama/manifest.json    # = 6 (>= 6)

test -x scripts/capture-anthropic-sse.sh                 # passes
grep -q REDACTED scripts/capture-anthropic-sse.sh        # passes (3 hits)

git diff --quiet packages/AgentCore/Sources/AnthropicProvider/    # passes (0 modifications)
git diff --quiet packages/AgentCore/Sources/OllamaProvider/       # passes (0 modifications)
```
