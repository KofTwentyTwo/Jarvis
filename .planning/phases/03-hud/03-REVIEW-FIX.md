---
phase: 03-hud
review_source: 03-REVIEW.md
fix_scope: critical+warning (default)
fixes_applied:
  H-01: fixed
  H-02: fixed (option B)
fixes_deferred: [M-01, M-02, M-03, M-04, M-05, M-06, L-01, L-02, L-03, L-04, L-05, L-06, L-07]
verification_status: all green
fix_date: 2026-04-24
---

# Phase 3 Review-Fix Report

## Summary

Both HIGH findings landed; no Critical existed. H-01 lifted `isApprovalPlaceholder` from `ToolCallCard.tsx` into a shared `chat/approvalSentinel.ts` module and retargeted the `toolCallStart` dispatcher arm in `bus/client.ts` to use it — replacing the literal-byte JSON equality with parsed-object semantics so Swift-side whitespace drift cannot silently flip the status label. H-02 took **Option B** (attach-to-existing) in `@jarvis/bus`'s `installJarvisBus`: when a pre-existing `window.jarvisBus` with the expected shape is detected, the function now returns it verbatim rather than overwriting it. This preserves the Injection.js-installed bus whose `send()` reaches `webkit.messageHandlers.jarvisBus` from inside `JarvisBusWorld` — the default-world HUD bundle attaches to that bus instead of orphaning it. Two atomic commits: `9e8e9ec` (H-01) and `a0d8271` (H-02). Verification gate is fully green.

## H-01 — awaitingApproval sentinel unified

**Commit:** `9e8e9ec`

**Files touched:**
- `webview/packages/hud/src/chat/approvalSentinel.ts` (new — shared helper)
- `webview/packages/hud/src/chat/ToolCallCard.tsx` (import from shared helper; delete local duplicate)
- `webview/packages/hud/src/bus/client.ts` (import helper; replace literal-string equality with parsed-object check; reuse `parsedArgs` for both store.args and sentinel detection)
- `webview/packages/hud/tests/streaming.test.tsx` (new test `D5b` asserts whitespace-drifted sentinel — `{"awaitingApproval": true}` — produces `status === 'awaiting-approval'`)

**New test coverage:**
- `D5b: toolCallStart sentinel detection is whitespace-insensitive (H-01)` — passes against fixed code; would fail against pre-fix literal-string check (verified by construction: the payload differs by one byte from the literal and the old code tested `===`).
- `D5` (exact-string variant) still passes — semantically identical result.

## H-02 — attach to existing `window.jarvisBus` (Option B)

**Commit:** `a0d8271`

**Files touched:**
- `webview/packages/bus/src/bridge.ts` (attach-to-existing detection via `isJarvisBusShape`; fresh-install branch preserved for bus-harness.html path; expanded JSDoc explaining WKContentWorld isolation model)
- `webview/packages/bus/tests/bridge.test.ts` (new `describe('H-02 attach-to-existing …')` block with 5 tests)
- `webview/packages/hud/src/main.tsx` (doc comment explaining the cross-world pattern so future readers don't re-litigate)

**Why Option B (not A):**
Option B is the smaller edit — it stays inside the `@jarvis/bus` TS package and touches no Swift code. Option A would have required (a) reading the hashed bundle JS off disk at runtime, (b) installing it as a `WKUserScript(.atDocumentEnd, in: JarvisBusWorld)`, and (c) stripping the `<script type="module">` tag from the built `index.html` — a bigger surface change with more risk of breaking the Vite pipeline and the bus-harness.html path. Option B also turned out to be robust against the `isJarvisBusShape` duck-type check, which correctly falls through to fresh install when no pre-existing bus is present (bus-harness.html + test environment).

**New test coverage (5 cases):**
1. `returns the pre-existing bus unchanged when one is already installed` — identity check: `window.jarvisBus === preExisting`.
2. `routes send() through the pre-existing bus's send (reaches JarvisBusWorld-captured handler)` — proves outbound path delegates to the pre-existing bus's `send`.
3. `registers outbound handler on the pre-existing bus's onOutbound slot` — proves `onOutbound(fn)` is received by the pre-existing bus (so Injection.js's `_handler` slot fills correctly).
4. `falls through to fresh install when no pre-existing bus is present (bus-harness.html path)` — Phase 2 harness regression guard.
5. `falls through to fresh install if pre-existing value lacks the bus shape` — defense against stale test debris.

**Implementation note:** The check uses `window.jarvisBus` (not `globalThis.jarvisBus`) because in the vitest-jsdom environment, tests reassign `globalThis.window = {...}` — `window !== globalThis`. In the real WKWebView they're aliased, so the check behaves identically.

**Follow-ups:** none. The H-02 fix is self-contained and does not defer work to later phases.

## Deferred findings

Per default scope (`critical+warning`), the following Medium and Low findings are intentionally NOT fixed in this pass:

- **M-01** (AppDelegate emit closure double-hops + swallowed errors) — defer to a focused cleanup pass; adds logging, not correctness.
- **M-02** (`HudStateCoordinator.start()` redundant `MainActor.run` hops) — runtime micro-win; not blocking.
- **M-03** (resetStore helpers incomplete in ChatPanel.test.tsx + store.test.ts) — documented trap; existing tests all green; mechanical follow-up.
- **M-04** (`bus/client.ts` direct `useJarvisStore.setState` bypass) — Phase 4 will touch `chat/textStart` and can refactor at that time.
- **M-05** (AppDelegate hardBlock helper factoring) — cosmetic.
- **M-06** (`scripts/build-webview.sh` pwd leak) — environmental hygiene.
- **L-01..L-07** — all low-priority (shader divide-by-zero, uTime drift, JSON.stringify on raw strings, tsconfig lib width, etc.). Defer to Phase 4+ or Phase 8 Hardening as appropriate.

All deferred items are tracked by the REVIEW.md findings themselves; no re-capture needed.

## Verification results

All gates green:

| Gate | Result |
|------|--------|
| `pnpm --filter @jarvis/bus test` | **33/33 pass** (was 28 — added 5 H-02 tests) |
| `pnpm --filter @jarvis/hud test` | **80/80 pass** (was 79 — added 1 H-01 whitespace variant) |
| `pnpm --filter @jarvis/hud typecheck` | exit 0 |
| `pnpm --filter @jarvis/hud build` | exit 0 (1.08 MB main chunk — known, out of scope per Phase 8) |
| `cd packages/Bus && swift test` | **47/47 pass** (Phase 2 closed; unchanged) |
| `xcodegen generate && xcodebuild build …` | **BUILD SUCCEEDED** |
| `scripts/check-bus-protocol-version.sh` | `bus parity OK at v2.0.0` |
| `scripts/check-no-evaluate-javascript.sh` | `no evaluateJavaScript calls — HUD-04 OK` |
| `scripts/check-bus-harness-parity.sh` | `bus-harness.html parity OK` |
| `scripts/check-single-writer-hudstate.sh` | exit 0 |
| `scripts/smoke-test-hud.sh` | `PASS: bundle shape OK` |

Commits on `develop` post-fix:
- `9e8e9ec` — H-01 sentinel unification
- `a0d8271` — H-02 attach-to-existing

## Next steps

All HIGH findings closed; zero Critical findings remain. Ready for `/gsd-verify-phase 3`.

The H-02 fix is the first time the default-world bundle's `send()` path is wired end-to-end (Phase 2 harness never exercised it). The verifier phase should include the manual UAT noted in 03-REVIEW.md Option C as a belt-and-suspenders confirmation: build Debug, summon HUD, tail `~/Library/Logs/Jarvis/system.log` for the `bus handshake armed` line AND a successful `uiReady` inbound. The automated test suite confirms the TS-side wiring delegates to the pre-existing bus; the UAT confirms WebKit's cross-world `window` sharing model matches what the fix assumes.

---

_Fixed: 2026-04-24_
_Fixer: Claude (gsd-code-fixer)_
_Iteration: 1_
