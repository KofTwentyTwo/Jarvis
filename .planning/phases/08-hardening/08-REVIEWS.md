---
phase: 8
reviewers: [gemini, qwen3-32b-ollama, gemma4-31b-ollama]
skipped: [claude (running session), codex (no auth), opencode (model missing), cursor (no auth)]
reviewed_at: 2026-04-30T20:29:26Z
plans_reviewed:
  - 08-01-replay-oracle-PLAN.md
  - 08-02-corpora-curation-and-runners-PLAN.md
  - 08-03-live-and-integration-runners-PLAN.md
  - 08-04-checklist-runner-and-shipping-gate-PLAN.md
---

# Cross-AI Plan Review — Phase 8 (Hardening)

Three independent reviewers covered the same prompt: Phase 8 ROADMAP §, CONTEXT (D-01..D-24), all 4 PLAN frontmatter + must_haves blocks, VERIFICATION.md, and the post-verification deferral closeout commits.

Codex / Cursor / OpenCode were unavailable on this host (auth or model-config issues); Claude was skipped because this session is the executing one.

---

## Gemini Review


## Summary
Phase 8 presents a robust, evidence-based strategy for graduating the Jarvis observability stack into a pass/fail shipping gate. The plan's primary strength lies in its "Real Pipeline" philosophy—ensuring that fixtures and replays are exercised through production decoders and orchestrator logic rather than simplified mocks. By decomposing the 8-pillar evaluation matrix into disjoint runners coordinated by a centralized `jarvis-eval` CLI, the team has created a scalable substrate that balances automated regression testing with the pragmatic necessity of manual UAT for hardware-dependent audio paths.

## Strengths
- **Fidelity of Replay Oracle:** The use of a typed `ExclusionList` (D-20) and `DriftClassifier` correctly distinguishes between benign sampling non-determinism and catastrophic logic drift.
- **Security Perimeter Validation:** The injection corpus (D-22/D-23) specifically targets the most vulnerable seams (`.toolResult` and `.mcpHelperOutput`) and includes sophisticated bidi/C0 control attacks.
- **Fixture-First Egress Policy:** Dual-gating live evaluations (D-04) prevents accidental Anthropic token burn and ensures the gate remains fast and deterministic for daily CI.
- **Checklist Mechanization:** Retroactively folding 18 legacy shell scripts into a structured YAML manifest (D-15/D-16) significantly reduces "checklist fatigue" while ensuring architectural invariants are greppable.
- **Empirical Remediation:** The re-verification cycle already identified and fixed a critical latent bug in the `openWakeWord` ORT chain, proving the harness provides immediate ROI.

## Concerns
- **[MEDIUM] Replay State Side-Effects:** The Replay Oracle asserts "byte-equal" output on the bus, but it does not inherently verify side-effects outside the `AgentOrchestrator` (e.g., local file mutations via MCP). If a tool's internal logic regresses but its JSON response remains identical, the oracle may report a false green.
- **[LOW] Wake Hysteresis Bootstrap:** The initial synthetic TTS seed corpus (D-18) is known-weak due to `openWakeWord`'s human-voice training distribution. While this is documented as an operator action, the "Manual" status of the first true FAR/FRR measurement is a slight risk to the initial "Harden" claim.
- **[LOW] lsof Overhead:** While `lsof` is the correct tool for macOS FD detection, running it in a tight 100-cycle loop (D-19) can be heavy. The plan’s built-in 200ms threshold check is a necessary safeguard.

## Suggestions
- **Z-Order Invariant:** Add a `plist_check` or `script` mechanization to the Phase 3 (HUD) checklist to verify the `JarvisHUDPanel` level is set to `.mainMenu` or `.screenSaver` to prevent window occlusion.
- **Non-Deterministic Tool Results:** Ensure `ReplayMCPAdapter` utilizes the same `ExclusionList` logic when comparing tool outputs that might contain ephemeral data (like PID or timestamps) that don't impact the LLM's next turn.
- **Secret Scan Breadth:** Extend the pre-commit secret grep (D-07) to explicitly check for `.replay` and `.evaluation` sqlite files that might accidentally contain sensitive tool results in the `tool_call` table.

## Risk Assessment: LOW
The plan is exceptionally well-aligned with the project's single-machine, personal-use constraints. It provides a high-confidence "shipping gate" without introducing the complexity of enterprise OTel stacks. The decision to accept the Xcode 26 launch fragility as a documented manual workaround is a pragmatic choice that preserves momentum for Phase 8's core mission: ensuring the agent loop remains secure and deterministic.

---

## Qwen3 32B (via Ollama) Review

**Summary**  
Phase 8 delivers a robust shipping gate through a replay oracle (OBS-03) and an 8-pillar evaluation matrix (OBS-04). The plans leverage existing infrastructure (e.g., replay logs, MCP tools) while introducing structured harnessing for regression testing, edge-case validation, and security assertions. Key strengths lie in its deterministic real-pipeline stress testing, empirical drift classification, and integration of pre-existing `scripts/check-*.sh` mechanisms into YAML manifests. The deferred items (e.g., operator-recorded human-voice wake corpus) are well-justified as manual checks, and the risk of accidental API-key leaks is mitigated via pre-commit hooks.

---

**Strengths**  
- **Deterministic Replay Oracle**: Ensures replay logs suppress TTS/HUD dispatch via `TurnSource`, exercises real `LLMProvider` and `MCPToolDispatcher`, and differentiates expected/expected drift with exclusion lists and sampling-aware logic.  
- **Empirical Evaluation Pillars**: All 8 pillars (injection corpus, tool-cap recovery, FD leak detection, wake hysteresis, etc.) are mechanized via targeted runners, leveraging real decoders and production stacks (e.g., Ollama NDJSON, Anthropic SSE).  
- **Security-First Corpus Design**: Inheritance of OWASP LLM01:2025 and bespoke vectors (AppleScript nonces, zero-width chars, memory-extraction attacks) tests perimeter defenses and deep mechanisms like the confirmation broker.  
- **Debt Resolution**: Inherited P6/P7 issues (Xcode 26 Debug fragility, Orpheus TTFA measurement) are explicitly scoped as manual gates, avoiding scope creep while preserving accountability.  
- **YAML-Based Checklist**: Folding existing 18 `scripts/check-*.sh` into typed mechanizations ensures consistency and backward compatibility with older phases' invariants.  

---

**Concerns**  
**LOW/MEDIUM**:  
- **Replay Schema Versioning**: Relying on hardcoded `replaySchemaVersion` may require disciplined re-recording after refactors, which depends on operator diligence.  
- **Live Test Isolation**: `LiveOllamaRunner` depends on Ollama being preconfigured (`OLLAMA_HOST`, model pulling), which could lead to skipped tests if environment setup is inconsistent.  
- **Crash Recovery Performance**: The 50-cycle default (if cycle time >200ms) may miss gradual FD leaks in edge cases where memory pressure isn't constant.  

---

**Suggestions**  
- **Automate YAML Manifest Validation**: Add a `swift test` suite to validate `checklist.yaml` files (e.g., required keys, regex patterns) to prevent misconfigured entries.  
- **Linter for Corpus Items**: Ensure each corpus item has a `category`/`vector` annotation to avoid ambiguous or overlapping test scenarios.  
- **Per-Test Logging**: For runners like `MCPCrashRunner`, emit per-cycle FD leak deltas to help diagnose transient issues rather than relying on summary assertions.  
- **Performance Guards**: Add a `--perf-check` mode to `scripts/shipping-gate.sh` that measures replay session durations, flagging unexpected slowdowns in the pipeline (e.g., database bloat).  

---

**Risk Assessment**: **Low**  
The phase adheres to a "real pipeline, not a simulator" principle, ensuring high confidence that shipping gates align with runtime behavior. Risks are localized to manual steps (e.g., operator voice recording for wake corpus) and depend on existing infrastructure rather than introducing new attack surfaces. The deferred items are explicitly manual and well-documented, reducing the likelihood of accidental regression.

---

## Gemma4 31B (via Ollama) Review

# Cross-AI Plan Review — Phase 8 (Hardening)

## Summary
The Phase 8 implementation plan is exceptionally rigorous. It transforms the project's observability (P4) into a formal shipping gate by constructing a high-fidelity harness (`packages/Harness`) that exercises the **real production pipeline** rather than a simplified simulation. The decomposition into four plans—separating the replay substrate (08-01), the curated corpora (08-02), the integration/live runners (08-03), and the final mechanization of the shipping gate (08-04)—is logically sound and manages dependencies effectively. All success criteria from `ROADMAP.md` (OBS-03, OBS-04) and the specific decision locks (D-01 through D-24) are accounted for.

## Strengths
*   **High-Fidelity Testing**: The use of `.replay` and `.eval` `TurnSource` variants to suppress side-effects (TTS/HUD) while keeping the core orchestrator logic intact ensures that tests are representative of production behavior.
*   **Security-First Injection Corpus**: Adhering to D-22 (focusing on `.toolResult` and `.mcpHelperOutput` rather than just `.userInput`) correctly targets the actual defense boundaries (SEC-06/07) rather than merely testing the harness.
*   **Robust Regression Guards**: The "dual assertion" for tool-cap recovery (zero events + HTTP body inspection) and the `lsof`-based FD leak detection are professional-grade hardening techniques that prevent silent regressions.
*   **Pragmatic "Live" Policy**: The dual-gating of live evaluations (`--live` flag + `JARVIS_LIVE_EVAL=1`) and the strict pre-commit secret scanning defend against accidental API spend and credential leakage.
*   **Comprehensive Mechanization**: Folding the existing 18 `check-*.sh` scripts into the `ChecklistRunner` YAML manifests ensures that no previous architectural invariants are lost during the transition to the new harness.

## Concerns

### MEDIUM: Replay Drift Complexity
The `DriftClassifier` relies on an `exclusion.json` and a `nondeterministicUnderSampling` set. There is a risk that as the model or system prompts evolve, the "expected drift" list becomes bloated, potentially masking legitimate regressions.
*   **Mitigation**: Ensure the `DriftReport` explicitly logs *why* a delta was excluded (e.g., "Field `textDelta` excluded due to `temperature > 0`").

### LOW: Wake-Hysteresis Hardware Variance
As noted in D-18, FAR/FRR are highly dependent on host hardware and environment. While the plan correctly labels the real measurement as a human action, there is a risk that the synthetic seed corpus (TTS clips) provides a false sense of "Pass" before the human recording occurs.
*   **Mitigation**: The shipping gate should clearly distinguish between "Pipeline Functional" (synthetic pass) and "Performance Validated" (human-recorded pass).

## Suggestions
*   **Drift Snapshotting**: In `08-01`, consider adding a "snapshot" command to `jarvis-eval` that allows the operator to mark the current output of a replay as the "new golden baseline" after a planned architectural change, rather than manually editing `exclusions.json`.
*   **Corpus Versioning**: In `08-02`, add a version field to the injection corpus manifest. This allows the `ChecklistRunner` to report which version of the security corpus was exercised, ensuring the "20+ items" requirement is tracked over time.
*   **FD Whitelist Documentation**: In `08-03`, ensure the "steady-state whitelist" for the `FDLeakDetector` is documented within the code, noting specifically which FDs (e.g., standard streams, SQLite WAL) are expected to persist.

## Risk Assessment
**Risk Level: LOW**

The plans are comprehensive and deeply integrated with the existing architecture. The project has correctly identified the "last mile" risks (Xcode 26 launch fragility, API costs, and hardware-dependent voice triggers) and shifted them to `MANUAL` status or operator-driven helpers. The technical approach to the 8-pillar matrix is sound, and the dependency chain (Substrate $\rightarrow$ Corpora/Runners $\rightarrow$ Gate) is optimal.


---

## Consensus Synthesis

### All three reviewers converged on RISK = LOW

Each reviewer independently rated overall risk as LOW. None flagged a HIGH-severity concern. None disputed that OBS-03 + OBS-04 are achieved by the implementation.

### Agreed Strengths (mentioned by 2+ reviewers)

- **Real-pipeline harness, not simulation** — `.replay` / `.evaluation` `TurnSource` suppresses TTS + webview while keeping the production orchestrator intact (Gemini, Qwen3, Gemma4 all called this out).
- **Security-first injection corpus** — `.toolResult` / `.mcpHelperOutput` vectors test SEC-06 + SEC-07 at the actual defense boundary, not the harness perimeter (Qwen3, Gemma4).
- **Tool-cap recovery dual assertion** (D-21) — both event-count AND outbound-body inspection prevents silent regression where `ToolChoice` parameter is dropped from `LLMProvider.stream` (Gemini, Qwen3, Gemma4).
- **lsof-based FD-leak detection** with steady-state whitelist (Gemini, Qwen3).
- **Dual-gating live runs** (`--live` flag + `JARVIS_LIVE_EVAL=1` env var) defends against accidental Anthropic spend (Gemini, Qwen3, Gemma4).
- **Pragmatic deferral classification** — Xcode 26 launch fragility correctly accepted as MANUAL with documented workaround rather than blocking on an upstream issue (Gemini, Gemma4).

### Agreed Concerns (raised by 2+ reviewers)

| Severity | Concern | Reviewers |
|----------|---------|-----------|
| MEDIUM | **Replay-oracle false-green risk** — byte-equal JSON tool responses may pass even if internal MCP-helper side-effects regress; drift classifier exclusion list could grow bloated and silently mask real regressions over time | Gemini, Gemma4 |
| LOW | **Synthetic wake corpus risks "false sense of pass"** — TTS clips score below threshold for both TP and TN; the seed proves only pipeline wiring, not detection accuracy. Shipping gate should clearly distinguish "pipeline functional" from "performance validated" | Gemini, Gemma4 |
| LOW | **Live-runner environment fragility** — `LiveOllamaRunner` depends on operator pre-configuring Ollama daemon + pulled model; misconfigured environment leads to skipped tests rather than failed | Qwen3 |
| LOW | **lsof loop overhead** — 100-cycle MCP crash loop is heavy on macOS; D-19's 200ms threshold mitigates but ought to be measured per host | Gemini, Qwen3 |

### Divergent Views

- **Wake-corpus framing:** Qwen3 treats the synthetic seed as adequate scaffolding; Gemini + Gemma4 want the shipping gate to clearly distinguish "pipeline ok" from "performance ok" so operators don't mistake a synthetic-pass for a real-voice pass. The README addition in commit `fa5da57` partially addresses this; consider adding a distinct "PIPELINE-ONLY" flag to the wake-corpus runner output.
- **Drift bookkeeping:** Gemma4 suggests a `jarvis-eval snapshot` operator command to mark "new golden baseline" after planned architectural changes (replacing manual `exclusions.json` edits). Not in current scope but a clean v1.x addition.

### Suggested Improvements (synthesized, ranked by impact)

1. **Replay-side-effect verification** — extend `ReplayMCPAdapter` to compare not just tool-result JSON but also any explicit "side-effect" markers the helper emits (e.g., file paths it touched). [Gemini]
2. **Wake-pipeline status distinction** — `wake-corpus` output should print `PIPELINE: OK / PERFORMANCE: PENDING (synthetic corpus)` when the seed corpus is in use, vs `PIPELINE: OK / PERFORMANCE: PASS|WARN|FAIL` once the operator-recorded corpus is in place. [Gemini, Gemma4]
3. **Corpus versioning** — add a `manifest_version` field to `Corpora/injection/manifest.json` so the checklist runner can report which corpus version was exercised over time. [Gemma4]
4. **FD whitelist inline doc** — the steady-state FD whitelist in `MCPCrashRunner` should carry inline comments explaining each expected FD (replay-log SQLite, journal, stdin/stdout/stderr) so future contributors don't accidentally tighten it. [Gemma4]
5. **Drift exclusion logging** — `DriftReport` should log *why* a delta was excluded (`field=textDelta reason=samplingNondeterminism temperature=0.7`) so growth of the exclusion set is visible at every gate run. [Gemma4]
6. **HUD z-order checklist** — add a `plist_check` or `script` row to `phase=03-hud/checklist.yaml` verifying `JarvisHUDPanel` window level. [Gemini]
7. **Secret-scan breadth** — extend the D-07 pre-commit grep to scan `.replay` / `.evaluation` SQLite files for accidental key inclusion in `tool_call` rows. [Gemini]

### Bottom line

Phase 8 ships. All three reviewers concur. The remaining work is the previously-documented operator-action items (real-voice wake corpus, P6 UAT gates, Orpheus TTFA) plus the optional improvements above, which are 1.x candidates rather than ship-blockers.

To incorporate any of the suggested improvements into a future plan revision:

```
/gsd-plan-phase 8 --reviews
```

(but at this point Phase 8 is already verified-complete; the suggestions are better routed to a v1.x follow-on phase or an `/gsd-add-todo` capture.)
