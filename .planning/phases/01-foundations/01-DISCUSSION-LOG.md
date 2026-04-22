# Phase 1: Foundations - Discussion Log

> **Audit trail only.** Do not use as input to planning, research, or execution agents.
> Decisions are captured in `01-CONTEXT.md` — this log preserves the alternatives considered.

**Date:** 2026-04-22
**Phase:** 01-foundations
**Areas discussed:** SPM package layout, First-launch onboarding, Menu-bar icon state design, Observability surface

---

## SPM package layout

### Q1: Overall SPM package split — how granular?

| Option | Description | Selected |
|--------|-------------|----------|
| Per-subsystem (recommended) | Several packages matching phase boundaries: Config, Logging, Shell, Bus, LLM, MCP, Voice, Memory. App target is a thin shell. Best isolation; matches roadmap phase boundaries cleanly. | ✓ |
| Coarse-grained (3 packages) | Core (config, logging, utils), Shell (lifecycle + hotkey + menu-bar + panel), and Agent (LLM + MCP later). Grows over time. Less upfront discipline. | |
| Monolithic JarvisCore | Single 'JarvisCore' package for everything non-UI. Simplest. Rebuild cost scales with the codebase. Refactor into smaller packages later if needed. | |
| Minimal — mostly app target | Put almost everything in the app target; peel off packages only when forced to share across targets. Fastest to iterate early. Highest coupling risk. | |

**User's choice:** Per-subsystem
**Notes:** Matches the roadmap's phase boundaries; each phase's module becomes an inspectable artifact.

### Q2: What lives in the app target vs packages?

| Option | Description | Selected |
|--------|-------------|----------|
| Lifecycle + wiring only (recommended) | App target = AppDelegate, @main, menu-bar MenuBarExtra or NSStatusBar, NSPanel, window composition, SwiftUI scenes. Packages hold all logic, protocols, models. | ✓ |
| Lifecycle + Shell | App target also owns hotkey manager, shortcut recorder view, TCC helpers — everything 'shell' stays in the main target. | |
| Minimal app target | App target is pure @main + AppDelegate; even MenuBarExtra/NSPanel wiring lives in a package exposing an 'AppShell' entrypoint. | |

**User's choice:** Lifecycle + wiring only
**Notes:** Rule of thumb — if a file is not mounting a window, starting an actor, or routing a delegate callback, it belongs in a package.

### Q3: Package tests — one target per package, or shared?

| Option | Description | Selected |
|--------|-------------|----------|
| One test target per package (recommended) | Each package defines its own testTarget in Package.swift. Run tests in isolation; failures point at the owning module. Swift-testing (macro-based) or XCTest per package author's choice. | ✓ |
| Single app-level test target | One JarvisTests target in the Xcode project that imports all packages. Simpler setup. Slower feedback loop and weaker module boundaries. | |
| Mix (core packages have their own; thin ones share) | Per-package tests for big packages (LLM, MCP, Memory later); small packages (Config, Logging) share a single app-level test target. | |

**User's choice:** One test target per package
**Notes:** Framework choice (XCTest vs swift-testing) at each package author's discretion; no project-wide mandate.

### Q4: Swift concurrency strictness at package level?

| Option | Description | Selected |
|--------|-------------|----------|
| Strict from day one (recommended) | Every package opts into Swift 6 strict concurrency checking (`.swiftLanguageModes(.v6)` or equivalent). Catches data-race bugs at compile time — critical for the actor-heavy agent loop later. | ✓ |
| Strict in core, relaxed in shell | Packages handling concurrency (Bus, LLM, MCP, Voice) go strict; Shell/Config stay on Swift 5 language mode to avoid @MainActor noise for UI glue. | |
| Relaxed across the board, tighten per-phase | Start on Swift 5 language mode in all packages; flip to strict concurrency as each phase lands. Less upfront friction; risks missing data-races early. | |

**User's choice:** Strict from day one
**Notes:** Load-bearing for P4 (agent loop), P5 (MCP confirmation broker), P6 (TTSEngineActor + barge-in); paying the cost now is cheaper than retrofitting.

---

## First-launch onboarding

### Q1: Overall onboarding style?

| Option | Description | Selected |
|--------|-------------|----------|
| Blocking wizard (recommended) | Borderless transparent window steps through: welcome → API key → hotkey → TCC explainer pages (one per surface) → done. Can't use Jarvis until complete. Native-feeling but enforced. | ✓ |
| Hybrid — required now, optional later | Only blocking step is API key (otherwise nothing works). Hotkey + TCC happen via HUD banners on-demand. User can summon a fallback hotkey or open Jarvis via menu-bar click until they bind one. | |
| HUD banner nags only | App just runs; every missing thing surfaces as a dismissible HUD banner. Most flexible, weakest guarantees, least cinematic. | |
| Menu-bar driven checklist | Menu-bar item reveals a 'setup tasks remaining' list the user clicks through at their own pace. Similar to hybrid but discoverability is menu-bar only. | |

**User's choice:** Blocking wizard
**Notes:** Matches the 'single-user personal project, meant to be lived in' posture; acceptable to enforce setup completion.

### Q2: Ordering within the wizard (API key → hotkey → TCC pages)?

| Option | Description | Selected |
|--------|-------------|----------|
| API key first, hotkey last (recommended) | API key (so text input works at all) → each TCC surface with its explainer + trigger button → hotkey binding last (user has already seen the app; knows what they're binding for). | ✓ |
| Hotkey first | Bind the hotkey as step one so the user experiences 'summon Jarvis' immediately. API key + TCC follow. Risk: first summoning reveals a broken app with no API key. | |
| TCC-heavy first | Trigger all TCC prompts up-front (Input Monitoring, Microphone, Camera, Automation-scaffold). Then API key + hotkey. Accepts the cost of prompting for things not needed until P6/P7. | |

**User's choice:** API key first, hotkey last
**Notes:** Mental model — prove Jarvis can talk, then configure how to summon it.

### Q3: TCC priming strategy during Phase 1?

| Option | Description | Selected |
|--------|-------------|----------|
| Prompt only what Phase 1 actually needs (recommended) | Phase 1 only needs Input Monitoring (for NSEvent global monitor). Microphone / Camera / Automation prompts DO NOT fire in P1. Plumbing + explainer pages exist; prompts stay dormant. | ✓ |
| Eager — prime everything up front | Trigger every TCC prompt during onboarding. One-and-done. Breaks mapping between prompt and feature; reads as intrusive for a personal tool. | |
| Plumbing only, zero prompts in P1 | Build the TCC framework but fire zero actual prompts in P1. Phase 1 ships with no TCC state changes. | |

**User's choice:** Prompt only what Phase 1 actually needs
**Notes:** Preserves the prompt↔feature causal link; aligns with SEC-04 incremental prompting.

### Q4: Wizard retake / re-entry — can the user re-open it later?

| Option | Description | Selected |
|--------|-------------|----------|
| Yes, via menu-bar 'Setup…' item (recommended) | Menu-bar dropdown includes 'Setup…' that re-opens the wizard at step 1. Stateless — wizard reflects current state each time. | ✓ |
| Individual settings pages only | No wizard re-entry. Menu bar exposes 'API Key…', 'Hotkey…', 'Permissions…' each as its own modal or Settings pane. | |
| Both — wizard + individual pages | Full setup wizard available from 'Setup…' AND individual pages from 'Settings…'. More code; more flexibility. Risk of surface divergence. | |

**User's choice:** Yes, via menu-bar 'Setup…' item
**Notes:** Avoids surface divergence; wizard reads current state and resumes at first unresolved step.

---

## Menu-bar icon state design

### Q1: Base icon technique?

| Option | Description | Selected |
|--------|-------------|----------|
| Custom template image (recommended) | Single custom .pdf / .svg asset rendered as NSImage with `isTemplate = true` — auto-adapts to light/dark menubar. Cinematic, on-brand. | ✓ |
| SF Symbols per state | Swap between SF Symbols per state. Zero design work. Breaks custom-HUD aesthetic. | |
| Custom template + SF Symbol overlay | Custom Jarvis ring as base; overlay a small SF Symbol badge per state. Balances brand vs clarity. | |

**User's choice:** Custom template image
**Notes:** Iron-Man arc-reactor silhouette; design can defer to implementation, decision to pursue custom template is locked.

### Q2: How to distinguish the 5 states visually?

| Option | Description | Selected |
|--------|-------------|----------|
| Silhouette constant + subtle animation (recommended) | Base silhouette stays constant; each non-idle state adds a subtle motion: listening = slow pulse, thinking = spinner arc, speaking = outward shimmer, awaitingConfirmation = gentle flash. | ✓ |
| Color tint per state | Requires dropping template mode. Loud; not macOS-idiomatic. | |
| Badge dot in corner | Silhouette is static; a small colored dot / glyph in the corner changes per state. Looks like a notification counter. | |

**User's choice:** Silhouette constant + subtle animation
**Notes:** Transitions crossfade over ~150ms; silhouette never swaps mid-animation.

### Q3: How urgent should `awaitingConfirmation` look?

| Option | Description | Selected |
|--------|-------------|----------|
| Attention-grabbing, not alarming (recommended) | Slow rhythmic glow (~1 Hz) with a small badge indicator. Matches 'user-initiated turns only' posture — asking for consent, not warning of danger. | ✓ |
| High-contrast flash | Faster flash / higher contrast amplitude. Risks feeling like a crashed-app error state. | |
| Sound + subtle visual | Play a short attention tone alongside a subtle glow. Breaks 'quiet ambient presence' posture. | |

**User's choice:** Attention-grabbing, not alarming
**Notes:** No sound; higher brightness amplitude than listening so peripheral vision catches it.

### Q4: Click behavior on the menu-bar icon?

| Option | Description | Selected |
|--------|-------------|----------|
| Left-click = summon / dismiss HUD; right-click = menu (recommended) | Click is the discoverability path alongside the hotkey; right-click gives full menu. Matches macOS conventions. | ✓ |
| Click opens menu; menu has 'Show Jarvis' item | Click always shows the menu — 'Show Jarvis' is the first item. More discoverable menu, less immediate to summon. | |
| Click summons; Option+click shows menu | Default click always summons; menu requires Option modifier. Very keyboard-forward. Hidden menu may confuse future-you. | |

**User's choice:** Left-click = summon / dismiss HUD; right-click = menu
**Notes:** Ensures Jarvis is always findable even if the hotkey is forgotten.

---

## Observability surface

### Q1: Destination for the four structured-log channels?

| Option | Description | Selected |
|--------|-------------|----------|
| File + os.Logger, both always on (recommended) | swift-log wires two handlers: file handler to `~/Library/Logs/Jarvis/{channel}.log` and `os.Logger` subsystem=`com.kingsrook.jarvis` category={channel}. | ✓ |
| File only | Only our own files; no os_log. Loses Console.app live-filtering and system-wide correlation. | |
| os_log only | Only os.Logger, no files. Zero rotation work. Buffer is OS-managed — can lose logs under pressure. | |
| File + os_log, different levels | Files capture debug+; os_log captures info+. Tunes the volume. More moving parts. | |

**User's choice:** File + os.Logger, both always on
**Notes:** Both handlers always active; level per handler configurable via LaunchSnapshot.

### Q2: File log rotation policy?

| Option | Description | Selected |
|--------|-------------|----------|
| Size-triggered, keep last 5 (recommended) | Each channel rotates at ~10 MB; retain last 5. Predictable disk footprint. | |
| Daily rotation, keep 7 days | Rotate at midnight local, keep last week. More natural human-time slicing; harder to bound disk. | ✓ |
| No rotation; single growing file per channel | Append-only, never rotate. Files grow without bound. | |

**User's choice:** Daily rotation, keep 7 days
**Notes:** Human-time slicing chosen over size-based — easier to triage "what happened yesterday afternoon". Disk unbounded on spiky days — accepted for a personal tool.

### Q3: How should first-launch failures surface (missing entitlement, Keychain denied, hotkey-unavailable, Input-Monitoring denied)?

| Option | Description | Selected |
|--------|-------------|----------|
| Severity-tiered: NSAlert for blockers, HUD banner for degraded-mode (recommended) | NSAlert modal for hard-blockers; HUD banner for degraded-mode recoverable states. Matches R4-S2: not silent, not overly-alarming. | ✓ |
| HUD banner for everything | Every first-launch failure is a dismissible HUD banner. Risks users dismissing and forgetting a hard-blocker. | |
| NSAlert for everything | Every failure is a modal. Doesn't match the 'ambient presence' posture. | |
| Menu-bar badge + banner on hover | Menu-bar icon grows a red dot; hover shows description. Minimal; can be missed. | |

**User's choice:** Severity-tiered: NSAlert for blockers, HUD banner for degraded-mode
**Notes:** Structured log only for diagnostic-level issues with automatic fallback.

### Q4: Log redaction policy — what does `redact()` cover beyond the spec minimum?

| Option | Description | Selected |
|--------|-------------|----------|
| Spec minimum only (recommended) | Cover exactly what OBS-06 specifies: API keys, Authorization: Bearer tokens, AKIA*, ghp_*. | ✓ |
| Spec + paths | Also redact absolute paths under /Users/<name>/ to a tilde-prefixed form. | |
| Spec + paths + free-text fields in tool results | Spec + path normalization + elide tool-result content. Over-broad. | |

**User's choice:** Spec minimum only
**Notes:** Single-user-machine threat model; over-redaction hurts P4+ debugging and conflicts with OBS-02 nothing-masked-bytes.

---

## Claude's Discretion

Areas where the user deferred specifics to planner/executor, consistent with the locked decisions:
- Exact asset file format for the template icon (.pdf vs .heic vs .svg).
- Shortcut-recorder implementation approach (hand-rolled SwiftUI view vs vetted SPM like `sindresorhus/KeyboardShortcuts`).
- Precise animation easing curves, frame rates, fade-in/out timings.
- SwiftUI vs AppKit split inside the onboarding wizard.
- Directory layout under `packages/` (flat vs grouped).
- Scaffold-time verification harness mechanic (XCTest vs shell script vs CI job).
- File-handler implementation for log rotation (hand-rolled vs a swift-log backend package).
- `config.json` schema versioning approach.

## Deferred Ideas

Captured in `01-CONTEXT.md` `<deferred>` section. Highlights:
- Exact `config.json` shape beyond the SEC-05 key split.
- Codesign script language/location.
- DevOverlay UI layout (P4 concern, not P1).
- Ambient corner mode (v1.x, explicit Out of Scope).
- Full Settings pane beyond wizard re-entry.
- Telemetry / crash reporting integration.
