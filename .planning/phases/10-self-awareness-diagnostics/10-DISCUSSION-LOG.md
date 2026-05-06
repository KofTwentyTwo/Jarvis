# Phase 10: Self-Awareness & Live Diagnostics — Discussion Log

> **Audit trail only.** Do not use as input to planning, research, or execution agents.
> Decisions are captured in `10-CONTEXT.md` — this log preserves the alternatives considered.

**Date:** 2026-05-06
**Phase:** 10-self-awareness-diagnostics
**Mode:** `--auto` (no AskUserQuestion; Claude picked the recommended option for every gray area, single-pass)
**Areas discussed:** Plan structure & sequence, stash salvage policy, MCP tool implementation, system prompt preamble, DevOverlay fix approach, diagnostic menu items, Voice Log window architecture, live-launch verification gate, boundary-gate discipline

---

## Plan structure & sequence

| Option | Description | Selected |
|--------|-------------|----------|
| Single mega-plan | All 10 requirements in one PLAN.md | |
| 4 plans | Foundation + UI + Diagnostics × 2 | |
| **5 plans (foundation → UI)** | Tools, prompt, DevOverlay, menu diagnostics, Voice Log — serial | ✓ |
| 6 plans (one per DIAG + bundled SELF) | Maximally split | |

**Selected:** 5 plans, serial.
**Notes:** SPEC said "4–6 expected"; 5 sits in band, isolates the largest plan (DIAG-01) so its risk doesn't contaminate smaller diagnostics' verification. Foundation-first (MCP tools before prompt, prompt before DevOverlay verification, etc.) so each plan's live-launch verification builds on the previous plan's working surface.

---

## Parallel vs serial execution

| Option | Description | Selected |
|--------|-------------|----------|
| Parallel where possible (waves) | Standard GSD pattern | |
| **Strictly serial** | One plan at a time, no fan-out | ✓ |

**Selected:** Strictly serial.
**Notes:** Today's parallel-agent failure is a recorded blocking anti-pattern in `.continue-here.md`. Phase 10 plans run single-threaded with explicit live verification at each plan boundary. The cost (linear time) is intentional.

---

## `stash@{0}` salvage policy

| Option | Description | Selected |
|--------|-------------|----------|
| `git stash apply` wholesale | Try to reapply, resolve conflicts | |
| **Selective per-plan, file-by-file** | Review each stashed file as a scaffolding input to the relevant plan | ✓ |
| Discard immediately | `git stash drop`, start fresh | |

**Selected:** Selective per-plan.
**Notes:** Stash contains 6 `packages/VoiceLog/` source files + 2 test files + edits to AppDelegate / MenuBarContextMenu / project.yml / pbxproj. Plan 10-05 (Voice Log) reviews `packages/VoiceLog/` files file-by-file; Plan 10-03 (DevOverlay) reviews `DevOverlayBroadcasterIntegrationTests.swift`. Stash is dropped only after Plan 10-05 SUMMARY commits.

---

## MCP self-knowledge tool implementation pattern

| Option | Description | Selected |
|--------|-------------|----------|
| **In-process adapter pattern (Track D-2 analog)** | Mirror `InProcessMemoryAdapters.swift` from commit 707c45b | ✓ |
| New tool-host process | Separately codesigned helper bundle | |
| Bus events | Surface via `BusOutbound` schema change | |

**Selected:** In-process adapter pattern.
**Notes:** Bus would require schema widening (SPEC out-of-scope). Helper bundle adds TCC surface and codesign work for read-only queries that don't need it. In-process matches the existing pattern, keeps the four tool implementations to ~30–80 LOC each.

---

## CoreAudio query model

| Option | Description | Selected |
|--------|-------------|----------|
| **Synchronous** | `AudioObjectGetPropertyData` direct, no actor | ✓ |
| Actor-wrapped async | Hop to a dedicated actor for queries | |

**Selected:** Synchronous.
**Notes:** Tools are invoked off the agent loop; query latency is sub-ms; no shared mutable state. `get_active_audio_route` reads through `AudioGraphOwner` actor because that one IS shared mutable state.

---

## Device list caching

| Option | Description | Selected |
|--------|-------------|----------|
| **No caching, fresh every call** | Hardware can hot-plug between calls | ✓ |
| 30s TTL cache | Save the syscall | |
| Subscribe to CoreAudio property listener | Push-based freshness | |

**Selected:** No caching.
**Notes:** Freshness > performance for read-only diagnostics. Property listener is overkill; a single syscall per call is cheap.

---

## System prompt preamble shape

| Option | Description | Selected |
|--------|-------------|----------|
| **Locked code constant, no tool-list duplication** | One string in code; nudges model to use introspection tools | ✓ |
| External JSON file | Editable without rebuild | |
| Per-tool description aggregation | Generate from tool schemas at boot | |

**Selected:** Locked code constant.
**Notes:** No localization needed; Anthropic API tools array already provides the catalog; preamble stays small for cache eligibility (`CacheHintsEligibilityTests`). External file invites drift between docs and what the model actually sees.

---

## Preamble vs presence enrichment ordering

| Option | Description | Selected |
|--------|-------------|----------|
| Preamble after presence | Single concatenation | |
| **Preamble before presence (two distinct steps)** | Identity is stable; presence is per-turn | ✓ |
| Replace presence with preamble | One-step | |

**Selected:** Preamble before presence, distinct steps.
**Notes:** Preamble is identity-stable and cache-eligible; presence is per-turn. Concatenating in one step would invalidate cache on every presence change. Two steps preserve `cache_control` boundaries.

---

## DevOverlay fix approach

| Option | Description | Selected |
|--------|-------------|----------|
| **Read-only investigation first, surgical diff second** | Two commits per plan 10-03 | ✓ |
| Rewrite DevOverlay broadcaster | Guarantees correctness | |
| Wait for next bug to surface | Fix opportunistically | |

**Selected:** Investigation-first, surgical diff.
**Notes:** Rewrite invites scope creep. Investigation note documents what was actually broken (subscriber not subscribed, teardown too early, `@Published` not driving view, or upstream `streamTruncatedFinal` was the cause). Fix follows.

---

## Diagnostic menu items location

| Option | Description | Selected |
|--------|-------------|----------|
| **`MenuBarContextMenu.swift` Diagnostics submenu** | Existing menu host | ✓ |
| HUD buttons | Visible on the always-on hologram | |
| Hidden hotkey-only | No UI surface | |

**Selected:** Menu bar Diagnostics submenu.
**Notes:** SPEC keeps debug UI off the always-on HUD. Menu bar is already the host for diagnostic-class menu items. Hotkey-only hides the surface from the user (defeats the purpose).

---

## Audio loopback tap

| Option | Description | Selected |
|--------|-------------|----------|
| **Reuse `AudioGraphOwner.subscribe()` (Track B-7 fan-out)** | Existing multi-consumer path | ✓ |
| New `AVAudioEngine` tap | Independent of voice subsystem | |

**Selected:** Reuse `AudioGraphOwner.subscribe()`.
**Notes:** New tap risks colliding with the wake-word DAG. The broadcaster fan-out is exactly what Track B-7 introduced for cases like this.

---

## TTS playback engine

| Option | Description | Selected |
|--------|-------------|----------|
| **Tier-1 `AVSpeechSynthesizer`** | Free, instant, audible | ✓ |
| Tier-2 Orpheus | Better voice character | |

**Selected:** Tier-1.
**Notes:** Tier-2 bring-up is explicitly out of scope (depends on ~6GB weights). Tier-1 is the fastest path to "I heard the phrase" verification.

---

## Voice Log publisher concurrency model

| Option | Description | Selected |
|--------|-------------|----------|
| **Actor + AsyncStream subscribers** | Swift 6 strict concurrency native | ✓ |
| `@MainActor` class with `@Published` | SwiftUI-native | |
| `OSAllocatedUnfairLock` shared array | Lock-based | |

**Selected:** Actor + AsyncStream.
**Notes:** Actor matches the codebase's strict-concurrency convention (BufferBroadcaster, AudioGraphOwner, MemoryStore). `@Published`-on-MainActor would force every voice subsystem to hop to the main actor on each event — too coarse for ≤1 Hz audio level emits.

---

## Voice Log retention policy

| Option | Description | Selected |
|--------|-------------|----------|
| **In-memory, 2000 events FIFO** | SPEC says in-memory only | ✓ |
| Persist across launches | ROADMAP wording suggested this | |
| Unbounded (rely on app restart) | Risk OOM | |

**Selected:** In-memory, 2000 events FIFO.
**Notes:** SPEC.md explicitly says "in-memory only — never writes transcript content to OSLog (T-06-05-03)" and that's authoritative over the earlier ROADMAP wording. Persisting transcripts to disk would conflict with T-06-05-03 and invite a privacy review that hasn't happened.

---

## Voice Log UI host

| Option | Description | Selected |
|--------|-------------|----------|
| **AppKit + `NSHostingView` + SwiftUI body** | Mirror DevOverlay | ✓ |
| WKWebView | New content world | |
| Pure AppKit | No SwiftUI | |

**Selected:** AppKit + NSHostingView.
**Notes:** Avoids widening the WKContentWorld surface (T-09 invariant). SwiftUI body inside `NSHostingView` keeps the view code modern.

---

## RMS rate-limiting site

| Option | Description | Selected |
|--------|-------------|----------|
| **At publisher (drop intermediate samples before send)** | One subscriber doesn't bottleneck others | ✓ |
| Per subscriber | Subscriber-side throttle | |
| At source (audio tap thread) | Earliest possible | |

**Selected:** Publisher-side rate-limit.
**Notes:** Source-side throttle would couple the rate to whatever the wake-word DAG happens to compute. Subscriber-side throttle would hold full-rate samples in memory between drops. Publisher-side is the cleanest choke point.

---

## Live-launch verification format

| Option | Description | Selected |
|--------|-------------|----------|
| **Locked SUMMARY.md "Live Verification" section format** | Relaunch command + observed log + AC match | ✓ |
| Free-form note | Less rigid | |
| Separate VERIFY.md | Extra file per plan | |

**Selected:** Locked section format inside SUMMARY.md.
**Notes:** Free-form notes don't survive review consistency. Separate file invites SUMMARY/VERIFY drift. Locked section in SUMMARY.md gives `/gsd-verify-phase 10` a known schema to validate against.

---

## TCC re-prompt protocol during verification

| Option | Description | Selected |
|--------|-------------|----------|
| **`tccutil reset` before relaunch when touching mic/camera** | Proves explicit-`requestAccess` actually fires | ✓ |
| Trust persisted TCC grant | Faster verification | |
| Run only on a fresh user account | Cleanest but expensive | |

**Selected:** `tccutil reset` before relaunch.
**Notes:** The 2026-05-06 mic gap was exactly "TCC says granted but no prompt was ever shown." Resetting forces the prompt path to re-execute and proves the explicit-`requestAccess` fix from `b92d062` is still load-bearing.

---

## New boundary gate?

| Option | Description | Selected |
|--------|-------------|----------|
| **No new gate — procedural enforcement via SUMMARY format** | Procedure scales with humans, gates with CI | ✓ |
| Add `check-summary-has-live-verification.sh` | Grep gate over SUMMARY files | |
| Require running app under CI | Out of scope for current build infra | |

**Selected:** Procedural.
**Notes:** A grep gate over SUMMARY.md is feasible but premature — the SUMMARY format is locked here for the first time, and a gate would freeze the format prematurely. Revisit if SUMMARY drift recurs across phases.

---

## Claude's Discretion

- Specific event payload field shapes for `voiceStateTransition` and `voiceError` (Sendable + Equatable + render-friendly).
- Whether `get_self_state` includes a git short-sha (cheap → include; expensive → skip).
- Whether the audio loopback diagnostic shows a "Recording…" status (free → show; new HUD surface → skip).
- AppKit filter UI (checkbox group vs segmented control) — pick the simplest idiom.

## Deferred Ideas

- Tier-2 Orpheus TTS bring-up (separate phase).
- `vec0.dylib` bundling + Ollama model pulls (Track D-5/6/7; carry-forward).
- AppDelegate.swift split refactor (P3 from 2026-05-04 audit).
- Bus schema widening (out of scope).
- Voice Log persistence across launches (privacy review needed; not now).
- HUD-surfaced diagnostics buttons (always-on hologram is not the place).
- Memory Log companion to Voice Log (Track D environment work needs to land first).
- Self-state historical timeline (point-in-time only for v1).
- Camera Log window (no recorded need yet).

---

*Discussion log written 2026-05-06; auto-mode single-pass; downstream agents read CONTEXT.md, not this file.*
