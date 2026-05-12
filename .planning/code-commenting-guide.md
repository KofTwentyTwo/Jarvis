# Jarvis Code-Commenting Style Guide

Status: normative (binding for all new code; opportunistic for legacy).
Authority: project-level. Supersedes ad-hoc per-file conventions where they conflict.
Date: 2026-05-12. Author: research pass during the audit-and-stabilize window.

This guide exists because Jarvis has explicitly chosen **in-code documentation over
external markdown**: no ARCHITECTURE.md, no ONBOARDING.md, no "/docs that go stale
the day after they're written." The code teaches itself or it doesn't get taught.
This document is about the code's documentation — it is not documentation *of* the
code, so it is allowed to live outside source files.

The adversarial benchmark a comment must pass: **a developer joining the project
tomorrow must be able to read any one file and understand WHY each non-obvious line
exists, without opening a Plan ledger, a PR description, or another file.**

---

## 1. Principles

Five rules. Memorize these. Everything below is application.

1. **Lead with the why, not the audit trail.** A comment that opens with `Plan 10-02c
   (B-01b): self.inProcessToolRegistry is now eagerly default-initialized…` teaches
   a new dev nothing until they look up Plan 10-02c. Open with the user-visible
   reason; put Plan IDs in parentheses at the end. *Rationale: git log is the audit
   trail; comments are for present-tense humans.*

2. **Comments answer "why," not "what."** Swift's type system, signature, and name
   already explain *what*. Comments earn their bytes by explaining *why this is the
   way it is* — concurrency invariants, hidden constraints, workarounds for SDK
   bugs, the failure mode this guards against. *Rationale: Clean Code's honest
   middle — duplicating the code in English is rot waiting to happen; encoding
   non-obvious constraints is paying for itself every read.*

3. **Every public declaration gets a `///` docstring.** Per Apple's Swift API Design
   Guidelines: *"Write a documentation comment for every declaration."* Internal
   helpers that fit on one screen and have a self-evident name are exempt; everything
   else is not. *Rationale: a developer should never have to grep for usages to learn
   what a public method does.*

4. **Comment rot is a bug. Treat it like one.** When you change the line, you own
   the comment above it. If the comment is no longer true, fix or delete it in the
   same diff. The boundary gate scripts enforce architectural invariants; treat
   stale comments as the same kind of invariant violation. *Rationale: a wrong
   comment is strictly worse than no comment — it actively misleads.*

5. **Concurrency invariants are sacred. Document them at the type level.** Actor
   isolation, MainActor confinement, single-writer gates, lifetime contracts — these
   are the failure modes that bite hardest in Swift 6 strict-concurrency land, and
   they cannot be derived from the signature alone. If the type has one, the
   docstring states it under `## Threading`. *Rationale: actor`@MainActor`, `Sendable`
   conformance, and `nonisolated` markers are necessary but not sufficient; the
   reader still needs to know who calls whom and on which executor.*

---

## 2. The Five Comment Shapes

### Shape 1 — File-level header

**Purpose.** Tell a reader who opens the file cold (a) what's in this file, (b) what
role it plays in the larger system, (c) where to look next.

**Good (real, from Jarvis: `packages/MCP/Sources/MCP/MCPClient.swift:1–13`).**
The current header is actually competent — it tells you the role, hosts which actor,
how restart mutexing layers, and which Plan introduced what:

```swift
// MCPClient.swift
//
// Top-level facade over the JarvisMCP layer. Hosts the registry of
// `MCPServerHandle` actors keyed by server name and the tool→server lookup
// table built from each helper's `tools/list` response. Plan 05-04 will wrap
// this into a concrete `ToolDispatcher`; for now MCPClient is consumed
// directly by 05-02 (helpers) and 05-04 (sanitize pipeline).
//
// The per-server restart mutex lives in `callTool` and is layered on top of
// each handle's `restartTask: Task<Void, Error>?` slot — concurrent callers
// awaiting a crashed helper share one in-flight restart instead of stampeding.
//
// Plan: 05-01
```

**Good (industry, swift-log `Sources/Logging/Logger.swift:1–14`).** Apple uses a
license banner for OSS attribution; Jarvis is private/personal so we skip that, but
the **standardized block** pattern carries over — fixed location, fixed shape, easy
to skim. Our equivalent is the four-section pattern above: name, role, key
invariant, audit reference.

**Bad (real, from Jarvis: `packages/Memory/Package.swift:7–9`).**
```swift
// D-5/D-6 closure (2026-05-11): SQLite and sqlite-vec are now statically
// linked via …
```
This is fine *as a changelog entry*, but it's the first thing a new dev reads in
the file. They have no idea what D-5/D-6 are. The audit reference should be a
suffix, not the lede.

**Rewritten.**
```swift
// Memory package — SQLite + sqlite-vec storage for conversational memory.
//
// Vec0 (the sqlite-vec extension) is statically linked into a `CSQLiteVec`
// system module rather than dlopen'd at runtime. This eliminates the
// dylib-not-found failure mode that haunted Round 4 and lets MemoryStore
// fail hard at boot instead of degrading silently mid-conversation.
// (audit trail: D-5/D-6 closure, 2026-05-11.)
```

**Header template (recommended for every Swift source file >100 LOC):**
```swift
// <Filename>.swift
//
// <One-paragraph role: what this file owns, where it sits in the system.>
//
// <Optional invariant paragraph: the constraint that's NOT obvious from the
// type signatures — concurrency, ordering, single-writer rule, etc.>
//
// See also: <related files this one collaborates with>
// (audit trail: <Plan ID(s) / phase(s) where relevant>)
```

Short utility files (<100 LOC, one or two trivial types) can skip the header if
every type has its own `///` docstring.

---

### Shape 2 — Type-level `///` docstring

**Purpose.** The first thing a `cmd-click` / `jump-to-definition` shows. Must
answer: what does this type represent, who owns it, what invariants does it carry,
where do I look next.

**Good (real, from Jarvis: `packages/Bus/Sources/Bus/WebviewBridge.swift:6–28`).**
This is the gold standard the rest of the codebase should aspire to:

```swift
/// Main-actor-bound bridge between Swift and the webview's JS layer.
///
/// Responsibilities:
/// - Install a `WKScriptMessageHandlerWithReply` in an isolated content world
///   (`JarvisBusWorld`) so page scripts cannot observe or post to it.
/// - Inject a `WKUserScript` at `.atDocumentStart` in the same world so
///   `window.jarvisBus` exists before any page script runs (pitfall 3).
/// …
///
/// This class is `@MainActor` because WebKit APIs demand main-thread calls
/// and `WKScriptMessage.body` must be read on main. The
/// `WKScriptMessageHandlerWithReply` protocol method itself is marked
/// `nonisolated` by the SDK, so the protocol method hops back onto the main
/// actor via `MainActor.assumeIsolated` — the recommended Swift 6 workaround
/// from Apple DevForums 751086 (FB13774556).
@MainActor
public final class WebviewBridge: NSObject {
```

This passes the benchmark: a new dev reads this docstring and knows the role
(bridge), the responsibilities (5 bullets), the threading rule (`@MainActor` and
why), and the workaround citation (DevForums 751086). Nothing left to grep for.

**Good (industry, swift-nio `EventLoop.swift:196–210`).** Apple's style is
denser-but-narrower — one summary sentence then a discussion paragraph:

```swift
/// An EventLoop processes IO / tasks in an endless loop for `Channel`s until
/// it's closed.
///
/// Usually multiple `Channel`s share the same `EventLoop` for processing IO /
/// tasks…
```

**Bad (real, from Jarvis: AppDelegate.swift:1464–1468 — the user's motivating
example).**
```swift
// Plan 10-02c (B-01b): self.inProcessToolRegistry is now eagerly
// default-initialized at property declaration so installMCP can
// hand the SAME instance to MCPRuntimeWiring.build for the dispatch
// routing composite. Memory tools register INTO the existing
// registry rather than into a fresh one constructed here.
let registry = self.inProcessToolRegistry ?? InProcessToolRegistry()
```

Four problems: (1) lede is "Plan 10-02c (B-01b)" — meaningless to a new reader;
(2) it's a diff-log ("is now"), past tense relative to a state change the reader
doesn't know happened; (3) it's `//` inline when the *type* needs the invariant —
the relationship between `installMCP` and `installMemory` sharing one registry
should live on the property declaration; (4) it explains *what changed* rather
than *why the property exists*.

**Rewritten.**
```swift
/// Shared in-process tool registry. Lives on the delegate so `installMCP` and
/// `installMemory` can both register tools into the same instance — the
/// dispatch routing composite consults it during agent loops and would
/// silently miss tools registered into a sibling instance.
///
/// Eagerly default-initialized at declaration (never `nil` after the
/// delegate is constructed) so installation order between `installMCP` and
/// `installMemory` does not matter.
///
/// (audit trail: Plan 10-02c / B-01b — dispatch routing bug; before this,
/// `installMemory` was building a second registry that the orchestrator
/// never saw.)
private var inProcessToolRegistry: InProcessToolRegistry? = InProcessToolRegistry()
```

The Plan ID is preserved — anyone who needs to dig finds it. But the new dev
learns *why* the property exists, not what code-shape transition produced it.

---

### Shape 3 — Method / property `///` docstring

**Purpose.** Document the contract: what does it do, what does it accept, what does
it return, what does it throw, what's the failure mode, what are the side effects.

**Apple's rule (from the Swift API Design Guidelines):** begin with a summary
sentence in active voice describing what the entity does ("Inserts `x` at…",
"Returns the …"), then use `- Parameters:`, `- Returns:`, `- Throws:` callouts in
that order.

**Good (real, from Jarvis: `packages/MCP/Sources/MCP/MCPClient.swift:113–116`).**
Single-purpose, opens with the verb, calls out the threading layer:

```swift
/// Dispatch a single tool call. Layers the per-server restart mutex on top
/// of the handle's `restartTask` slot:
///
///   1. If a restart is already in flight for this server, await it.
///   2. Else if the handle is crashed, atomically claim-or-share the slot
///      via `MCPServerHandle.claimOrShareRestart`. The claimant runs…
```

**Bad (synthetic, but typical of the Jarvis legacy corpus):**
```swift
/// Submit a turn.
public func submit(_ input: TurnInput) async -> SubmitResult { … }
```
This is no better than no docstring. The signature already says "submit a turn."
The reader needs to know: what does it return on the happy path; what does
`.turnInFlight` actually mean; can this throw; does it block.

**Rewritten (matches `AgentOrchestrator.submit` reality):**
```swift
/// Start a fresh agent turn.
///
/// Allocates a new `TurnID` + `TurnNonce`, reads `PerTurnSnapshot`,
/// resolves the provider via the injected factory, and spawns the turn
/// `Task`. Returns immediately; the turn drives itself via `OrchestratorEvent`
/// and only blocks the caller for the synchronous setup phase.
///
/// - Parameter input: the user message, optionally with attached images.
/// - Returns: `.accepted(turnId:)` on success, `.turnInFlight(currentId:)`
///   if a prior turn is still streaming (use `cancelAndSubmit` for barge-in).
///   `submit` is never `async throws` — provider/replay failures surface
///   through the turn's event stream as `.error`, not the return value.
///
/// SEC-06: the `TurnNonce` is persisted to the replay log but is never
/// emitted on `OrchestratorEvent`. Callers cannot observe it.
```

**The Google rule on overrides:** *"overrides need not always be documented."*
Apply this. An overridden method whose contract is identical to its protocol can
be left without a docstring; the protocol's docstring is canonical.

---

### Shape 4 — Inline `//` comments

**Purpose.** This is where the failure modes live. Inline comments should appear
**only** when the why-is-non-obvious threshold is met: a workaround, a hidden
constraint, a concurrency invariant, a project-specific gotcha that won't be
obvious from the surrounding three lines.

**Good (real, from Jarvis:
`packages/AgentCore/Sources/AgentOrchestrator/OrchestratorEventBroadcaster.swift:160–164`).**
This is the *correct* use of a Plan ID — it leads with what the rule does
("only `.tokenDelta` / `.thinkingDelta` are drop-eligible") and explains *why*
("Bus forwarder shares the rule — OutboundBatcher coalesces tokens at ~30 Hz, so
tail-dropping individual deltas under extreme overload is preferable to
back-pressuring the orchestrator"):

```swift
// D-07 / Phase E (BLOCKER-INT-2): only .tokenDelta /
// .thinkingDelta are drop-eligible. Bus forwarder shares
// the rule — OutboundBatcher coalesces tokens at ~30 Hz,
// so tail-dropping individual deltas under extreme overload
// is preferable to back-pressuring the orchestrator.
```

This is on the line. It would be even better if the audit-IDs moved to a
parenthetical at the end, but the content already passes the benchmark — a new dev
understands *why* this branch exists.

**Bad (real, from Jarvis: `packages/AgentCore/Sources/AgentOrchestrator/AgentOrchestrator.swift:306–307`).**
```swift
// Plan 10-02 disambiguation: qualify with `JarvisVision.` because
// …
```
Plan 10-02 is the lede. The reader has to translate "disambiguation" into
"namespace collision" themselves. The rewrite:

```swift
// Qualify with `JarvisVision.VisionRouter` rather than the bare type because
// `AgentCore` re-exports a `VisionRouter` protocol with the same name; the
// compiler picks the wrong one in this file's import graph.
// (Plan 10-02.)
```

**What does NOT earn an inline comment:**

- Code whose meaning is plain from the line itself.
  - Bad: `i += 1  // increment i`
- Standard Swift idioms (`guard let x = optional else { return }`, `defer { … }`).
- Property mutations whose intent is in the property's own docstring.
- Anything answerable by `cmd-click` / jump-to-definition.

When in doubt, ask: *would deleting this comment make the file harder to maintain?*
If no, delete the comment.

---

### Shape 5 — `// MARK: -` section dividers

**Purpose.** Pure navigation. They show up in Xcode's jump bar and let a reader
skim a long file.

**Good (real, from Jarvis: `WebviewBridge.swift:47, 55, 61, 75, 81`).** Plain,
short, hyphenated for the divider line:

```swift
// MARK: - Configuration
// MARK: - Codecs
// MARK: - Public hooks
// MARK: - State
// MARK: - Init
```

**Bad.** Don't include Plan IDs in MARKs — they're navigation labels, not history:

```swift
// MARK: - B-02 history threading   // <- bad; B-02 is the audit trail, not the section name
```

**Rewritten.**
```swift
// MARK: - Prior-turn history
```
The audit reference goes on the `typealias` / property docstring inside the section.

**Use a MARK divider when the file is >150 LOC** and has at least 3 logical
sections. Files shorter than that don't benefit; MARKs add visual noise without
helping navigation.

---

## 3. Audit Trails — How to Reference Plan IDs, Audits, PRs

Plan IDs (`Plan 10-02c`, `B-01b`), audit references (`audit-2026-05-04 P2-15`,
`Round 4`), and PR/issue links are valuable. They preserve the lookup path back to
the discussion that produced the code. They are not, however, the lede.

**The rule:** audit references are **parenthetical suffixes** at the end of a
paragraph or as a standalone bracketed tail. The descriptive prose comes first;
the audit ID comes last.

**Three accepted forms:**

1. **Trailing parenthetical** (preferred):
   ```swift
   /// Shared registry across `installMCP` and `installMemory` — registering tools
   /// into a fresh sibling instance would silently strand them off the
   /// orchestrator's dispatch path. (audit trail: Plan 10-02c / B-01b.)
   ```

2. **Trailing line, separated by blank line** (long history / multiple plans):
   ```swift
   /// VAD hangover threshold. 5 chunks ≈ 160 ms; tuned empirically against
   /// the audit-2026-05-04 fast-finalize corpus to avoid cutting users off
   /// mid-sentence.
   ///
   /// (audit trail: Plan 06-03 / VOICE-04; tuned in P1-3, audit-2026-05-04.)
   ```

3. **Inline parenthetical mid-sentence** (when one ID identifies the whole
   rationale):
   ```swift
   // Don't log raw memory content (P2-6, security MEDIUM-1) — extraction
   // text can contain PII even after sanitization.
   ```

**The rule applied to inline `//` comments:** if your entire comment is a
Plan ID, you have not written a comment. You have written a TODO without the
word TODO. Fix or delete:

- ❌ `// Plan 09-02 cascade`
- ✅ `// JarvisVision moved to platform v14, so this module follows. (Plan 09-02 cascade.)`

**Grep gate.** A lightweight CI check that warns on Plan-ID-only comments — i.e., a
comment block whose entire content matches `^//\s*(Plan|B-|D-|P[0-9]|S-|T-)[A-Za-z0-9-]*\s*$`
or a `///` block whose body is shorter than its Plan reference. Add this as
`scripts/check-no-stale-plan-id-comments.sh`. Failure mode is warn-not-fail at
first; promote to fail after a migration pass clears the legacy hits.

---

## 4. What NOT to Comment

The codebase already over-comments certain shapes. The rule is: if the comment
duplicates information the reader can get from the line itself or one
`cmd-click`, delete it.

- **Self-evident public-API surface.** `public init(label: String)` does not need
  `/// Constructs with a label.` (Apple's swift-log violates this rule because it
  takes the "every declaration" line absolutely — Jarvis applies the rule
  pragmatically: every *non-trivial* declaration.)
- **Type-checked things.** `// returns a String` next to `-> String` is noise.
- **Idioms.** `// guard against nil` next to a `guard let` is noise.
- **Changelogs.** Don't write "TODO(2026-04-12 jmaes): this used to call X but now
  calls Y." That's a git log entry, not a comment. The current behavior is what
  matters.
- **Dead-letter sections.** Don't keep `// REMOVED: …` blocks. Delete the code,
  delete the comment; `git log -S` finds the prior version.
- **Test file boilerplate.** Most test methods have self-evident names
  (`testStreamingTokensArriveBeforeMessageStop`); a docstring repeating the name
  is filler. Reserve test docstrings for the unusual cases (regression tests
  pinned to a specific bug).

---

## 5. Concurrency / Actor / Single-Writer Invariants

Jarvis runs under Swift 6 strict concurrency. The most expensive bugs in the
codebase to date have been concurrency-shaped (`B-02` carry-forward, `T-06-05-04`
debounce, the single-writer HUD state rule). The signature alone does not
communicate these invariants; the docstring must.

**Always document at the type level:**

- The actor's isolation (`actor`, `@MainActor`, `nonisolated`) and *why* this is the
  right answer (e.g., "WebKit APIs demand main-thread calls"). `WebviewBridge` and
  `VoiceController` do this well.
- Single-writer gates. If only one site is permitted to call a method, the
  docstring says so AND points to the grep gate that enforces it:
  ```swift
  /// Single-writer entry point for `HUDState.transition(to:)`. The only
  /// permitted call site is `HUDStateMachine.advance` — enforced by
  /// `scripts/check-single-writer-hudstate.sh`.
  ```
- Lifetime contracts. If a `Task` must be cancelled by a specific teardown method
  before the actor is released, say it: "cancelled on `shutdown`."
- Reentrancy hazards. If the method `await`s and the caller must hold an external
  lock, say so. `AgentOrchestrator.cancelAndSubmit` does this well: *"cancels the
  in-flight turn, awaits its task to drain (no actor-reentrancy race), then starts
  a new turn."*

**Document at the property level:**

- Why a stored property is mutable when it looks like it should be `let` (the
  `degradationSummary` property on `AgentOrchestrator` does this — explains that
  `installAgent` runs before `runBootHealth` so the summary cannot be supplied at
  construction time).
- Why a closure type is `@Sendable` — the docstring should name the off-actor
  caller.

**Wired-but-dead anti-pattern.** Jarvis has a history of subsystems that compile,
test, and emit events but are not connected at composition. New types whose
behavior depends on being wired up by `AppDelegate` should say so in the
docstring: *"This type is inert unless `AppDelegate.installXYZ` calls
`.start()`."* This is the audit history paying for itself — a developer who knows
the failure mode writes against it.

---

## 6. Migration Plan

The codebase is ~50.9k LOC of Swift across 14 packages plus the App target.
Current state from a quick survey: 114k `///` lines and 153k `//` lines (this
includes legitimate code-level comments; the rate of *meaningful* comments is
substantially lower). The legacy hot spots are inline Plan-ID-led comments
(found 100+ in a single grep across `packages/` non-test sources) and underweight
docstrings on package-internal helpers.

**Don't attempt a global rewrite.** Apply opportunistic migration: any PR that
touches a file leaves the comments at-or-above this guide's standard for the
lines touched. That alone closes the gap on the hot paths inside a few months.

**Prioritized targeted rewrite (do these even if not touching the code):**

| Priority | File | Effort | Why first |
|----------|------|--------|-----------|
| P0 | `App/AppDelegate.swift` | ~4h | Composition root. First file every new dev opens. Already has a strong type-level docstring (lines 37–80); body has the worst Plan-ID-lede inline comments (lines 1464+, 1623+). Focus on the inline comments and property docstrings. |
| P0 | `packages/AgentCore/Sources/AgentOrchestrator/AgentOrchestrator.swift` | ~3h | Core turn lifecycle. Type-level docstring is already excellent. Body has ~10 Plan-ID-lede inline comments that should be rephrased to lead with why. |
| P1 | `packages/MCP/Sources/MCP/MCPClient.swift` + `MCPRuntime.swift` | ~2h | Tool dispatch backbone; already mostly there. Fix Plan-10-02b leads on properties at lines 58 and 105. |
| P1 | `packages/Memory/Sources/Memory/MemoryStore.swift` + `HybridSearch.swift` | ~2h | Memory is the newest subsystem, has the freshest D-IDs, and is also the place "wired-but-dead" bit hardest. Lead docstrings with the invariant ("hard-fails at boot rather than degrading"). |
| P2 | `packages/Voice/Sources/Voice/VoiceController.swift` | ~1h | Type-level docstring is already gold-standard. Cleanup pass on per-property docstrings only. |
| P2 | `packages/Bus/Sources/Bus/WebviewBridge.swift` | <1h | Reference example; leave it alone. |
| P2 | All `packages/*/Package.swift` headers | ~2h total | Currently changelog-shaped; rewrite to lead with the dependency rationale. |
| P3 | All package `README.md` files | not part of this guide | Either fold the README content INTO the package's top-level Swift file as a header comment, or delete them. The README-vs-code split is exactly the failure mode this guide rejects. |
| P3 | Test files | low priority | Tests are read by people debugging failures, not learning the codebase. Apply the guide opportunistically when touching a file. |

**Total estimated effort for P0+P1+P2:** ~12 hours focused work, or ~3 weeks of
opportunistic-while-doing-other-things. Spread across atomic commits with the
shape `docs(<package>): rewrite docstrings per code-commenting-guide`.

**Per-PR convention.** Every PR that touches a `.swift` file must leave each
modified function/type/property at-or-above the guide's standard for the lines
touched. Don't expand scope beyond the diff; don't "improve" adjacent code (per
CLAUDE.md surgical-changes rule). The grep gate
(`scripts/check-no-stale-plan-id-comments.sh`) warns on regressions; promote it
to fail after the P0/P1 pass.

**One-time helper.** Add a `scripts/check-no-stale-plan-id-comments.sh` that finds
comment lines whose entire content is a Plan/audit ID with no descriptive prose:

```bash
# pseudocode
grep -rnE '^\s*///?\s*(Plan|B-|D-|P[0-9]|S-|T-|CR-|REVIEW)[A-Za-z0-9-/ ]*\s*$' \
  packages App --include='*.swift'
```

Run this once, eyeball the hits, fix the worst offenders, then wire it into the
pre-push boundary gate sweep at warn-level.

---

## 7. References

1. **Apple — Swift API Design Guidelines (Documentation Comments section).**
   <https://www.swift.org/documentation/api-design-guidelines/> — *"Write a
   documentation comment for every declaration."* Begin with single-sentence
   summary. Use Swift's Markdown dialect; `- Parameter:`, `- Returns:`, `- Throws:`
   callouts. Cited above.

2. **Google — Swift Style Guide §5 (Documentation Comments).**
   <https://google.github.io/swift/> — Single-sentence summary; `Parameter(s)` /
   `Returns` / `Throws` tag order; "every open or public declaration"; explicit
   overrides-need-not-be-documented carve-out.

3. **Apple — DocC documentation (Symbol-Linking, Topics, See Also).** DocC supports
   `## Topics`, `## See Also`, fenced code samples, and `<doc:Article>` cross-links
   inside `///` docstrings. Jarvis uses the `## ` H2 form (visible in WebviewBridge,
   VoiceController, AgentOrchestrator headers) but does not yet build DocC archives
   — fine for in-IDE viewing.

4. **Steve McConnell, *Code Complete* (2nd ed.), Ch. 32 "Self-Documenting Code."**
   Comments express intent and rationale, not mechanics. Comments duplicating the
   code are rot waiting to happen.

5. **Robert C. Martin, *Clean Code*, Ch. 4 "Comments."** *"Comments are, at best, a
   necessary evil. […] Comments are always failures."* This guide takes the more
   honest middle position: comments that **encode non-obvious constraints** (which
   is what concurrency invariants, workaround citations, and hidden contracts are)
   are not failures — they are paying their rent on every read.

6. **Donald Knuth, "Literate Programming" (CACM, 1984).** The extreme "code IS
   documentation" position. Knuth's actual mechanism (WEB / CWEB) isn't practical
   in Swift; the spirit — that documentation and code are one artifact — is what
   Jarvis's "all docs in code" rule operationalizes.

7. **swift-nio — `Sources/NIOCore/EventLoop.swift`.**
   <https://github.com/apple/swift-nio/blob/main/Sources/NIOCore/EventLoop.swift>
   — Apple's reference style for documenting actor-shaped concurrency primitives.
   Type-level docstring opens with a one-sentence role, then a discussion paragraph.
   Method-level docstrings use `- Parameters:` / `- Returns:` callouts with
   threading notes integrated into the prose, not as separate sections.

8. **swift-log — `Sources/Logging/Logger.swift`.**
   <https://github.com/apple/swift-log/blob/main/Sources/Logging/Logger.swift> —
   Jarvis's logging dependency. License banner header; one-sentence type-level
   docstrings; verb-led method docstrings (*"Log a message…"*); double-backtick
   cross-references (` ``logLevel`` `).

9. **swift-composable-architecture — `Sources/ComposableArchitecture/Store.swift`.**
   <https://github.com/pointfreeco/swift-composable-architecture/blob/main/Sources/ComposableArchitecture/Store.swift>
   — Heavy DocC use; markdown headers (`### Scoping`) instead of formal `## Topics`
   blocks; code examples embedded in docstrings via fenced blocks. Closer to
   Jarvis's pragmatic style than nio's terser idiom.

10. **Jarvis CLAUDE.md (this repo).** Project-level rules — surgical changes,
    simplicity-first, "the user must understand WHY any given line of code exists
    by reading the file alone." This guide operationalizes that benchmark.
