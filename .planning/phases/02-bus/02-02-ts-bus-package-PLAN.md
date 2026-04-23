---
phase: 02-bus
plan: 02
type: execute
wave: 1
depends_on: []
files_modified:
  - webview/package.json
  - webview/pnpm-workspace.yaml
  - webview/.gitignore
  - webview/tsconfig.base.json
  - webview/packages/bus/package.json
  - webview/packages/bus/tsconfig.json
  - webview/packages/bus/vitest.config.ts
  - webview/packages/bus/src/protocol.ts
  - webview/packages/bus/src/bridge.ts
  - webview/packages/bus/src/index.ts
  - webview/packages/bus/fixtures/hello.json
  - webview/packages/bus/fixtures/helloAck.json
  - webview/packages/bus/fixtures/hudState.idle.json
  - webview/packages/bus/fixtures/hudState.listening.json
  - webview/packages/bus/fixtures/hudState.thinking.json
  - webview/packages/bus/fixtures/hudState.speaking.json
  - webview/packages/bus/fixtures/hudState.awaitingConfirmation.json
  - webview/packages/bus/fixtures/hudState.reconfiguring.json
  - webview/packages/bus/fixtures/hudState.booting.json
  - webview/packages/bus/fixtures/tokenDelta.json
  - webview/packages/bus/fixtures/audioLevel.json
  - webview/packages/bus/fixtures/toolCallStart.json
  - webview/packages/bus/fixtures/toolCallEnd.json
  - webview/packages/bus/fixtures/turnStarted.json
  - webview/packages/bus/fixtures/turnEnded.json
  - webview/packages/bus/tests/round-trip.test.ts
  - webview/packages/bus/tests/bridge.test.ts
  - webview/bus-harness.html
autonomous: true
requirements: [HUD-03, HUD-05, SEC-09]

must_haves:
  truths:
    - "TS `BUS_PROTOCOL_VERSION` constant exists at `webview/packages/bus/src/protocol.ts` and equals \"2.0.0\" (byte-identical to the Swift constant)"
    - "`BusOutbound` and `BusInbound` TS types use discriminated-union shape with `type` literal as the discriminator"
    - "`decodeOutbound(jsonString)` returns `{ok: true, value}` on valid input and `{ok: false, error}` on any failure — never throws, never returns a default-branch value"
    - "`decodeOutbound` exhaustive `switch` uses `const _exhaustive: never = parsed.type;` sentinel so a TS union expansion forgotten in decodeOutbound fails `tsc --strict`"
    - "Each of the 14 fixture `.json` files in `webview/packages/bus/fixtures/` is byte-identical to its counterpart in `packages/Bus/Tests/BusTests/Fixtures/` (parity-enforced in Plan 04)"
    - "Vitest round-trip runner parses every fixture + re-stringifies it via `encodeOutbound` / `encodeInbound` and asserts deep-equality"
    - "The `window.jarvisBus` glue (`src/bridge.ts`) is the ONLY surface that calls `webkit.messageHandlers.jarvisBus.postMessage(...)` — all other TS code routes through `window.jarvisBus.send(msg)`"
    - "`bus-harness.html` is the minimal static HTML stub that the Swift-side bridge points its `WKWebView` at in P2; it imports `dist/bus.js`, responds to `hello` with `helloAck`, and exposes `window.jarvisBus` for Swift's `callAsyncJavaScript`"
    - "pnpm workspace is initialized (`pnpm-workspace.yaml` lists `packages/*`); TypeScript 5.5+ and Vitest 2.x are installed as workspace-root devDeps"
  artifacts:
    - path: "webview/package.json"
      provides: "pnpm workspace root; devDeps: typescript, vitest, @types/node"
    - path: "webview/pnpm-workspace.yaml"
      provides: "Declares `packages/*` glob"
    - path: "webview/tsconfig.base.json"
      provides: "Shared strict TS config extended by package tsconfigs"
    - path: "webview/packages/bus/package.json"
      provides: "`@jarvis/bus` package metadata + vitest script"
      contains: "@jarvis/bus"
    - path: "webview/packages/bus/src/protocol.ts"
      provides: "BUS_PROTOCOL_VERSION + BusOutbound/BusInbound types + decode/encode functions"
      contains: "BUS_PROTOCOL_VERSION = \"2.0.0\""
    - path: "webview/packages/bus/src/bridge.ts"
      provides: "`window.jarvisBus` glue: receive(payload: string), send(inbound), onOutbound(handler)"
    - path: "webview/packages/bus/src/index.ts"
      provides: "Re-exports protocol.ts + bridge.ts public surface"
    - path: "webview/packages/bus/tests/round-trip.test.ts"
      provides: "Vitest suite: one test per fixture, decode → re-encode → deepEqual"
    - path: "webview/packages/bus/tests/bridge.test.ts"
      provides: "Vitest suite: bridge.receive dispatches to onOutbound handler; malformed payload logs console.error (mocked)"
    - path: "webview/bus-harness.html"
      provides: "Static HTML Swift's WKWebView loads; imports compiled bus.js, auto-responds to hello with helloAck"
    - path: "webview/packages/bus/fixtures/*.json"
      provides: "14 fixtures — identical bytes to Swift side"
  key_links:
    - from: "webview/packages/bus/src/protocol.ts"
      to: "packages/Bus/Sources/Bus/Protocol.swift"
      via: "byte-identical BUS_PROTOCOL_VERSION constant; same discriminator 'type'"
      pattern: "BUS_PROTOCOL_VERSION"
    - from: "webview/packages/bus/src/bridge.ts"
      to: "webkit.messageHandlers.jarvisBus"
      via: "window.webkit.messageHandlers.jarvisBus.postMessage(jsonString)"
      pattern: "messageHandlers\\.jarvisBus"
    - from: "webview/bus-harness.html"
      to: "window.jarvisBus"
      via: "<script type='module' src='dist/bus.js'>"
      pattern: "dist/bus\\.js"
    - from: "webview/packages/bus/src/protocol.ts"
      to: "decodeOutbound exhaustive switch"
      via: "const _exhaustive: never = parsed.type sentinel"
      pattern: "_exhaustive: never"
---

<objective>
Build the TypeScript side of the typed JSON bus — `webview/packages/bus/` — as
the mirror of `packages/Bus` in Plan 01. This plan delivers:

1. **pnpm workspace scaffolding** — first content of the `webview/` top-level
   directory (previously empty). `package.json` at `webview/` declares the
   workspace; `pnpm-workspace.yaml` globs `packages/*`; a shared
   `tsconfig.base.json` enables strict mode.
2. **`@jarvis/bus` TS package** — mirror of `packages/Bus/Sources/Bus/`:
   `BUS_PROTOCOL_VERSION = "2.0.0"` (byte-identical to Swift), TS discriminated
   unions for `BusOutbound` and `BusInbound`, `decodeOutbound`/`encodeOutbound`
   with exhaustive switches (using TS's `never` sentinel for compile-time
   exhaustiveness), and `window.jarvisBus` glue (`bridge.ts`).
3. **14 fixture JSONs** — byte-identical to their Swift counterparts from Plan
   01. Plan 04's parity script asserts the directories never drift.
4. **Vitest round-trip suite** — one test per fixture: decode the JSON →
   re-encode through `encodeOutbound`/`encodeInbound` → assert `deepEqual` to
   the original. Proves wire-shape symmetry.
5. **`bus-harness.html`** — minimal static HTML. Swift's WKWebView loads this
   at P2 runtime. It imports the compiled `dist/bus.js`, auto-responds to
   `hello` with `helloAck`, and exposes `window.jarvisBus` so Swift's
   `callAsyncJavaScript("window.jarvisBus.receive(payload)", …)` works when
   Plan 03 wires it. Per RESEARCH open question #1: static HTML + compiled
   bundle, NOT a full Vite project (Vite arrives in P3 with R3F).

Purpose: Pin the wire format on both sides. The handshake succeeds when both
constants equal `"2.0.0"` and both codecs round-trip identical bytes. The
harness HTML is what Plan 03 hands to `panel.webView.loadFileURL(...)`.

Output: New `webview/` directory (root + workspace + one package + harness).
No changes to `App/`, `packages/`, or `project.yml` — this plan is strictly
additive in a new top-level directory. Can run fully in parallel with Plan 01.
</objective>

<execution_context>
@~/.claude/get-shit-done/workflows/execute-plan.md
@~/.claude/get-shit-done/templates/summary.md
</execution_context>

<context>
@.planning/PROJECT.md
@.planning/ROADMAP.md
@.planning/REQUIREMENTS.md
@.planning/phases/02-bus/02-RESEARCH.md

<!-- Shared fixture source of truth — Plan 01 creates the Swift mirror with identical bytes.
     Plan 04's parity script will enforce byte-equality between these two directories. -->

<interfaces>
<!-- TS public surface this plan creates -->
```typescript
// webview/packages/bus/src/protocol.ts — public API

export const BUS_PROTOCOL_VERSION = "2.0.0";

export type HudState =
  | "idle" | "listening" | "thinking" | "speaking"
  | "awaitingConfirmation" | "reconfiguring" | "booting";

export type TurnTerminator =
  | "completed" | "cancelled" | "errored" | "superseded";

export type BusOutbound =
  | { type: "hello"; version: string }
  | { type: "hudState"; state: HudState }
  | { type: "tokenDelta"; text: string }
  | { type: "audioLevel"; rms: number }
  | { type: "toolCallStart"; id: string; name: string; argsPreview: string }
  | { type: "toolCallEnd"; id: string; ok: boolean; previewOrError: string }
  | { type: "turnStarted"; id: string }
  | { type: "turnEnded"; id: string; terminator: TurnTerminator };

export type BusInbound =
  | { type: "helloAck"; version: string }
  | { type: "uiReady" };

export type DecodeResult<T> =
  | { ok: true; value: T }
  | { ok: false; error: string };

export function decodeOutbound(json: string): DecodeResult<BusOutbound>;
export function decodeInbound(json: string): DecodeResult<BusInbound>;
export function encodeOutbound(msg: BusOutbound): string;
export function encodeInbound(msg: BusInbound): string;

// webview/packages/bus/src/bridge.ts — window.jarvisBus glue

declare global {
  interface Window {
    jarvisBus: {
      receive(payload: string): void;
      send(msg: BusInbound): Promise<unknown>;
      onOutbound(handler: (msg: BusOutbound) => void): void;
    };
    webkit?: {
      messageHandlers: {
        jarvisBus: { postMessage(body: string): Promise<unknown> };
      };
    };
  }
}

export function installJarvisBus(): void;
```
</interfaces>
</context>

<tasks>

<task type="auto" tdd="true">
  <name>Task 1: pnpm workspace scaffold + protocol.ts + 14 fixtures + round-trip tests</name>
  <files>
    webview/package.json,
    webview/pnpm-workspace.yaml,
    webview/.gitignore,
    webview/tsconfig.base.json,
    webview/packages/bus/package.json,
    webview/packages/bus/tsconfig.json,
    webview/packages/bus/vitest.config.ts,
    webview/packages/bus/src/protocol.ts,
    webview/packages/bus/src/index.ts,
    webview/packages/bus/fixtures/*.json (14 files),
    webview/packages/bus/tests/round-trip.test.ts
  </files>
  <behavior>
    - Test 1: Each of 14 fixtures decodes via `decodeOutbound` or `decodeInbound` to the correct typed value
    - Test 2: Round-trip: fixture.json → decoded → re-encoded → JSON.parse → deepEqual(original)
    - Test 3: `decodeOutbound("{\"type\":\"unknown\"}")` returns `{ok: false, error: ...}` (never throws)
    - Test 4: `decodeOutbound("{not json")` returns `{ok: false, error: ...}` (catches SyntaxError)
    - Test 5: `decodeOutbound("{}")` returns `{ok: false, error: "missing discriminator"}`
    - Test 6: `BUS_PROTOCOL_VERSION === "2.0.0"` (byte-match with Swift)
    - Test 7: `HudState` union covers exactly 7 members (matches Swift `HudState` case count)
    - Test 8: TS `const _exhaustive: never = parsed.type;` branch is unreachable in happy path but present in source (lint / compile-time check)
  </behavior>
  <action>
    **Decisions honored:** pnpm workspace per CLAUDE.md D-12 + RESEARCH §Standard Stack.
    Vitest 2.x per RESEARCH §Alternatives Considered ("Vite proper is a P3 concern").
    Hand-written TS types (no codegen) per RESEARCH §Claude's Discretion.
    Static fixture JSONs with byte-identical content to Plan 01 (Swift side).
    `decodeOutbound` never throws (returns Result), per RESEARCH §HUD-03 JS pattern sketch.

    **1. `webview/package.json`** (workspace root):
    ```json
    {
      "name": "jarvis-webview-workspace",
      "private": true,
      "version": "0.0.0",
      "packageManager": "pnpm@9.15.0",
      "engines": { "node": ">=20.0.0" },
      "scripts": {
        "test": "pnpm -r test",
        "build": "pnpm -r build",
        "typecheck": "pnpm -r typecheck"
      },
      "devDependencies": {
        "typescript": "^5.5.0",
        "vitest": "^2.1.0",
        "@types/node": "^20.0.0"
      }
    }
    ```
    Note: verify exact latest pnpm version acceptable to the user's local install
    at execution time — `packageManager` pinning is best practice but the
    user's `corepack enable` setup may or may not be active. If
    `npm view pnpm version` returns a different major, use that.

    **2. `webview/pnpm-workspace.yaml`:**
    ```yaml
    packages:
      - "packages/*"
    ```

    **3. `webview/.gitignore`:**
    ```
    node_modules/
    dist/
    coverage/
    .vitest-cache/
    *.tsbuildinfo
    ```

    **4. `webview/tsconfig.base.json`** — shared strict config:
    ```json
    {
      "compilerOptions": {
        "target": "ES2022",
        "module": "ESNext",
        "moduleResolution": "bundler",
        "strict": true,
        "noImplicitAny": true,
        "noImplicitReturns": true,
        "noFallthroughCasesInSwitch": true,
        "exactOptionalPropertyTypes": true,
        "noUncheckedIndexedAccess": true,
        "esModuleInterop": true,
        "skipLibCheck": true,
        "isolatedModules": true,
        "resolveJsonModule": true,
        "lib": ["ES2022", "DOM"]
      }
    }
    ```

    **5. `webview/packages/bus/package.json`:**
    ```json
    {
      "name": "@jarvis/bus",
      "private": true,
      "version": "0.0.0",
      "type": "module",
      "main": "dist/index.js",
      "types": "dist/index.d.ts",
      "exports": {
        ".": {
          "types": "./dist/index.d.ts",
          "import": "./dist/index.js"
        },
        "./fixtures/*": "./fixtures/*"
      },
      "scripts": {
        "build": "tsc -p tsconfig.json",
        "typecheck": "tsc -p tsconfig.json --noEmit",
        "test": "vitest run"
      },
      "devDependencies": {
        "typescript": "^5.5.0",
        "vitest": "^2.1.0"
      }
    }
    ```

    **6. `webview/packages/bus/tsconfig.json`:**
    ```json
    {
      "extends": "../../tsconfig.base.json",
      "compilerOptions": {
        "outDir": "dist",
        "rootDir": "src",
        "declaration": true,
        "declarationMap": true,
        "sourceMap": true,
        "composite": true
      },
      "include": ["src/**/*"],
      "exclude": ["tests/**/*", "dist/**/*", "node_modules/**/*"]
    }
    ```

    **7. `webview/packages/bus/vitest.config.ts`:**
    ```typescript
    import { defineConfig } from "vitest/config";

    export default defineConfig({
      test: {
        globals: false,
        environment: "node",
        include: ["tests/**/*.test.ts"],
      },
    });
    ```

    **8. `webview/packages/bus/src/protocol.ts`** — the core. Follow RESEARCH
    §SEC-09 TS mirror pattern. Key rules:
    - `BUS_PROTOCOL_VERSION` as a `const` string literal, exact value `"2.0.0"`.
    - `HudState` and `TurnTerminator` as string-literal unions (match Swift
      `enum: String` cases exactly).
    - `BusOutbound` and `BusInbound` as discriminated unions with `type`
      literal discriminator.
    - `decodeOutbound` and `decodeInbound` each return
      `{ok: true, value} | {ok: false, error}`. NEVER throw. Parse via
      `JSON.parse` inside `try/catch`; unknown `type` falls into the `never`
      sentinel branch and returns `{ok: false, error: "unknown type: ..."}`.
    - `encodeOutbound`/`encodeInbound` are thin wrappers around `JSON.stringify`
      — exposed as functions (not `JSON.stringify` directly) so consumers
      don't couple to the serialization primitive.

    Full source:
    ```typescript
    export const BUS_PROTOCOL_VERSION = "2.0.0";

    export type HudState =
      | "idle"
      | "listening"
      | "thinking"
      | "speaking"
      | "awaitingConfirmation"
      | "reconfiguring"
      | "booting";

    export type TurnTerminator =
      | "completed"
      | "cancelled"
      | "errored"
      | "superseded";

    export type BusOutbound =
      | { type: "hello"; version: string }
      | { type: "hudState"; state: HudState }
      | { type: "tokenDelta"; text: string }
      | { type: "audioLevel"; rms: number }
      | { type: "toolCallStart"; id: string; name: string; argsPreview: string }
      | { type: "toolCallEnd"; id: string; ok: boolean; previewOrError: string }
      | { type: "turnStarted"; id: string }
      | { type: "turnEnded"; id: string; terminator: TurnTerminator };

    export type BusInbound =
      | { type: "helloAck"; version: string }
      | { type: "uiReady" };

    export type DecodeResult<T> =
      | { ok: true; value: T }
      | { ok: false; error: string };

    function isObject(v: unknown): v is Record<string, unknown> {
      return typeof v === "object" && v !== null && !Array.isArray(v);
    }

    export function decodeOutbound(json: string): DecodeResult<BusOutbound> {
      let parsed: unknown;
      try {
        parsed = JSON.parse(json);
      } catch (e) {
        return { ok: false, error: `parse error: ${String(e)}` };
      }
      if (!isObject(parsed)) return { ok: false, error: "payload is not an object" };
      if (typeof parsed.type !== "string") return { ok: false, error: "missing discriminator" };

      // Narrow by discriminator. Switches below cover every `BusOutbound.type`.
      // The `_exhaustive: never` branch catches forgotten additions at compile time.
      switch (parsed.type) {
        case "hello":
          if (typeof parsed.version !== "string") return { ok: false, error: "hello: version must be string" };
          return { ok: true, value: { type: "hello", version: parsed.version } };
        case "hudState":
          if (typeof parsed.state !== "string") return { ok: false, error: "hudState: state must be string" };
          if (!isHudState(parsed.state)) return { ok: false, error: `hudState: unknown state '${parsed.state}'` };
          return { ok: true, value: { type: "hudState", state: parsed.state } };
        case "tokenDelta":
          if (typeof parsed.text !== "string") return { ok: false, error: "tokenDelta: text must be string" };
          return { ok: true, value: { type: "tokenDelta", text: parsed.text } };
        case "audioLevel":
          if (typeof parsed.rms !== "number") return { ok: false, error: "audioLevel: rms must be number" };
          return { ok: true, value: { type: "audioLevel", rms: parsed.rms } };
        case "toolCallStart":
          if (typeof parsed.id !== "string" || typeof parsed.name !== "string" || typeof parsed.argsPreview !== "string") {
            return { ok: false, error: "toolCallStart: invalid fields" };
          }
          return { ok: true, value: { type: "toolCallStart", id: parsed.id, name: parsed.name, argsPreview: parsed.argsPreview } };
        case "toolCallEnd":
          if (typeof parsed.id !== "string" || typeof parsed.ok !== "boolean" || typeof parsed.previewOrError !== "string") {
            return { ok: false, error: "toolCallEnd: invalid fields" };
          }
          return { ok: true, value: { type: "toolCallEnd", id: parsed.id, ok: parsed.ok, previewOrError: parsed.previewOrError } };
        case "turnStarted":
          if (typeof parsed.id !== "string") return { ok: false, error: "turnStarted: id must be string" };
          return { ok: true, value: { type: "turnStarted", id: parsed.id } };
        case "turnEnded":
          if (typeof parsed.id !== "string" || typeof parsed.terminator !== "string") {
            return { ok: false, error: "turnEnded: invalid fields" };
          }
          if (!isTurnTerminator(parsed.terminator)) {
            return { ok: false, error: `turnEnded: unknown terminator '${parsed.terminator}'` };
          }
          return { ok: true, value: { type: "turnEnded", id: parsed.id, terminator: parsed.terminator } };
        default: {
          // Compile-time exhaustiveness: adding a case to BusOutbound without
          // extending this switch fails `tsc --strict` at this line.
          const _exhaustive: never = parsed.type as never;
          return { ok: false, error: `unknown type: ${String(parsed.type)}` };
        }
      }
    }

    export function decodeInbound(json: string): DecodeResult<BusInbound> {
      let parsed: unknown;
      try {
        parsed = JSON.parse(json);
      } catch (e) {
        return { ok: false, error: `parse error: ${String(e)}` };
      }
      if (!isObject(parsed)) return { ok: false, error: "payload is not an object" };
      if (typeof parsed.type !== "string") return { ok: false, error: "missing discriminator" };
      switch (parsed.type) {
        case "helloAck":
          if (typeof parsed.version !== "string") return { ok: false, error: "helloAck: version must be string" };
          return { ok: true, value: { type: "helloAck", version: parsed.version } };
        case "uiReady":
          return { ok: true, value: { type: "uiReady" } };
        default: {
          const _exhaustive: never = parsed.type as never;
          return { ok: false, error: `unknown type: ${String(parsed.type)}` };
        }
      }
    }

    export function encodeOutbound(msg: BusOutbound): string {
      return JSON.stringify(msg);
    }

    export function encodeInbound(msg: BusInbound): string {
      return JSON.stringify(msg);
    }

    // Type guards — defined as arrays so changes to the union are caught by
    // the `satisfies readonly HudState[]` check at compile time.
    const HUD_STATES = [
      "idle", "listening", "thinking", "speaking",
      "awaitingConfirmation", "reconfiguring", "booting",
    ] as const satisfies readonly HudState[];

    const TURN_TERMINATORS = [
      "completed", "cancelled", "errored", "superseded",
    ] as const satisfies readonly TurnTerminator[];

    function isHudState(v: string): v is HudState {
      return (HUD_STATES as readonly string[]).includes(v);
    }

    function isTurnTerminator(v: string): v is TurnTerminator {
      return (TURN_TERMINATORS as readonly string[]).includes(v);
    }
    ```

    **9. `webview/packages/bus/src/index.ts`** — re-exports (bridge.ts added in Task 2):
    ```typescript
    export * from "./protocol.js";
    // bridge.ts exports installJarvisBus — added in Task 2
    ```

    **10. 14 fixture files under `webview/packages/bus/fixtures/`** — byte-identical
    content to Plan 01 Swift fixtures. Plan 04 asserts parity. Exact contents
    (same as Plan 01 Task 1):
    - `hello.json`: `{"type":"hello","version":"2.0.0"}`
    - `helloAck.json`: `{"type":"helloAck","version":"2.0.0"}`
    - `hudState.idle.json`: `{"type":"hudState","state":"idle"}`
    - `hudState.listening.json`: `{"type":"hudState","state":"listening"}`
    - `hudState.thinking.json`: `{"type":"hudState","state":"thinking"}`
    - `hudState.speaking.json`: `{"type":"hudState","state":"speaking"}`
    - `hudState.awaitingConfirmation.json`: `{"type":"hudState","state":"awaitingConfirmation"}`
    - `hudState.reconfiguring.json`: `{"type":"hudState","state":"reconfiguring"}`
    - `hudState.booting.json`: `{"type":"hudState","state":"booting"}`
    - `tokenDelta.json`: `{"type":"tokenDelta","text":"Hello, world!"}`
    - `audioLevel.json`: `{"type":"audioLevel","rms":0.42}`
    - `toolCallStart.json`: `{"type":"toolCallStart","id":"550e8400-e29b-41d4-a716-446655440000","name":"get_time","argsPreview":"{}"}`
    - `toolCallEnd.json`: `{"type":"toolCallEnd","id":"550e8400-e29b-41d4-a716-446655440000","ok":true,"previewOrError":"\"2026-04-23T16:00:00Z\""}`
    - `turnStarted.json`: `{"type":"turnStarted","id":"6ba7b810-9dad-11d1-80b4-00c04fd430c8"}`
    - `turnEnded.json`: `{"type":"turnEnded","id":"6ba7b810-9dad-11d1-80b4-00c04fd430c8","terminator":"completed"}`

    **11. `webview/packages/bus/tests/round-trip.test.ts`** — Vitest suite:
    ```typescript
    import { describe, it, expect } from "vitest";
    import { readFileSync } from "node:fs";
    import { join } from "node:path";
    import {
      BUS_PROTOCOL_VERSION,
      decodeOutbound,
      decodeInbound,
      encodeOutbound,
      encodeInbound,
    } from "../src/protocol.js";

    const FIX = join(__dirname, "..", "fixtures");

    function readFixture(name: string): { raw: string; parsed: unknown } {
      const raw = readFileSync(join(FIX, name), "utf-8");
      return { raw, parsed: JSON.parse(raw) };
    }

    describe("BUS_PROTOCOL_VERSION", () => {
      it("equals 2.0.0 (must match Swift constant)", () => {
        expect(BUS_PROTOCOL_VERSION).toBe("2.0.0");
      });
    });

    describe("BusOutbound round-trip", () => {
      const outboundFixtures = [
        "hello.json",
        "hudState.idle.json",
        "hudState.listening.json",
        "hudState.thinking.json",
        "hudState.speaking.json",
        "hudState.awaitingConfirmation.json",
        "hudState.reconfiguring.json",
        "hudState.booting.json",
        "tokenDelta.json",
        "audioLevel.json",
        "toolCallStart.json",
        "toolCallEnd.json",
        "turnStarted.json",
        "turnEnded.json",
      ];

      for (const name of outboundFixtures) {
        it(`decodes and re-encodes ${name}`, () => {
          const { raw, parsed } = readFixture(name);
          const result = decodeOutbound(raw);
          expect(result.ok, `decode failed: ${result.ok ? "" : result.error}`).toBe(true);
          if (!result.ok) return;
          const reEncoded = JSON.parse(encodeOutbound(result.value));
          expect(reEncoded).toEqual(parsed);
        });
      }
    });

    describe("BusInbound round-trip", () => {
      it("decodes and re-encodes helloAck.json", () => {
        const { raw, parsed } = readFixture("helloAck.json");
        const result = decodeInbound(raw);
        expect(result.ok).toBe(true);
        if (!result.ok) return;
        expect(JSON.parse(encodeInbound(result.value))).toEqual(parsed);
      });
    });

    describe("decodeOutbound error paths", () => {
      it("returns ok:false on unknown type", () => {
        const r = decodeOutbound(`{"type":"unknown"}`);
        expect(r.ok).toBe(false);
        if (!r.ok) expect(r.error).toContain("unknown type");
      });

      it("returns ok:false on malformed JSON", () => {
        const r = decodeOutbound(`{not json`);
        expect(r.ok).toBe(false);
        if (!r.ok) expect(r.error).toContain("parse error");
      });

      it("returns ok:false on missing discriminator", () => {
        const r = decodeOutbound(`{"version":"2.0.0"}`);
        expect(r.ok).toBe(false);
        if (!r.ok) expect(r.error).toContain("missing discriminator");
      });

      it("returns ok:false on invalid hudState", () => {
        const r = decodeOutbound(`{"type":"hudState","state":"garbage"}`);
        expect(r.ok).toBe(false);
      });

      it("returns ok:false on non-object payload", () => {
        const r = decodeOutbound(`"just a string"`);
        expect(r.ok).toBe(false);
      });
    });
    ```

    **TDD flow:** Write `round-trip.test.ts` first against stub
    `decodeOutbound`/`encodeOutbound` returning `{ok: false}` for everything;
    watch all assertions fail; fill in `protocol.ts` case-by-case until each
    fixture goes green. Commit RED → GREEN atomically per task.
  </action>
  <verify>
    <automated>cd webview && pnpm install --ignore-scripts && pnpm --filter @jarvis/bus exec tsc --noEmit && pnpm --filter @jarvis/bus exec vitest run tests/round-trip.test.ts</automated>
  </verify>
  <done>
    14 fixture files exist with the exact contents specified (byte-match Plan 01 Swift mirror).
    `pnpm --filter @jarvis/bus test` green — all round-trip + error-path cases pass.
    `BUS_PROTOCOL_VERSION === "2.0.0"` in both sides (grep-verifiable).
    `tsc --noEmit` green under strict mode for `src/protocol.ts`.
    `grep -c '_exhaustive: never' webview/packages/bus/src/protocol.ts` >= 2 (once per decode function).
  </done>
</task>

<task type="auto" tdd="true">
  <name>Task 2: bridge.ts (window.jarvisBus glue) + bridge.test.ts + bus-harness.html</name>
  <files>
    webview/packages/bus/src/bridge.ts,
    webview/packages/bus/src/index.ts,
    webview/packages/bus/tests/bridge.test.ts,
    webview/bus-harness.html
  </files>
  <behavior>
    - Test 1: After `installJarvisBus()`, `window.jarvisBus.receive` is defined and dispatches decoded `BusOutbound` to the registered handler
    - Test 2: `window.jarvisBus.receive("{not json")` logs an error via the injected `onDecodeError` callback (injectable for test) but does not throw
    - Test 3: `window.jarvisBus.send(inbound)` calls `window.webkit.messageHandlers.jarvisBus.postMessage(jsonString)` with the encoded inbound message, returns the Promise
    - Test 4: `window.jarvisBus.onOutbound(handler)` replaces the previous handler (latest wins)
    - Test 5: Before `onOutbound` is called, `receive` still accepts messages and logs a warning — does not drop them silently
    - Test 6: `bus-harness.html` exists and imports `dist/bus.js` via `<script type="module">`, calls `installJarvisBus()`, and `window.jarvisBus.onOutbound` auto-responds to `hello` by calling `window.jarvisBus.send({type:"helloAck", version: BUS_PROTOCOL_VERSION})` — no other behavior
  </behavior>
  <action>
    **Decisions honored:** `window.jarvisBus` as the single glue point per RESEARCH §HUD-04 JS sketch.
    Static HTML + compiled bundle per RESEARCH open question #1 (full Vite deferred to P3).
    Auto-ack in harness HTML so Plan 03 can wire up `loadFileURL` + observe `handshakeState == .armed`.
    Inject `onDecodeError` callback (not a bare `console.error`) so tests can capture decode failures.

    **1. `webview/packages/bus/src/bridge.ts`:**
    ```typescript
    import {
      BUS_PROTOCOL_VERSION,
      decodeOutbound,
      encodeInbound,
      type BusInbound,
      type BusOutbound,
    } from "./protocol.js";

    export type OutboundHandler = (msg: BusOutbound) => void;
    export type DecodeErrorHandler = (error: string, raw: string) => void;

    // The shape Swift's WKScriptMessageHandlerWithReply produces on the JS side.
    // webkit.messageHandlers.jarvisBus.postMessage returns a Promise that
    // resolves to whatever the Swift replyHandler passed.
    declare global {
      interface Window {
        jarvisBus: JarvisBus;
        webkit?: {
          messageHandlers: {
            jarvisBus: { postMessage(body: unknown): Promise<unknown> };
          };
        };
      }
    }

    export interface JarvisBus {
      /** Called by Swift via `callAsyncJavaScript("window.jarvisBus.receive(payload)", ...)`. */
      receive(payload: string): void;
      /** Send a BusInbound to Swift. Returns the Promise resolved by Swift's replyHandler. */
      send(msg: BusInbound): Promise<unknown>;
      /** Register the outbound handler (latest wins). Auto-responds to `hello` internally if unset. */
      onOutbound(handler: OutboundHandler): void;
      readonly protocolVersion: string;
    }

    export interface InstallOptions {
      onDecodeError?: DecodeErrorHandler;
    }

    /**
     * Install `window.jarvisBus`. Call once at document-start. The returned
     * cleanup function is for tests — production code never calls it.
     *
     * Behavior:
     * - `receive(payload)` decodes via `decodeOutbound`; valid messages go to
     *   the registered `onOutbound` handler; decode failures go to
     *   `onDecodeError` (default: `console.error`).
     * - If a `hello` message arrives BEFORE `onOutbound` is registered, the
     *   bridge synthesizes the `helloAck` response itself so the handshake
     *   completes even with a minimal harness.
     * - `send(msg)` JSON-encodes and posts to `webkit.messageHandlers.jarvisBus`.
     *   Callers await the returned Promise to observe Swift's reply.
     */
    export function installJarvisBus(options: InstallOptions = {}): () => void {
      const onDecodeError: DecodeErrorHandler =
        options.onDecodeError ?? ((error, raw) => {
          // eslint-disable-next-line no-console
          console.error("[bus] decode failed:", error, raw);
        });

      let handler: OutboundHandler | null = null;
      let pendingHello: BusOutbound | null = null;

      const bus: JarvisBus = {
        protocolVersion: BUS_PROTOCOL_VERSION,

        receive(payload: string): void {
          const result = decodeOutbound(payload);
          if (!result.ok) {
            onDecodeError(result.error, payload);
            return;
          }
          if (handler) {
            handler(result.value);
          } else if (result.value.type === "hello") {
            // Auto-ack the handshake even if no handler is registered. This is
            // what bus-harness.html relies on — the stub HTML loads, receives
            // hello, and replies without needing any page-side code.
            void bus.send({ type: "helloAck", version: BUS_PROTOCOL_VERSION });
          } else {
            pendingHello = result.value;
            onDecodeError("received message before onOutbound handler", payload);
          }
        },

        async send(msg: BusInbound): Promise<unknown> {
          const json = encodeInbound(msg);
          if (!window.webkit?.messageHandlers?.jarvisBus) {
            throw new Error("[bus] webkit.messageHandlers.jarvisBus is not available");
          }
          return window.webkit.messageHandlers.jarvisBus.postMessage(json);
        },

        onOutbound(newHandler: OutboundHandler): void {
          handler = newHandler;
          if (pendingHello) {
            newHandler(pendingHello);
            pendingHello = null;
          }
        },
      };

      window.jarvisBus = bus;
      return () => { /* test cleanup — noop in production */ };
    }
    ```

    Note: the auto-ack is load-bearing for the P2 harness. It exists because
    `bus-harness.html` is a minimal stub with no page-side handler registered;
    P3's real HUD code will register `onOutbound` early enough that this
    branch never fires in production.

    **2. Update `webview/packages/bus/src/index.ts`:**
    ```typescript
    export * from "./protocol.js";
    export * from "./bridge.js";
    ```

    **3. `webview/packages/bus/tests/bridge.test.ts`** — Vitest suite. Mock
    `window` + `window.webkit` via `globalThis` or by defining them before
    `installJarvisBus()`.
    ```typescript
    import { describe, it, expect, beforeEach, vi } from "vitest";
    import { installJarvisBus } from "../src/bridge.js";
    import { BUS_PROTOCOL_VERSION } from "../src/protocol.js";

    describe("installJarvisBus", () => {
      let postMessage: ReturnType<typeof vi.fn>;

      beforeEach(() => {
        postMessage = vi.fn().mockResolvedValue({ ok: true });
        // @ts-expect-error — test shim
        globalThis.window = {
          webkit: { messageHandlers: { jarvisBus: { postMessage } } },
        };
      });

      it("installs window.jarvisBus with the correct protocol version", () => {
        installJarvisBus();
        expect(window.jarvisBus).toBeDefined();
        expect(window.jarvisBus.protocolVersion).toBe(BUS_PROTOCOL_VERSION);
      });

      it("dispatches decoded outbound to the registered handler", () => {
        installJarvisBus();
        const handler = vi.fn();
        window.jarvisBus.onOutbound(handler);
        window.jarvisBus.receive(`{"type":"hudState","state":"thinking"}`);
        expect(handler).toHaveBeenCalledWith({ type: "hudState", state: "thinking" });
      });

      it("auto-acks hello when no handler is registered", async () => {
        installJarvisBus();
        window.jarvisBus.receive(`{"type":"hello","version":"2.0.0"}`);
        // Let the async send fire
        await new Promise((r) => setTimeout(r, 0));
        expect(postMessage).toHaveBeenCalledWith(
          `{"type":"helloAck","version":"${BUS_PROTOCOL_VERSION}"}`
        );
      });

      it("surfaces decode errors to onDecodeError, does not throw", () => {
        const onDecodeError = vi.fn();
        installJarvisBus({ onDecodeError });
        expect(() => window.jarvisBus.receive(`{not json`)).not.toThrow();
        expect(onDecodeError).toHaveBeenCalled();
        const [error] = onDecodeError.mock.calls[0];
        expect(error).toContain("parse error");
      });

      it("send() JSON-encodes and posts to webkit.messageHandlers.jarvisBus", async () => {
        installJarvisBus();
        const reply = await window.jarvisBus.send({ type: "uiReady" });
        expect(postMessage).toHaveBeenCalledWith(`{"type":"uiReady"}`);
        expect(reply).toEqual({ ok: true });
      });

      it("throws helpful error if webkit is missing", async () => {
        // @ts-expect-error — test shim
        globalThis.window = {};
        installJarvisBus();
        await expect(window.jarvisBus.send({ type: "uiReady" })).rejects.toThrow(/webkit/);
      });

      it("onOutbound latest wins", () => {
        installJarvisBus();
        const a = vi.fn();
        const b = vi.fn();
        window.jarvisBus.onOutbound(a);
        window.jarvisBus.onOutbound(b);
        window.jarvisBus.receive(`{"type":"hudState","state":"idle"}`);
        expect(a).not.toHaveBeenCalled();
        expect(b).toHaveBeenCalledOnce();
      });
    });
    ```

    **4. `webview/bus-harness.html`** — static HTML Swift's WKWebView loads at P2:
    ```html
    <!DOCTYPE html>
    <html lang="en">
    <head>
      <meta charset="UTF-8">
      <meta name="viewport" content="width=device-width, initial-scale=1.0">
      <title>Jarvis Bus Harness</title>
      <style>
        body {
          background: transparent;
          margin: 0;
          font-family: -apple-system, BlinkMacSystemFont, sans-serif;
          color: #888;
        }
        .status {
          position: fixed;
          bottom: 8px;
          left: 8px;
          font-size: 10px;
          opacity: 0.4;
        }
      </style>
    </head>
    <body>
      <!-- P2-02 scope: static harness. P3 replaces this file with the
           real React + R3F entrypoint. -->
      <div class="status" id="status">jarvis-bus-harness</div>
      <script type="module">
        import { installJarvisBus, BUS_PROTOCOL_VERSION } from "./packages/bus/dist/index.js";
        installJarvisBus();
        const statusEl = document.getElementById("status");
        if (statusEl) statusEl.textContent = `jarvis-bus-harness v${BUS_PROTOCOL_VERSION}`;
      </script>
    </body>
    </html>
    ```
    Note: the import path `./packages/bus/dist/index.js` assumes the harness is
    loaded alongside the built `webview/packages/bus/dist/` output. Plan 03
    handles the bundle-copy step (post-build script that copies
    `webview/packages/bus/dist/` + `bus-harness.html` into
    `App/Resources/webview/` or `Contents/Resources/webview/`). If Plan 03
    changes the layout, this import path is the single place to update.

    **TDD flow:** Write `bridge.test.ts` first against an empty `bridge.ts`
    stub (all tests fail); fill in `installJarvisBus` body until green. Commit
    RED → GREEN atomically. Write `bus-harness.html` last — it's a static
    asset and its "correctness" is verified by the integration smoke in Plan 03.
  </action>
  <verify>
    <automated>cd webview && pnpm --filter @jarvis/bus exec vitest run tests/bridge.test.ts && pnpm --filter @jarvis/bus exec tsc --noEmit</automated>
  </verify>
  <done>
    `window.jarvisBus.receive` dispatches correctly; decode errors go to `onDecodeError` (not `throw`).
    `window.jarvisBus.send` posts JSON to `webkit.messageHandlers.jarvisBus` and returns a Promise.
    Auto-ack handshake works when no handler is registered (critical for bus-harness.html).
    `bus-harness.html` imports the compiled `./packages/bus/dist/index.js` and calls `installJarvisBus()`.
    `tsc --noEmit` green under strict mode; zero `any` types added (the `// @ts-expect-error` test shim is the only exception).
  </done>
</task>

</tasks>

<threat_model>
## Trust Boundaries

| Boundary | Description |
|----------|-------------|
| Swift → JS outbound | `callAsyncJavaScript` payload passes as a primitive string argument; JS calls `JSON.parse` inside `decodeOutbound` |
| JS → Swift inbound | JS encodes via `JSON.stringify` and calls `postMessage(jsonString)`; Swift re-parses |
| Page-script world | Isolated from `JarvisBusWorld` by Plan 01's `WKContentWorld.world(name:)`; page scripts cannot access `window.jarvisBus` injected into the bus world |

## STRIDE Threat Register

| Threat ID | Category | Component | Disposition | Mitigation Plan |
|-----------|----------|-----------|-------------|-----------------|
| T-02-08 | Tampering | `decodeOutbound` JSON.parse on crafted input | mitigate | `try/catch` around `JSON.parse`; returns `{ok: false, error}` — never throws. Unknown `type` hits the `never` sentinel and returns error. |
| T-02-09 | Tampering | `JSON.parse` prototype pollution via `__proto__` key | accept | V8/JavaScriptCore `JSON.parse` does NOT assign to `__proto__` (ES2022 spec). Single-user personal project; low risk. |
| T-02-10 | Information Disclosure | `window.jarvisBus` leak to page world | mitigate | P3 installs bridge via `WKUserScript` at `.atDocumentStart` in `WKContentWorld.world(name:"JarvisBusWorld")` — page scripts cannot access. P2 harness is the entire page so there are no competing scripts. |
| T-02-11 | Tampering | SE-0295-equivalent drift on TS side | mitigate | `const _exhaustive: never = parsed.type as never;` at decode default branch — `tsc --strict` fails if a union member is added without a case. Plan 04's parity script adds build-time enforcement that Swift + TS case counts match. |
| T-02-12 | Spoofing | Crafted `helloAck` from untrusted origin | accept | Webview loads only from `file://` bundle URL (P3 sets `WKURLSchemeHandler` policy); no remote content. |
</threat_model>

<verification>
**TypeScript strict-mode compile:**
- `cd webview && pnpm --filter @jarvis/bus exec tsc --noEmit` — zero errors.
- `grep -c ': any' webview/packages/bus/src/*.ts` — zero (outside of `as never` sentinel).

**Vitest suites:**
- `cd webview && pnpm --filter @jarvis/bus test` — round-trip + bridge suites both green.

**Parity precondition (Plan 04 enforces at build time, but P2-02 asserts now):**
- `diff webview/packages/bus/fixtures/ packages/Bus/Tests/BusTests/Fixtures/` shows no differences. Byte-equal.
- `grep 'BUS_PROTOCOL_VERSION' webview/packages/bus/src/protocol.ts packages/Bus/Sources/Bus/Protocol.swift` shows both constants at `"2.0.0"`.

**Harness HTML manual smoke (for Plan 03 to wire):**
- Build the TS package: `cd webview && pnpm --filter @jarvis/bus build` produces `dist/index.js` + `dist/index.d.ts`.
- Load `bus-harness.html` in a Safari window — `window.jarvisBus` is defined; check via DevTools console: `window.jarvisBus.protocolVersion === "2.0.0"`.
</verification>

<success_criteria>
1. `webview/package.json` + `webview/pnpm-workspace.yaml` exist; `pnpm install` succeeds.
2. `webview/packages/bus/` contains the @jarvis/bus package with strict TS config.
3. `BUS_PROTOCOL_VERSION === "2.0.0"` in `webview/packages/bus/src/protocol.ts` — byte-identical to Swift.
4. 14 fixture files exist at `webview/packages/bus/fixtures/` with the exact contents specified (byte-equal to Plan 01 Swift fixtures).
5. `decodeOutbound` and `decodeInbound` never throw — always return `DecodeResult<T>`.
6. Each decoder has an exhaustive switch with a `const _exhaustive: never = ...` default sentinel for compile-time drift detection.
7. `installJarvisBus()` exposes `window.jarvisBus` with `receive` / `send` / `onOutbound` / `protocolVersion`.
8. Auto-ack of `hello` works when no handler is registered (load-bearing for the harness).
9. `bus-harness.html` imports compiled bundle and calls `installJarvisBus()` on load.
10. `pnpm --filter @jarvis/bus test` is green (both round-trip and bridge suites).
11. `pnpm --filter @jarvis/bus exec tsc --noEmit` green under `strict: true`.
</success_criteria>

<output>
After completion, create `.planning/phases/02-bus/02-02-SUMMARY.md` covering:
- Files created (1 workspace root + 1 base tsconfig + 1 pnpm config + 8 @jarvis/bus source/config + 14 fixtures + 2 test files + 1 harness HTML)
- Key decisions: hand-written TS mirror (no codegen), auto-ack in harness (so minimal page completes handshake), `DecodeResult<T>` non-throwing contract, `_exhaustive: never` sentinel for compile-time exhaustiveness
- Tech-stack adds: pnpm 9.x workspace, TypeScript 5.5+, Vitest 2.x — first TS content in the repo
- Patterns established: `@jarvis/*` scoped TS packages under `webview/packages/`; `DecodeResult<T>` return shape for all bus decoders (extends to P3); strict tsconfig inheritance pattern
- Requirements completed: HUD-03 (JS side of inbound; peer of Swift side from Plan 01), HUD-05 (TS `BUS_PROTOCOL_VERSION` pinned at `"2.0.0"` — handshake partner), SEC-09 (TS round-trip fixtures + exhaustive discriminator switches)
- Handoff to Plan 03 (real `callAsyncJavaScript` send in Swift; `loadFileURL` points to `bus-harness.html`; post-build script copies `dist/` + harness) and Plan 04 (parity script diffs fixtures + greps constants + runs `pnpm --filter @jarvis/bus test`)
</output>
