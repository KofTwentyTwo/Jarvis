# Contributing

Personal-use project; the audience for this file is me-six-months-from-now and any AI coding agent operating in this repo. If you're an outside collaborator, this file probably isn't for you — see [`README.md`](README.md).

## Dev environment

| Requirement | Version |
|-------------|---------|
| macOS | 26 Tahoe (Apple Silicon) |
| Xcode | 16+ |
| Swift | 6.0 (strict concurrency) |
| Node | LTS |
| pnpm | 9+ |
| Ollama (optional) | Latest; pull `qwen2.5-coder:32b` + `nomic-embed-text` |

Clone, then:

```bash
# Webview workspace
cd webview && pnpm install
cd ..

# Open in Xcode (project.yml is the source of truth; xcodeproj is generated)
open Jarvis.xcodeproj
```

## Build / test cycle

Don't memorize commands — see the [`Build & test`](README.md#build--test) section in the root README and [`CLAUDE.md > Commands`](CLAUDE.md#commands). The short version:

```bash
swift test --package-path packages/<Pkg>     # default loop, fast, offline
bash scripts/check-app-builds.sh             # App target via xcodebuild
bash scripts/build-webview.sh                # HUD bundle
for s in scripts/check-*.sh; do bash "$s" || break; done   # all 18 boundary gates
```

Live-network / real-hardware tests are gated by `JARVIS_REAL_MODELS=1` and `JARVIS_REAL_CAMERA=1` env vars; default runs are deterministic and offline.

## GSD workflow

Project planning runs through the [GSD (Get Shit Done)](https://github.com/anthropics/gsd) toolchain. `.planning/` is authoritative; `docs/` carries cross-session live state.

```
/gsd-discuss-phase N → /gsd-plan-phase N → /gsd-execute-phase N → /gsd-verify-phase N
```

Each step commits atomically. Per-phase artifacts land in `.planning/phases/<N>/`. The roadmap is in `.planning/ROADMAP.md`; current state in `.planning/STATE.md`.

## Boundary gates

18 grep-based architectural-invariant linters live under `scripts/check-*.sh`. They are fast and deterministic. Run them before pushing.

If a gate fails:

1. **Read the gate's output.** It cites file:line.
2. **Read the gate script's header comment.** Tells you what it enforces and why.
3. **Don't disable the gate.** Fix the violation. If the rule has genuinely become wrong, that's a separate conversation that involves updating CLAUDE.md and possibly retiring the gate — never a one-off bypass.

The gates are listed in [`ARCHITECTURE.md > Boundary gates`](ARCHITECTURE.md#boundary-gates).

## Commit message conventions

Conventional Commits with scopes that match the work:

| Prefix | Use for |
|--------|---------|
| `feat(scope):` | New feature |
| `fix(scope):` | Bug fix |
| `chore(scope):` | Tooling, gates, infrastructure |
| `docs(scope):` | Documentation only |
| `test(scope):` | Test-only change |
| `refactor(scope):` | Internal restructuring, no behavior change |

Real examples from `git log`:

```
fix(track-b 7): BufferBroadcaster fan-out for multi-consumer audio ring
chore(gates): add check-applescript-confirmation.sh — defense-in-depth grep gate
docs(session): record P0-P2 audit-fix sweep close
test(voice p1-2): production chunkPump factory extracted + integration test
```

Scope often references the active workstream (`track-a`, `track-b 7`, `voice p1-3`, `memory d-3`) or the gate name. Body explains the **why**, not the what.

Sign commits with the `Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>` trailer when an AI agent did the work.

## Test discipline

- **TDD by default.** Failing test first, then make it pass. The audit-2026-05-04 P1 fixes followed this discipline; load-bearing tests were written before the fixes landed.
- **Mock / Stub / Fake naming taxonomy** ([CLAUDE.md §Test naming conventions](CLAUDE.md)):
  - `Mock*` — records calls AND returns scripted responses
  - `Stub*` — returns canned data, no recording
  - `Fake*` — alternative implementation behaviorally close to production
- **Test seams stay `internal` or `@_spi(Testing) public`, never plain `public`.** Test entry points must not leak into the published ABI. Tests use `@testable import`. (P2-14 — `_forceState`, `_testFireSpeechEnd`, `_testHandle`, `_testProcessIdentifier`.)
- **No tautologies.** `XCTAssertTrue(true)` and rubber-stamp tests get removed. `scripts/check-no-leftover-stubs.sh` flags some patterns; others rely on review. (`08125a4` cleanup.)
- **Fakes at I/O boundaries only.** Don't mock middle-of-system types — fake the LLM provider, the keychain, the SQLite store, and exercise the real code in between.

## Anti-patterns to avoid

These are the rules with teeth. See [`ARCHITECTURE.md > Anti-patterns`](ARCHITECTURE.md#anti-patterns-lessons-from-audits) for the full list. Most-cited:

- **Single `cancelAndSubmit` call site.** VOICE-14, grep-gated.
- **Never log voice transcript text.** T-06-05-03.
- **Multi-consumer audio: `BufferBroadcaster.subscribe()`, never raw `RingBuffer`.** Track B-7.
- **Tool result content capped at 8 KB.** Opus 4.7 footgun.
- **Cache hints gated on prompts ≥1024 tokens.** Track A.
- **`extended-cache-ttl` requires the beta header.**
- **Tool-choice `.none` on cap-recovery turns.**
- **`turnNonce` never on the bus.** SEC-06.
- **Never `--deep` codesign.** Strips per-helper entitlements.
- **No `evaluateJavaScript` outside `WebviewBridge`.**
- **`requiresConfirmation: true` for `run_applescript` at TWO sites.** Single-point edit can't bypass.
- **Single-emission sites for memory replay events.**

## How to add a new MCP tool

1. **Decide if it's a helper or in-process.** Helpers are separately codesigned `.app` bundles under `Contents/Helpers/`; they get their own TCC identity. In-process tools (like `SearchMemoryTool`) live under `packages/MCP/Sources/MCP/InProcess/` and don't spawn a child.
2. **For a helper:**
   - Create a new directory under `mcp-servers/<name>/` with a `Package.swift` (executable product) and a `main.swift` that uses `modelcontextprotocol/swift-sdk`'s `Server`, `StdioTransport`, and registers handlers via `withMethodHandler(ListTools.self)` / `withMethodHandler(CallTool.self)`.
   - Codesign the helper as a separate identity. Add a build phase or update `scripts/codesign.sh`. **Never `--deep`. Never Xcode "Code Sign On Copy".**
   - If the helper needs entitlements (e.g., Apple Events), give the helper its own `.entitlements` file. Don't widen the main app's.
3. **Register in `App/MCP/MCPRuntimeWiring.swift`** with `register(name:binaryURL:requiresConfirmation:)`. Confirmation-required tools (`run_applescript`) MUST set `requiresConfirmation: true` — `scripts/check-applescript-confirmation.sh` enforces this for AppleScript specifically; do similar gates for any new dangerous tool.
4. **Add tests.** Crash/restart fixture via `MockHelper`; happy-path call; sanitize round-trip if the tool returns content.
5. **Update [`ARCHITECTURE.md`](ARCHITECTURE.md) if the tool changes the system's exposed surface.**

## How to add a new HUD button + bus event

1. **Add the case to BOTH sides of the bus.**
   - Swift: `packages/Bus/Sources/Bus/BusInbound.swift` (or `BusOutbound.swift`). Update the hand-written `Codable` `init(from:)` AND `encode(to:)`. Adding a case without updating both is a compile error — that's the schema-drift preventer.
   - TS: `webview/packages/bus/src/`. Mirror the new case in the union + the zod schema.
2. **Bump the protocol version.** `packages/Bus/Sources/Bus/Protocol.swift` AND `webview/packages/bus/src/version.ts`. Additive changes are MINOR; breaking changes are MAJOR. `scripts/check-bus-protocol-version.sh` enforces the sync.
3. **Update the harness fixtures** under `packages/Bus/Tests/.../Fixtures/`. `scripts/check-bus-harness-parity.sh` requires the TS fixtures to round-trip through the Swift decoder.
4. **Wire the producer.** For a Swift→JS event: emit through `OutboundBatcher`. For a JS→Swift event: handle in `AppDelegate.onInbound` (or the appropriate routing site).
5. **Add the HUD UI** in `webview/packages/hud/src/`. Use the typed bus client (`window.jarvisBus.send` for inbound, the message-handler subscription for outbound).
6. **Add tests on both sides.** Vitest for the React component, XCTest for the Swift handler.

## Compaction recovery (for AI agents)

After context compaction, re-read in this order:

1. `~/.claude/CLAUDE.md` (global rules)
2. This project's [`CLAUDE.md`](CLAUDE.md)
3. [`docs/SESSION-STATE.md`](docs/SESSION-STATE.md) — current state
4. [`docs/TODO.md`](docs/TODO.md) — open items
5. [`ARCHITECTURE.md`](ARCHITECTURE.md) — system shape
6. The git log: `git log --oneline | head -25`

Then orient on the active workstream. The `.planning/audit-*` reports are historical context — use them to understand the why behind recent fix commits, not as instructions.
