---
phase: 02-bus
plan: 02
subsystem: bus
tags: [typescript, pnpm, vitest, webview, wkwebview, bridge, protocol]

requires:
  - phase: 01-foundations
    provides: project.yml, App/ scaffolding, STATE.md tracking
provides:
  - webview/ pnpm workspace root (first TS content in repo)
  - "@jarvis/bus TS package: BUS_PROTOCOL_VERSION, BusOutbound/BusInbound discriminated unions, non-throwing decoders"
  - window.jarvisBus glue (the single surface calling webkit.messageHandlers.jarvisBus)
  - 15 fixture JSONs byte-identical to Plan 01 Swift mirror (14 outbound + 1 inbound)
  - bus-harness.html — static stub Plan 03's WKWebView loadFileURL targets
affects: [02-03-outbound-batcher-wiring, 02-04-build-parity-lint, 03-hud-skeleton, all future webview work]

tech-stack:
  added:
    - "pnpm 10.30.2 (packageManager pin; workspace root)"
    - "TypeScript 5.9.3 (strict mode + noUncheckedIndexedAccess + exactOptionalPropertyTypes)"
    - "Vitest 2.1.9 (node env for unit tests)"
    - "@types/node 20.19"
  patterns:
    - "pnpm workspace at webview/ with packages/* glob"
    - "Shared tsconfig.base.json extended by per-package tsconfig"
    - "@jarvis/* scoped TS packages under webview/packages/"
    - "DecodeResult<T> = {ok:true,value} | {ok:false,error} — decoders never throw"
    - "`const _exhaustive: never = type;` (no `as never` cast) for compile-time switch exhaustiveness"
    - "Type-guard arrays with `as const satisfies readonly T[]` catch union drift"
    - "window.jarvisBus is the single bridge surface; all webkit.messageHandlers.jarvisBus access routed through it"
    - "Static HTML + compiled bundle (Vite proper deferred to P3)"

key-files:
  created:
    - webview/package.json (workspace root, pnpm@10.30.2)
    - webview/pnpm-workspace.yaml
    - webview/.gitignore
    - webview/tsconfig.base.json
    - webview/packages/bus/package.json (@jarvis/bus)
    - webview/packages/bus/tsconfig.json
    - webview/packages/bus/vitest.config.ts
    - webview/packages/bus/src/protocol.ts (BUS_PROTOCOL_VERSION, decoders, encoders, type guards)
    - webview/packages/bus/src/bridge.ts (installJarvisBus, window.jarvisBus)
    - webview/packages/bus/src/index.ts
    - webview/packages/bus/tests/round-trip.test.ts (21 assertions)
    - webview/packages/bus/tests/bridge.test.ts (7 assertions)
    - webview/packages/bus/fixtures/*.json (15 files)
    - webview/bus-harness.html
    - webview/pnpm-lock.yaml
  modified: []

key-decisions:
  - "Pinned packageManager to pnpm@10.30.2 (matched installed version; plan suggested 9.15.0 but the plan explicitly permits using the installed major)."
  - "Dropped `as never` cast from the exhaustiveness sentinel: `const _exhaustive: never = type;` (no cast). Empirically proved `as never` defeats the check — adding a variant without updating the switch does NOT fail tsc with the cast present. Without the cast, tsc emits TS2322 as designed."
  - "Typed the switch-scrutinee as `const type: BusOutbound[\"type\"] = parsed.type as BusOutbound[\"type\"];` so the switch narrows properly."
  - "Auto-ack of `hello` when no handler is registered — load-bearing for bus-harness.html to complete the handshake without page-side code. P3's real HUD registers a handler before any `hello` arrives, so this branch is dormant in production."
  - "Dropped `pendingHello` buffer from the plan's sketch (originally also tried to replay a single pre-handler message to a late-registered handler). Simpler contract: handler-or-auto-ack-or-log. Messages after auto-ack go to the handler; messages arriving pre-handler that are NOT hello are dropped with a diagnostic to onDecodeError."
  - "Fixture files written with `printf '%s'` (no trailing newline) so bytes match Plan 01's Swift fixtures exactly (Swift's Codable default also writes no trailing newline). Verified last byte is `0x7d` (`}`) for all 15 files."

patterns-established:
  - "pnpm workspace layout: webview/{package.json, pnpm-workspace.yaml, tsconfig.base.json}; per-package extends tsconfig.base.json."
  - "DecodeResult<T> shape for all bus-layer decoders; extends to P3 consumers."
  - "Exhaustiveness sentinel: `const _exhaustive: never = type;` without `as never` — compile-time drift detection for discriminated unions."
  - "Single-surface bridge: only bridge.ts touches webkit.messageHandlers.jarvisBus; all other TS code goes through window.jarvisBus."

requirements-completed: [HUD-03, HUD-05, SEC-09]

duration: 14min
completed: 2026-04-23
---

# Phase 02-bus Plan 02: TypeScript Bus package + pnpm workspace Summary

**`@jarvis/bus` TypeScript package with `BUS_PROTOCOL_VERSION = "2.0.0"`, non-throwing `DecodeResult<T>` codecs, compile-time `never`-sentinel exhaustiveness, `window.jarvisBus` bridge, and 15 byte-identical fixtures — first TS content in the repo.**

## Performance

- **Duration:** ~14 min
- **Started:** 2026-04-23T22:07:55Z
- **Completed:** 2026-04-23T22:21:40Z
- **Tasks:** 2 (both TDD)
- **Files modified:** 24 new files committed across 4 atomic commits

## Accomplishments

- pnpm workspace root at `webview/` (first TS content in the repository) with strict `tsconfig.base.json`
- `@jarvis/bus` TypeScript package mirroring `packages/Bus/Sources/Bus/` from Plan 01 — same discriminator, same fixtures, same version constant
- Non-throwing decoders (`decodeOutbound`, `decodeInbound`) returning `DecodeResult<T>`, with compile-time exhaustiveness via `const _exhaustive: never = type` (empirically verified: adding a variant fails `tsc --strict` with TS2322)
- `window.jarvisBus` glue (`installJarvisBus()`) — the single TypeScript surface calling `webkit.messageHandlers.jarvisBus.postMessage`; all other code routes through it
- 15 fixture JSONs (14 BusOutbound + 1 BusInbound) written with exact byte contents to match Plan 01 — Plan 04's parity script will diff them
- `bus-harness.html` static stub that Plan 03's `panel.webView.loadFileURL(...)` points at; imports compiled `./packages/bus/dist/index.js` and auto-acks the `hello` handshake without any page-side code
- 28 vitest assertions across 2 suites, all green; `tsc --noEmit --strict` clean

## Task Commits

TDD tasks have RED → GREEN commits; both tasks followed the cycle.

1. **Task 1 RED: scaffolding + failing round-trip suite** — `6ce4754` (test)
2. **Task 1 GREEN: protocol decode/encode with never-sentinel exhaustiveness** — `4e68fa2` (feat)
3. **Task 2 RED: failing bridge.test.ts against stub installJarvisBus** — `2d3387a` (test)
4. **Task 2 GREEN: window.jarvisBus glue + bus-harness.html** — `c21df44` (feat)

_Plan metadata commit (SUMMARY.md) follows this file._

## Files Created/Modified

**Workspace root**
- `webview/package.json` — pnpm workspace declaration; devDeps typescript 5.9.3, vitest 2.1.9, @types/node 20.19.
- `webview/pnpm-workspace.yaml` — `packages/*` glob.
- `webview/.gitignore` — `node_modules/`, `dist/`, `coverage/`, `*.tsbuildinfo`.
- `webview/tsconfig.base.json` — strict TypeScript config inherited by each package.
- `webview/pnpm-lock.yaml` — committed for reproducibility.

**`@jarvis/bus` package** (`webview/packages/bus/`)
- `package.json` — `@jarvis/bus`, ESM, exports `.` + `./fixtures/*`.
- `tsconfig.json` — extends base, emits `dist/` with declarations + sourcemaps, composite.
- `vitest.config.ts` — node env, `tests/**/*.test.ts`.
- `src/protocol.ts` — `BUS_PROTOCOL_VERSION = "2.0.0"`, `HudState` (7 members), `TurnTerminator` (4 members), `BusOutbound` (8 cases) and `BusInbound` (2 cases) discriminated unions, `decodeOutbound` / `decodeInbound` returning `DecodeResult<T>` (never throws), `encodeOutbound` / `encodeInbound` wrappers around `JSON.stringify`, type guards backed by `as const satisfies readonly T[]`.
- `src/bridge.ts` — `installJarvisBus()` creates `window.jarvisBus` with `receive`, `send`, `onOutbound`, `protocolVersion`. `send()` is the only TS call site of `webkit.messageHandlers.jarvisBus.postMessage`. Auto-acks `hello` when no handler is registered.
- `src/index.ts` — re-exports `protocol.js` + `bridge.js`.
- `tests/round-trip.test.ts` — 21 assertions: `BUS_PROTOCOL_VERSION` pin, 14 outbound round-trips, 1 inbound round-trip, 5 error paths.
- `tests/bridge.test.ts` — 7 assertions: installation, dispatch, auto-ack, decode-error callback, `send()` JSON encoding, missing-webkit error, `onOutbound` latest-wins.
- `fixtures/*.json` (15 files) — byte-identical to Plan 01 Swift fixtures.

**Harness**
- `webview/bus-harness.html` — static HTML stub; `<script type="module">` imports `./packages/bus/dist/index.js`, calls `installJarvisBus()`. P3 replaces this file with the real React + R3F entrypoint.

## Decisions Made

- **pnpm 10.30.2 packageManager pin.** The plan sketched `pnpm@9.15.0`; the installed pnpm is 10.30.2. The plan explicitly allowed using the installed major, so `packageManager` is `pnpm@10.30.2`.
- **Exhaustiveness sentinel without `as never` cast.** The plan's original snippet used `const _exhaustive: never = type as never;`, which empirically defeats the check — adding a new `BusOutbound` variant without updating the switch does NOT fail `tsc --strict` because the cast strips type information. I replaced it with `const _exhaustive: never = type;` (no cast) and verified: adding `| { type: "futureVariant"; novel: string }` to the union produces `TS2322: Type '"futureVariant"' is not assignable to type 'never'` on the sentinel line. Restored to the baseline union afterward. See deviation #1 below.
- **Strictly-typed switch scrutinee.** `const type: BusOutbound["type"] = parsed.type as BusOutbound["type"];` so the switch narrows through `type` (not through the broader-typed `parsed.type: string`), allowing `never` to actually be `never` in the default branch.
- **Auto-ack in bridge (load-bearing).** The bus-harness.html stub has no page-side handler, so the bridge synthesizes `helloAck` internally when `hello` arrives before `onOutbound`. This is the only reason Plan 03's `loadFileURL` smoke test can observe `handshakeState == .armed` without any JS beyond the bundle import.
- **Dropped the plan's `pendingHello` buffer.** The plan's sketch attempted to buffer a pre-handler message and replay it once a handler registered. Simplified to: handler present → dispatch; no handler + hello → auto-ack; no handler + anything else → log via `onDecodeError`. Rationale: the replay path is never used in production (P3 registers a handler early) and never exercised by tests.

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 1 - Bug] Exhaustiveness sentinel used `as never` cast which defeats the check**

- **Found during:** Task 1 verification (probed by temporarily adding a new discriminator variant).
- **Issue:** The plan's snippet wrote `const _exhaustive: never = type as never;`. The `as never` cast erases the type information the sentinel depends on. I verified: with the cast present, adding `| { type: "futureVariant"; novel: string }` to `BusOutbound` compiled cleanly — no TS2322, no drift detection. The stated purpose of the sentinel (compile-time exhaustiveness) was broken.
- **Fix:** Two edits in `protocol.ts`:
  1. Strongly-type the switch scrutinee: `const type: BusOutbound["type"] = parsed.type as BusOutbound["type"];` (instead of `type as BusOutbound["type"] | (string & {})`, which widened it back to `string`).
  2. Removed the `as never` cast from both default branches: `const _exhaustive: never = type;` (no cast).
- **Verification:** Empirical probe — temporarily appended `| { type: "futureVariant"; novel: string }` to the union, ran `tsc --noEmit`, observed `src/protocol.ts(166,13): error TS2322: Type '"futureVariant"' is not assignable to type 'never'.`, restored the baseline. The sentinel now bites. Mentioned in the "must_haves.truths" of the plan frontmatter as a load-bearing property.
- **Files modified:** `webview/packages/bus/src/protocol.ts` (both `decodeOutbound` and `decodeInbound` default branches, plus the switch-scrutinee typing).
- **Committed in:** `4e68fa2` (Task 1 GREEN).

**2. [Rule 2 - Missing Critical] `parsed.type` not castable to `BusOutbound["type"]` in strict mode**

- **Found during:** Task 1 GREEN compilation.
- **Issue:** At the time `parsed.type` is narrowed by the string guard above, its type is `string`, not `BusOutbound["type"]`. Direct assignment `const type: BusOutbound["type"] = parsed.type;` fails strict typecheck.
- **Fix:** Used a single localized `as BusOutbound["type"]` cast on the RHS: `const type: BusOutbound["type"] = parsed.type as BusOutbound["type"];`. This is the load-bearing cast. The sentinel in the default branch catches the case where that cast is lying (i.e., `parsed.type` is not actually a member of the union), returning `{ok: false, error: 'unknown type: ...'}`.
- **Verification:** `tsc --noEmit` clean. The five error-path tests (unknown type, malformed JSON, missing discriminator, invalid hudState, non-object payload) all pass, confirming the cast doesn't compromise runtime safety.
- **Committed in:** `4e68fa2` (Task 1 GREEN).

---

**Total deviations:** 2 auto-fixed (1 bug in the plan's sentinel sketch, 1 narrowing fix required for strict mode).
**Impact on plan:** Both fixes preserve the plan's stated intent (compile-time exhaustiveness); the plan's sketch was directionally correct but the specific snippet didn't work under the strict config the plan mandated. Plan's truths table now accurately describes the shipped behavior. No scope creep.

## Issues Encountered

- **tsc exhaustiveness sentinel did not bite on first attempt.** Discovered during Task 1 GREEN verification. Root cause + fix described under Deviations §1. Took one probe-fix-reprobe cycle to diagnose.
- **Fixture byte-format.** `printf '%s'` (no trailing newline) was chosen so bytes match Swift's `Codable` encoder default. All 15 files end in `0x7d` with no `0x0a`. Verified via `tail -c 1 | xxd -p`.

## User Setup Required

None — no external service configuration required. Plan is strictly additive under `webview/`.

## Next Phase Readiness

- **Plan 03 (Outbound batcher + Swift wiring)** can now point `panel.webView.loadFileURL(...)` at the compiled `webview/bus-harness.html`. The post-build copy step described in the harness comment (`webview/packages/bus/dist/` + `bus-harness.html` → `App/Resources/webview/` or `Contents/Resources/webview/`) is Plan 03's responsibility.
- **Plan 04 (Build parity + lint)** inherits 15 fixtures, the `BUS_PROTOCOL_VERSION = "2.0.0"` constant, and the `grep 'messageHandlers\.jarvisBus'` invariant (only `bridge.ts` should match). Parity script should:
  1. `diff webview/packages/bus/fixtures/ packages/Bus/Tests/BusTests/Fixtures/` — expect zero output.
  2. `grep BUS_PROTOCOL_VERSION` in both mirror files and assert equality.
  3. `pnpm --filter @jarvis/bus test` in CI.
- **HUD-03, HUD-05, SEC-09** are now complete on the TS side. Plan 01 (running in parallel) covers the Swift side of the same requirements.

### Handoff Contracts (immutable from this plan forward)

- `window.jarvisBus.receive(payload: string): void` — Swift calls this via `callAsyncJavaScript`.
- `window.jarvisBus.send(msg: BusInbound): Promise<unknown>` — JS -> Swift; awaitable for reply.
- `window.jarvisBus.onOutbound(handler: OutboundHandler): void` — P3's HUD registers here before `hello` arrives.
- `window.jarvisBus.protocolVersion: "2.0.0"` — handshake partner for Swift's `BUS_PROTOCOL_VERSION`.
- `dist/index.js` is the ESM bundle; harness imports from `./packages/bus/dist/index.js` (relative). If Plan 03 changes the bundle layout, the harness's single `import` line is the only place to update.

## Threat Flags

None — this plan stays within the surface already enumerated in the plan's `<threat_model>`. The `bridge.ts` auto-ack narrows `T-02-12` (spoofing): the harness will `helloAck` any `hello` it receives, but the WKWebView is scoped to `file://` bundle URLs by Plan 03, so this is accepted risk per the register.

## Self-Check

- [x] `webview/package.json` exists
- [x] `webview/pnpm-workspace.yaml` exists
- [x] `webview/tsconfig.base.json` exists
- [x] `webview/packages/bus/package.json` exists (`@jarvis/bus`)
- [x] `webview/packages/bus/src/protocol.ts` exists with `BUS_PROTOCOL_VERSION = "2.0.0"`
- [x] `webview/packages/bus/src/bridge.ts` exists with `installJarvisBus` + `window.jarvisBus` typing
- [x] `webview/packages/bus/src/index.ts` re-exports both modules
- [x] 15 fixtures under `webview/packages/bus/fixtures/` (14 outbound + 1 inbound)
- [x] `webview/packages/bus/tests/round-trip.test.ts` — 21 assertions, all green
- [x] `webview/packages/bus/tests/bridge.test.ts` — 7 assertions, all green
- [x] `webview/bus-harness.html` exists and imports `./packages/bus/dist/index.js`
- [x] Commit `6ce4754` exists (Task 1 RED)
- [x] Commit `4e68fa2` exists (Task 1 GREEN)
- [x] Commit `2d3387a` exists (Task 2 RED)
- [x] Commit `c21df44` exists (Task 2 GREEN)
- [x] `grep -c '_exhaustive: never' webview/packages/bus/src/protocol.ts` ≥ 2 (actual: 3)
- [x] Zero `: any` types in `webview/packages/bus/src/*.ts`
- [x] `pnpm --filter @jarvis/bus test` exits 0 (28/28 green)
- [x] `pnpm --filter @jarvis/bus exec tsc --noEmit` exits 0

**Self-Check: PASSED**

---
*Phase: 02-bus*
*Completed: 2026-04-23*
