---
phase: 3
slug: hud
researched: 2026-04-22
researcher: gsd-phase-researcher
confidence: MEDIUM-HIGH
depends-on-phase: 2
requirements-covered: [HUD-01, HUD-02, HUD-07, HUD-08, TEXT-02]
---

# Phase 3 — HUD: Research

> How to land a cinematic R3F particle ring that reflects all seven agent states from Swift-side truth, surface tool-call lifecycle as expandable chat-panel cards, and render streamed tokens token-by-token inlined with tool-call events in chronological order — under Swift 6 strict concurrency, WKWebView Hardened-Runtime, and the P2 typed-JSON bus.

## Summary

Phase 3 is the cinematic face of Jarvis. P1 already built the shell (`JarvisHUDPanel` with a transparent `WKWebView`, menu-bar state animations, banner coordinator, Reduce Transparency / Reduce Motion fallbacks). P2 builds the typed JSON bus with `BUS_PROTOCOL_VERSION` handshake, `callAsyncJavaScript(arguments:)` outbound, `WKScriptMessageHandlerWithReply` inbound, and OutboundBatcher. **P3 is where the ring shows up and the chat panel reacts.**

Five research spines converge here:

1. **R3F 9 + drei 10.7 + three r184 + Zustand 5 + Vite 8 stack** — all five are current (R3F 9.6.0 paired with React 19, drei 10.7.6, three r184). R3F 9 is *the* release line for React 19 compatibility. Vite 8 ships Rolldown bundler + Lightning CSS by default; builds are 10-30× faster than Vite 7.
2. **`HudStateCoordinator` as Swift-side keystone** — `@MainActor final class` owning three `for await` loops (agent, voice, confirm) merged into an `AsyncStream<HudStateIntent>` multi-producer single-consumer pattern. Precedence ladder resolves `awaitingConfirmation > speaking > listening > thinking > idle > booting > reconfiguring` before `bridge.send(.hudState)`.
3. **Particle-ring anatomy** — single `THREE.Points` geometry with `ShaderMaterial` (via drei's `shaderMaterial`) is the 2026-standard pattern. State-driven animation happens in vertex/fragment uniforms updated in `useFrame`, NEVER by React state changes to the mesh. Smooth interpolation between states uses GLSL `mix()` on time-based uniforms. **Instancing is wrong for a single ring**; it's a one-geometry-many-draws tool, and we have one object. Use `Points` with an `InstancedBufferGeometry` only if we later want per-particle variant attributes.
4. **Event-log rendering pattern for chat panel** — the Vercel AI SDK 5 `UIMessage.parts` shape is the industry-standard 2026 pattern: an ordered array of typed discriminated parts (`text`, `tool-call`, `tool-result`, `reasoning`) that renders chronologically. We adopt the *shape* (not the SDK itself — we don't need its server-side streaming infra) and keep tool-call cards inlined via part ordering, not via a separate tool-call rail.
5. **Token-by-token rendering discipline** — never `setState` per token. Buffer incoming `tokenDelta` events in a mutable ref, flush via `requestAnimationFrame` (or rely on P2's OutboundBatcher @ ~30 Hz). This is the "ChatGPT streams smoothly" pattern; naive per-token setState drops to 20 FPS on sustained streams.

**Primary recommendation:** Build the webview as a separate `webview/` workspace with pnpm + Vite 8 (Rolldown). Ship a single bundle to `App/Resources/webview/` via a pre-build script invoked by Xcode's `postBuildScripts`. The bundle loads via `loadFileRequest(_:allowingReadAccessTo:)` pointing at the `webview/` *directory* (not the single `index.html`) so CSS/JS chunks load correctly. A single Zustand 5 store, hydrated by messages on the P2 bus, drives both the R3F ring (via `useFrame`-read uniforms) and the chat-panel React components (via selective `useStore` selectors).

## User Constraints (from upstream context)

### Locked Decisions (from CLAUDE.md + PROJECT.md + REQUIREMENTS)

- Stack: React 19 + R3F 9 + drei 10.7 + three r184 + Zustand 5 + Vite 8 (from HUD-01 wording — verbatim).
- Panel transparency already solved in P1 (`JarvisHUDPanel.swift` — `drawsBackground=false` + `underPageBackgroundColor=.clear` + Reduce Transparency fallback).
- `HudState` enum lives in `App/Theme/HudState.swift`. P1 ships 5 cases (`idle, listening, thinking, speaking, awaitingConfirmation`). P3 **must** extend to 7: add `.booting`, `.reconfiguring`.
- `HudStateCoordinator` must be `@MainActor final class` (not `actor` — Swift cannot bind an `actor` to MainActor).
- Bus outbound is `callAsyncJavaScript(arguments:)` with JSON payload as primitive string. Never interpolate into `evaluateJavaScript`. (Enforced by P2 lint.)
- Bus uses `type` discriminator with hand-written `Codable` + exhaustive switches (no `default` branches).
- High-frequency events coalesce at ~30 Hz via OutboundBatcher (P2); state transitions flush immediately.
- Tool calls surface as **both** ring-state shift AND expandable chat-panel cards (HUD-07). Ring-color-only is a test failure.
- Confirmation broker modals are **forbidden** on webview; they live in a native hidden NSPanel (P5 concern, but ring shows `.awaitingConfirmation` here).
- Hardened Runtime + `allow-jit` entitlement is load-bearing for WKWebView JIT (P1 landed this).

### Claude's Discretion (this phase's open options)

- Webview package layout: single `webview/` at repo root vs `packages/webview-*` SPM-style split. Research recommendation: **single `webview/` at repo root** (SPM doesn't apply to TS anyway, and a split adds pnpm workspace overhead we don't need yet).
- Ring geometry: `THREE.Points` vs `InstancedMesh` vs shader-driven primitive. Research recommendation: **`THREE.Points` with a `BufferGeometry` of 512-1024 particles + drei `shaderMaterial`**. Single draw call; vertex shader owns the ring math; CPU updates only uniforms.
- Chat-panel rendering strategy. Research recommendation: **Ordered `ChatEvent` array in Zustand, rendered as a flat list.** No virtualization in P3 (we have <100 events per session this early; virtualize in P8 hardening if profiling shows need).
- CSS strategy: Tailwind vs CSS Modules vs vanilla CSS vars. Research recommendation: **vanilla CSS + CSS custom properties** (HUD has <10 visible components; Tailwind is overkill for this surface; design tokens live in a single `tokens.css` sourced from Swift's `BrandColors`).
- Testing: Vitest + React Testing Library for component logic; Playwright ring visual regression test gated behind `--grep @visual` in P8.

### Deferred (OUT OF SCOPE for P3)

- Multi-panel holographic HUD (HUD-V2-01, V2-02, V2-03).
- Ambient corner mode (HUD-V2-03).
- DevOverlay UI (lands in P4 with the orchestrator).
- Settings pane UI.
- Markdown rendering inside chat bubbles — P3 renders plain text streams + tool-call cards; markdown can come in P4 or later.
- Memory-updated toast / MEM-08 DevOverlay row (P7).
- Voice-input waveform (P6).

## Phase Requirements

| ID | Description | Research Support |
|----|-------------|------------------|
| HUD-01 | WKWebView hosts R19 + R3F 9 + drei 10.7 + three r184 + Zustand 5 + Vite 8; single particle ring renders reactive to all 7 states | §Standard Stack (verified versions), §Architecture Patterns (Vite-to-bundle-to-WKWebView flow), §Code Examples (R3F ring scaffold) |
| HUD-02 | Seven distinct visual states: idle / listening / thinking / speaking / awaitingConfirmation / reconfiguring / booting | §Particle Ring Visual Design — state-to-uniform map; GLSL `mix()` interpolation between states; Reduce Motion fallback per state |
| HUD-07 | Tool calls surface as ring-state shift AND expandable chat-panel cards with lifecycle (pending / running / awaiting-approval / completed / failed) | §Tool-Call Lifecycle Cards — ChatEvent.kind discriminator, card component, expand/collapse state, lifecycle state machine |
| HUD-08 | HudStateCoordinator is @MainActor final class, sole writer, precedence `awaitingConfirmation > speaking > listening > thinking > idle > booting > reconfiguring` | §HudStateCoordinator — AsyncStream merge pattern, precedence resolver, single `bridge.send` callsite, test matrix for precedence pairs |
| TEXT-02 | Streaming tokens render token-by-token into chat panel; tool-call cards inlined in chronological order | §Streaming Tokens + Chronological Inlining — RAF buffer, Zustand append-to-last-text-part pattern, tool-call insert-before-current-text |

## Architectural Responsibility Map

| Capability | Primary Tier | Secondary Tier | Rationale |
|------------|--------------|----------------|-----------|
| HUD state truth (current agent state) | Swift `HudStateCoordinator` | — | Single-writer invariant requires Swift ownership; webview is a pure render layer |
| Rendering the particle ring | Webview (R3F/WebGL) | — | WebGL shaders can't run in Swift; SwiftUI can't match R3F's particle/shader ergonomics |
| Chat message log persistence | Swift (in-memory ring in P3; SQLite in P4 ReplayLog) | — | Webview memory dies with panel dismiss; truth lives in Swift |
| Chat message rendering | Webview (React) | — | React's flat-list + Zustand selector model is well-suited |
| Token-buffer batching | Webview (RAF on React side) | Swift OutboundBatcher | OutboundBatcher flushes events @ 30 Hz; React can trust event cadence and NOT double-buffer for `tokenDelta` |
| State transition events (low-freq) | Swift, immediate-flush out of batcher | Webview Zustand `setState` | HUD state changes must be near-instant perceived; skip batching (HUD-06 in P2) |
| Tool-call lifecycle (pending → running → …) | Swift orchestrator (P4) emits events; Webview renders cards | — | Lifecycle truth lives with orchestrator; React subscribes to the event stream |
| Confirmation UI for destructive tools | Swift native NSPanel (P5) | Webview ring shift to `.awaitingConfirmation` | No modals in webview (lint-enforced from P5) |
| Reduce Motion / Reduce Transparency fallback | Both | — | macOS accessibility is a native signal; emit it from Swift over the bus; React applies CSS and R3F skips animations |
| Brand color tokens (arc-reactor glow etc.) | Swift `BrandColors.swift` | Webview CSS vars | Single source of truth in Swift; export to a `tokens.css` build step or emit via bus on startup |

## Standard Stack

### Core

| Library | Version | Purpose | Why Standard |
|---------|---------|---------|--------------|
| `react` | `^19.2.0` | UI framework | [VERIFIED: R3F 9.6.0 release notes — "pairs with react@19"]; React 19.2 adds Activity (compatible) |
| `react-dom` | `^19.2.0` | DOM renderer | Peer of `react` |
| `@react-three/fiber` | `^9.6.0` | React renderer for three.js | [VERIFIED: npmjs — 9.6.0 last published 2026-04-17]; **this is the React-19-compatible line**; R3F 8.x is React 18 only |
| `@react-three/drei` | `^10.7.6` | R3F helpers (`shaderMaterial`, `useAspect`, `Points`, `PointMaterial`) | [VERIFIED: unpkg URL resolves to 10.7.6]; drei 10.x pairs with R3F 9 |
| `three` | `^0.184.0` (r184) | Core WebGL engine | [VERIFIED: three.js r184 GitHub release]; r184 added `OnFrameUpdate`/`OnBeforeFrameUpdate` and 3× shader-compile perf |
| `zustand` | `^5.0.0` | State management + external store | [VERIFIED: Zustand 5 docs — `subscribeWithSelector` middleware; useSyncExternalStore-compatible]; Zustand 5 is the current major |
| `vite` | `^8.0.0` | Build tool | [VERIFIED: Vite 8 release blog, March 2026]; ships Rolldown bundler + Lightning CSS; 10-30× faster builds vs V7; ~15 MB install size increase (10 MB LightningCSS + 5 MB Rolldown) |
| `@vitejs/plugin-react` | `^5.0.0` | React HMR in Vite | Standard Vite ↔ React integration |

### Supporting (build + test)

| Library | Version | Purpose | When to Use |
|---------|---------|---------|-------------|
| `typescript` | `^5.9.0` | Static types, shared Swift-side protocol mirror | Always on — TS mirror of `BUS_PROTOCOL_VERSION` + bus schema lives here |
| `vitest` | `^3.0.0` | Unit test runner | Component tests for chat-panel pieces, Zustand store reducers |
| `@testing-library/react` | `^17.0.0` | DOM-level component tests | Pair with vitest; assert rendered output not internals |
| `@testing-library/jest-dom` | `^7.0.0` | Matcher extensions | `toBeInTheDocument()` etc. |
| `@playwright/test` | `^2.0.0` | Visual regression + E2E | Deferred gating until P8; scaffold only a "canvas is present" smoke test in P3 |
| `glslify` or raw GLSL imports | (Vite handles `.glsl` as string via `?raw`) | Shader source | Vite 8 supports `.glsl?raw` imports natively |

### Alternatives Considered

| Instead of | Could Use | Tradeoff |
|------------|-----------|----------|
| R3F 9 | Raw three.js via `useEffect` + imperative mount | R3F's reconciler owns unmount; raw three.js leaks GPU resources on WKWebView panel dismiss unless you hand-write `dispose()` trees. R3F buys us auto-cleanup + the drei helpers. |
| Zustand 5 | Redux Toolkit / Jotai / React Context | Zustand's `subscribeWithSelector` + external-store compatibility is tight-loop friendly; context causes full-tree rerenders; Redux is overkill for a 5-writer store. |
| Vite 8 with Rolldown | esbuild / webpack / Parcel | Vite is R3F ecosystem standard; Rolldown bundler is 10-30× faster than Vite 7 Rollup; HMR is required for dev ergonomics. |
| `THREE.Points` + custom shader | `InstancedMesh` of sphere particles | Instancing is for "many geometries, many draws"; our ring is one object. Points is the lower-overhead primitive for >500 particles. Per [three.js forum discussion](https://discourse.threejs.org/t/instancedmesh-vs-instancedbuffergeometry/31058), `InstancedBufferGeometry` matters only when per-instance attributes vary meaningfully. |
| drei `shaderMaterial` | Hand-roll `THREE.ShaderMaterial` subclass | drei's `shaderMaterial(uniforms, vert, frag)` auto-generates uniform setters/getters + constructor args. Saves ~30 LOC per shader. |
| AI SDK 5 `useChat` | Custom bus-driven chat state | We have our own bus + orchestrator; AI SDK is server-streaming-shaped and doesn't fit the Swift-orchestrator-is-authoritative model. **Borrow the `UIMessage.parts` *shape*, reject the hook.** |
| Tailwind | CSS Modules / vanilla CSS vars | HUD has <10 visible components; Tailwind's utility classes are optimized for large component libraries; vanilla CSS + custom properties wins on bundle size (~30 KB savings) and maintains fewer moving parts. |
| CSS-in-JS (Emotion/Stitches) | Vanilla CSS | Same reasoning; CSS-in-JS pays runtime cost for theming we can do statically via CSS vars. |

**Installation (baseline `package.json` in `webview/`):**
```json
{
  "name": "jarvis-hud",
  "version": "0.1.0",
  "private": true,
  "scripts": {
    "dev": "vite",
    "build": "vite build",
    "typecheck": "tsc --noEmit",
    "test": "vitest run",
    "test:watch": "vitest"
  },
  "dependencies": {
    "react": "^19.2.0",
    "react-dom": "^19.2.0",
    "@react-three/fiber": "^9.6.0",
    "@react-three/drei": "^10.7.6",
    "three": "^0.184.0",
    "zustand": "^5.0.0"
  },
  "devDependencies": {
    "@types/react": "^19.0.0",
    "@types/react-dom": "^19.0.0",
    "@types/three": "^0.184.0",
    "@vitejs/plugin-react": "^5.0.0",
    "typescript": "^5.9.0",
    "vite": "^8.0.0",
    "vitest": "^3.0.0",
    "@testing-library/react": "^17.0.0",
    "@testing-library/jest-dom": "^7.0.0"
  }
}
```

**Version verification command (planner: run at scaffold, capture resolved versions in task action blocks):**
```bash
cd webview && pnpm view react version && pnpm view @react-three/fiber version && pnpm view @react-three/drei version && pnpm view three version && pnpm view zustand version && pnpm view vite version
```

## Architecture Patterns

### System Architecture Diagram

```
┌────────────────────────────────────────────────────────────────────────┐
│  macOS host process: Jarvis.app (LSUIElement, Hardened Runtime +jit)   │
│                                                                        │
│  Swift side (P1 + P2 + P3)                                             │
│                                                                        │
│   AgentOrchestrator (P4)─┐                                             │
│   VoiceController (P6)───┼──► AsyncStream<HudStateIntent>              │
│   ConfirmationBroker (P5)┘             │                               │
│                                        ▼                               │
│                         ┌──────────────────────────────────┐           │
│                         │ HudStateCoordinator              │           │
│                         │ @MainActor final class           │           │
│                         │ • 3× `for await` subscriber loops│           │
│                         │ • Precedence resolver            │           │
│                         │ • Single `bridge.send(.hudState)`│           │
│                         └──────────────┬───────────────────┘           │
│                                        │                               │
│                         WebviewBridge (P2)                             │
│                         callAsyncJavaScript(args:)                     │
│                         OutboundBatcher @ 30Hz (token/audio)           │
│                         State transitions flush immediately            │
│                                        │                               │
│                                        ▼                               │
│              ┌─────────────────────────────────────────┐               │
│              │ JarvisHUDPanel.webView (WKWebView)      │               │
│              │ loadFileRequest(indexURL, readAccess:   │               │
│              │                webviewDir)              │               │
│              └──────────────────┬──────────────────────┘               │
│                                 │                                      │
│      ────────────────────────── BUS ───────────────────────────        │
│                                 │                                      │
│   React 19 app (webview/dist/)                                         │
│                                 ▼                                      │
│      ┌──────────────────────────────────────────────────────┐          │
│      │ Bus client (TS):                                     │          │
│      │  • window.webkit.messageHandlers.jarvis.postMessage  │          │
│      │  • Listens for outbound messages via window.onJarvis │          │
│      │    (injected by callAsyncJavaScript)                 │          │
│      │  • Dispatches to Zustand store                       │          │
│      └───────────────────────┬──────────────────────────────┘          │
│                              │                                         │
│      ┌───────────────────────▼──────────────────────────────┐          │
│      │ Zustand 5 store (useJarvisStore)                     │          │
│      │  • hudState: HudState                                │          │
│      │  • chatEvents: ChatEvent[]  (ordered, discriminated) │          │
│      │  • theme: ThemeTokens                                │          │
│      │  • a11y: {reduceMotion, reduceTransparency}          │          │
│      │  • connection: 'booting' | 'ready' | 'refused'       │          │
│      └───────┬─────────────────────────────────┬────────────┘          │
│              │                                 │                       │
│              ▼                                 ▼                       │
│      ┌───────────────────┐       ┌──────────────────────────┐          │
│      │ <ParticleRing />  │       │ <ChatPanel />            │          │
│      │ R3F <Canvas>      │       │ React flat list of       │          │
│      │ useFrame reads    │       │ <ChatEvent> components   │          │
│      │ hudState uniform  │       │ • TextPart (streaming)   │          │
│      │ (no React rerender│       │ • ToolCallCard           │          │
│      │  per frame)       │       │ • ErrorPart              │          │
│      └───────────────────┘       └──────────────────────────┘          │
│                                                                        │
└────────────────────────────────────────────────────────────────────────┘
```

### Recommended Project Structure

```
webview/                              ** NEW in P3 (repo root, peer of App/) **
├── package.json
├── pnpm-lock.yaml                    # commit this
├── tsconfig.json
├── vite.config.ts                    # base: './' for file:// compat
├── index.html                        # <div id="root"></div>, CSP meta, viewport
├── vitest.config.ts
├── public/
│   └── (static assets, icons — empty in P3)
├── src/
│   ├── main.tsx                      # ReactDOM.createRoot, mounts <App />
│   ├── App.tsx                       # <ParticleRing /> + <ChatPanel /> in a flex layout
│   ├── bus/
│   │   ├── BUS_PROTOCOL_VERSION.ts   # mirrored constant — must match Swift; check-bus-protocol-version.sh enforces
│   │   ├── schemas.ts                # Zod-free: hand-written discriminated unions matching Swift Codable
│   │   ├── client.ts                 # inbound dispatch, outbound postMessage wrapper
│   │   └── __fixtures__/             # JSON fixtures for round-trip tests (SEC-09 from P2)
│   ├── store/
│   │   ├── index.ts                  # createStore, subscribeWithSelector
│   │   ├── types.ts                  # HudState, ChatEvent, Theme, A11y
│   │   └── selectors.ts              # memoized selectors for components
│   ├── hud/
│   │   ├── ParticleRing.tsx          # <Canvas> wrapper
│   │   ├── RingMesh.tsx              # <points> + useFrame + useRef<Material>
│   │   ├── ring.vert.glsl            # vertex shader (string-imported via ?raw)
│   │   ├── ring.frag.glsl            # fragment shader
│   │   └── stateUniforms.ts          # per-state uniform target values
│   ├── chat/
│   │   ├── ChatPanel.tsx             # wraps list + input
│   │   ├── ChatEvent.tsx             # discriminator router
│   │   ├── TextPart.tsx              # streaming text with RAF flush
│   │   ├── ToolCallCard.tsx          # expandable lifecycle card
│   │   └── __tests__/                # vitest + RTL
│   ├── theme/
│   │   ├── tokens.css                # CSS custom properties (derived from Swift BrandColors at startup via bus)
│   │   └── theme.ts                  # Zustand-backed theme provider hook
│   └── types/
│       └── globals.d.ts              # declare window.webkit, vite glsl module
└── dist/                             # vite build output — copied into Jarvis.app/Contents/Resources/webview/
```

**Integration with Xcode project.yml:**
```yaml
postBuildScripts:
  - name: Build webview bundle
    script: |
      set -e
      cd "$SRCROOT/webview"
      if [ ! -d "node_modules" ] || [ "package.json" -nt "node_modules/.pnpm-integrity" ]; then
        pnpm install --frozen-lockfile
      fi
      pnpm build
      rsync -a --delete dist/ "$TARGET_BUILD_DIR/$WRAPPER_NAME/Contents/Resources/webview/"
    runOnlyWhenInstalling: false
    basedOnDependencyAnalysis: false
```

(Precede `verify-entitlements.sh` and `codesign.sh` — webview assets must be present before codesign so they're covered by the signature.)

**Content hash sentinel vs `-nt`:** the above uses `-nt` for simplicity. ARCHITECTURE.md R3-B9 notes that `-nt` is susceptible to timestamp issues across checkouts; the eventual `scripts/build-webview.sh` should use a `pnpm-lock.sha256` content-hash sentinel. For P3 MVP, `-nt` is acceptable with a TODO marker.

### Pattern 1: Single-Writer HudStateCoordinator (Swift)

**What:** One `@MainActor final class` is the sole callsite of `bridge.send(.hudState)`. Three subsystems (agent / voice / confirmation) publish `HudStateIntent` events; the coordinator resolves against a precedence ladder.

**When to use:** Always for multi-source state → single UI surface. Any deviation causes the R1 H-A3 "two writers race."

**Example:**
```swift
// Source: ARCHITECTURE.md system overview + SE-0406 back-pressure patterns

public enum HudStateIntent: Sendable, Equatable {
    case agent(AgentHudIntent)           // .idle / .thinking / .speaking
    case voice(VoiceHudIntent)           // .listening / .reconfiguring
    case confirmation(ConfirmHudIntent)  // .awaitingConfirmation / .cleared
    case system(SystemHudIntent)         // .booting / .ready
}

@MainActor
public final class HudStateCoordinator {
    private let bridge: WebviewBridge
    private var current: HudState = .booting
    private var lastAgent: AgentHudIntent = .idle
    private var lastVoice: VoiceHudIntent = .silent
    private var awaitingConfirm: Bool = false
    private var booting: Bool = true

    public init(bridge: WebviewBridge) {
        self.bridge = bridge
    }

    /// Start three concurrent subscribers. Called at startup after all three
    /// AsyncStreams exist (AppDelegate barrier chain).
    public func start(
        agent: AsyncStream<AgentHudIntent>,
        voice: AsyncStream<VoiceHudIntent>,
        confirmation: AsyncStream<ConfirmHudIntent>
    ) {
        Task { [weak self] in
            for await intent in agent {
                guard let self else { return }
                self.lastAgent = intent
                self.resolveAndEmit()
            }
        }
        Task { [weak self] in
            for await intent in voice {
                guard let self else { return }
                self.lastVoice = intent
                self.resolveAndEmit()
            }
        }
        Task { [weak self] in
            for await intent in confirmation {
                guard let self else { return }
                switch intent {
                case .required: self.awaitingConfirm = true
                case .cleared:  self.awaitingConfirm = false
                }
                self.resolveAndEmit()
            }
        }
    }

    public func markReady() {
        self.booting = false
        self.resolveAndEmit()
    }

    /// Resolve against precedence ladder per HUD-08:
    ///   awaitingConfirmation > speaking > listening > thinking > idle > booting > reconfiguring
    private func resolveAndEmit() {
        let resolved: HudState
        if awaitingConfirm {
            resolved = .awaitingConfirmation
        } else if case .speaking = lastAgent {
            resolved = .speaking
        } else if case .listening = lastVoice {
            resolved = .listening
        } else if case .thinking = lastAgent {
            resolved = .thinking
        } else if case .reconfiguring = lastVoice {
            // reconfiguring only if no higher-priority condition — UI-SPEC §Surface 3 ambiguity
            resolved = .reconfiguring
        } else if booting {
            resolved = .booting
        } else {
            resolved = .idle
        }

        guard resolved != current else { return }
        current = resolved
        bridge.send(.hudState(resolved))  // SINGLE call-site — lint-enforced
    }

    // Test introspection
    public var currentStateForTests: HudState { current }
}
```

**Why three `for await` Tasks and not one merged stream:** Swift 6 doesn't ship a `merge` combinator in stdlib; `swift-async-algorithms` provides one but pulling it in for three sources is heavier than three loops. Three `Task { for await ... }` is simpler, has the same semantics under MainActor serialization, and makes the precedence re-computation obvious. Per [Swift Forums: Consuming AsyncStream from multiple tasks](https://forums.swift.org/t/consuming-an-asyncstream-from-multiple-tasks/54453), consuming one stream from multiple tasks is broken (tasks race for elements); our pattern is the inverse — one task per stream — which is correct.

**Alternative if back-pressure matters:** use `swift-async-algorithms` `.merge(_:_:_:)` to fold all three into one stream, then one `for await`. Defer unless we see a reason.

### Pattern 2: Zustand 5 Store with subscribeWithSelector

**What:** One store, multiple slices. Actions are strict — only the bus dispatcher mutates store state. Components read with selector functions; `subscribeWithSelector` middleware enables imperative subscriptions (for R3F `useFrame` which can't participate in React render).

**When to use:** When a subscriber needs store updates WITHOUT forcing a React render (the ring mesh reads `hudState` in `useFrame` and writes shader uniforms directly).

**Example:**
```ts
// Source: Zustand 5 docs (subscribeWithSelector middleware)
// https://zustand.docs.pmnd.rs/reference/middlewares/subscribe-with-selector

import { create } from 'zustand'
import { subscribeWithSelector } from 'zustand/middleware'

export type HudState =
  | 'booting' | 'reconfiguring' | 'idle'
  | 'thinking' | 'listening' | 'speaking'
  | 'awaitingConfirmation'

export type ChatEvent =
  | { id: string; kind: 'text'; text: string; role: 'user' | 'assistant'; turnId: string }
  | { id: string; kind: 'tool-call'; name: string; args: unknown; status: ToolCallStatus;
      result?: unknown; error?: string; turnId: string }
  | { id: string; kind: 'error'; message: string; turnId: string }

export type ToolCallStatus = 'pending' | 'running' | 'awaiting-approval' | 'completed' | 'failed'

interface JarvisStore {
  hudState: HudState
  chatEvents: ChatEvent[]
  a11y: { reduceMotion: boolean; reduceTransparency: boolean }
  theme: { arcReactorGlow: string }
  connection: 'booting' | 'ready' | 'refused'

  // Actions — only called by bus dispatcher, never by components directly
  setHudState: (s: HudState) => void
  appendTokenToLastText: (id: string, delta: string) => void
  upsertToolCall: (ev: Extract<ChatEvent, { kind: 'tool-call' }>) => void
  pushEvent: (ev: ChatEvent) => void
  setA11y: (a11y: JarvisStore['a11y']) => void
  setTheme: (theme: JarvisStore['theme']) => void
  setConnection: (c: JarvisStore['connection']) => void
}

export const useJarvisStore = create<JarvisStore>()(
  subscribeWithSelector((set) => ({
    hudState: 'booting',
    chatEvents: [],
    a11y: { reduceMotion: false, reduceTransparency: false },
    theme: { arcReactorGlow: '#1E88E5' },
    connection: 'booting',

    setHudState: (s) => set({ hudState: s }),
    appendTokenToLastText: (id, delta) => set((state) => {
      const idx = state.chatEvents.findIndex((e) => e.id === id)
      if (idx === -1) return state
      const ev = state.chatEvents[idx]
      if (ev.kind !== 'text') return state
      // Zustand 5 requires immutable updates for subscribers to fire
      const next = state.chatEvents.slice()
      next[idx] = { ...ev, text: ev.text + delta }
      return { chatEvents: next }
    }),
    upsertToolCall: (ev) => set((state) => {
      const idx = state.chatEvents.findIndex((e) => e.id === ev.id)
      const next = state.chatEvents.slice()
      if (idx === -1) next.push(ev)
      else next[idx] = ev
      return { chatEvents: next }
    }),
    pushEvent: (ev) => set((state) => ({ chatEvents: [...state.chatEvents, ev] })),
    setA11y: (a11y) => set({ a11y }),
    setTheme: (theme) => set({ theme }),
    setConnection: (c) => set({ connection: c }),
  }))
)

// Imperative subscription pattern used by RingMesh inside useFrame hook
export function subscribeHudState(cb: (s: HudState) => void): () => void {
  return useJarvisStore.subscribe(
    (state) => state.hudState,
    cb,
    { equalityFn: Object.is, fireImmediately: true }
  )
}
```

**Why `subscribeWithSelector` and not the default subscribe:** default `subscribe(listener)` fires on *any* store change. `subscribeWithSelector` lets the ring subscribe specifically to `hudState` without being woken up by `appendTokenToLastText` firing every 16ms. [Zustand discussion #2103](https://github.com/pmndrs/zustand/discussions/2103) documents a known footgun where the middleware fires if the *selector's return* compares unequal; our keys are primitives (string state name), so `Object.is` works.

### Pattern 3: R3F Particle Ring — Uniforms Over React State

**What:** One `<points>` with a `BufferGeometry` of N particles arranged on a ring. A drei `shaderMaterial` owns the fragment + vertex shaders with uniforms for `uTime`, `uState` (encoded as numeric index 0..6), `uStateBlend` (0..1 for crossfade between two states), and per-state param uniforms. In `useFrame`, we read `hudState` from the Zustand store (via `getState()`, NOT a hook — hooks would cause React rerender per frame, which kills perf), compute target uniform values, interpolate toward them, and apply.

**When to use:** Whenever the animation would re-render React per frame. ALL animated shader uniforms belong here.

**Anti-pattern to avoid:** `const hudState = useJarvisStore((s) => s.hudState)` inside the ring mesh component. That would rerender the component every time hudState changes, but worse — if the selector returns a new reference object you'd pay every store tick. Use `getState()` in `useFrame` and a separate `subscribeWithSelector` for state transitions that need React commits (e.g., swapping color palettes).

**Example:**
```tsx
// Source: drei docs (shaderMaterial), Maxime Heckel particles article,
// three.js BufferGeometry docs
// https://drei.docs.pmnd.rs/shaders/shader-material
// https://blog.maximeheckel.com/posts/the-magical-world-of-particles-with-react-three-fiber-and-shaders/

import { shaderMaterial } from '@react-three/drei'
import { extend, useFrame } from '@react-three/fiber'
import { useMemo, useRef } from 'react'
import * as THREE from 'three'
import vertexShader from './ring.vert.glsl?raw'
import fragmentShader from './ring.frag.glsl?raw'
import { useJarvisStore, HudState } from '../store'

const RingMaterial = shaderMaterial(
  // uniforms (initial values)
  {
    uTime: 0,
    uStateIdx: 0,        // 0..6 integer index of current HudState
    uStateBlend: 1,      // 1 = fully at uStateIdx; <1 during crossfade from uPrevStateIdx
    uPrevStateIdx: 0,
    uPulseSpeed: 1.0,    // state-driven: 0 for idle, 3 for listening, etc.
    uRotateSpeed: 0.0,   // state-driven
    uColorGlow: new THREE.Color('#1E88E5'),
    uReduceMotion: 0,    // 1 = disable motion
  },
  vertexShader,
  fragmentShader,
)

extend({ RingMaterial })

// Maps HudState to shader params. Computed once per state — cheap lookup.
const STATE_PARAMS: Record<HudState, { pulse: number; rotate: number }> = {
  booting:              { pulse: 0.3, rotate: 0.1 },
  reconfiguring:        { pulse: 0.8, rotate: 0.3 },
  idle:                 { pulse: 0.0, rotate: 0.0 },
  thinking:             { pulse: 1.5, rotate: 1.0 },
  listening:            { pulse: 3.0, rotate: 0.0 },
  speaking:             { pulse: 2.0, rotate: 0.2 },
  awaitingConfirmation: { pulse: 2.5, rotate: 0.0 },
}

const STATE_TO_IDX: Record<HudState, number> = {
  booting: 0, reconfiguring: 1, idle: 2, thinking: 3,
  listening: 4, speaking: 5, awaitingConfirmation: 6,
}

export function RingMesh({ particles = 512 }: { particles?: number }) {
  const matRef = useRef<any>(null)

  // Precompute particle positions on a ring once.
  const geometry = useMemo(() => {
    const geo = new THREE.BufferGeometry()
    const positions = new Float32Array(particles * 3)
    const radii = new Float32Array(particles)
    const thetas = new Float32Array(particles)
    for (let i = 0; i < particles; i++) {
      const t = (i / particles) * Math.PI * 2
      const r = 1.0 + (Math.random() - 0.5) * 0.05 // slight jitter
      positions[i * 3 + 0] = Math.cos(t) * r
      positions[i * 3 + 1] = Math.sin(t) * r
      positions[i * 3 + 2] = 0
      radii[i] = r
      thetas[i] = t
    }
    geo.setAttribute('position', new THREE.BufferAttribute(positions, 3))
    geo.setAttribute('aRadius', new THREE.BufferAttribute(radii, 1))
    geo.setAttribute('aTheta', new THREE.BufferAttribute(thetas, 1))
    return geo
  }, [particles])

  // Cached target state. Read via getState(), not hook.
  const targetRef = useRef({ stateIdx: 0, pulse: 0, rotate: 0 })
  const currentRef = useRef({ stateIdx: 0, pulse: 0, rotate: 0, blend: 1 })

  useFrame((_, delta) => {
    if (!matRef.current) return

    // Read truth from store WITHOUT subscribing (no rerender)
    const s = useJarvisStore.getState().hudState
    const p = STATE_PARAMS[s]
    const targetIdx = STATE_TO_IDX[s]
    const reduceMotion = useJarvisStore.getState().a11y.reduceMotion

    if (targetRef.current.stateIdx !== targetIdx) {
      // Start crossfade: remember previous as uPrevStateIdx, blend from 0 → 1
      currentRef.current.blend = 0
      matRef.current.uPrevStateIdx = currentRef.current.stateIdx
      currentRef.current.stateIdx = targetIdx
    }
    targetRef.current = { stateIdx: targetIdx, pulse: p.pulse, rotate: p.rotate }

    // Ease blend toward 1 (150ms crossfade consistent with UI-SPEC Surface 3)
    currentRef.current.blend = Math.min(1, currentRef.current.blend + delta / 0.15)

    // Ease pulse/rotate params (smooth morphing)
    currentRef.current.pulse += (p.pulse - currentRef.current.pulse) * Math.min(1, delta * 6)
    currentRef.current.rotate += (p.rotate - currentRef.current.rotate) * Math.min(1, delta * 6)

    matRef.current.uTime += delta
    matRef.current.uStateIdx = currentRef.current.stateIdx
    matRef.current.uStateBlend = currentRef.current.blend
    matRef.current.uPulseSpeed = reduceMotion ? 0 : currentRef.current.pulse
    matRef.current.uRotateSpeed = reduceMotion ? 0 : currentRef.current.rotate
    matRef.current.uReduceMotion = reduceMotion ? 1 : 0
  })

  return (
    <points geometry={geometry}>
      {/* @ts-expect-error drei's shaderMaterial needs a custom element namespace */}
      <ringMaterial ref={matRef} transparent depthWrite={false} />
    </points>
  )
}
```

**Ring vertex shader sketch:**
```glsl
// ring.vert.glsl
uniform float uTime;
uniform float uPulseSpeed;
uniform float uRotateSpeed;
uniform float uStateIdx;
uniform float uStateBlend;  // 0..1, 1 = fully at uStateIdx
uniform float uPrevStateIdx;
uniform float uReduceMotion;

attribute float aRadius;
attribute float aTheta;

varying float vAlpha;

void main() {
  float theta = aTheta + uTime * uRotateSpeed;
  float pulse = sin(uTime * uPulseSpeed * 6.2831) * 0.05 * (1.0 - uReduceMotion);
  float r = aRadius + pulse;

  vec3 pos = vec3(cos(theta) * r, sin(theta) * r, 0.0);
  vec4 mvPosition = modelViewMatrix * vec4(pos, 1.0);
  gl_Position = projectionMatrix * mvPosition;

  gl_PointSize = 4.0 * (300.0 / -mvPosition.z);
  vAlpha = 0.85;
}
```

**Ring fragment shader sketch:**
```glsl
// ring.frag.glsl
uniform vec3 uColorGlow;
varying float vAlpha;

void main() {
  // Circular point sprite with soft edge
  vec2 uv = gl_PointCoord - vec2(0.5);
  float d = length(uv);
  float alpha = smoothstep(0.5, 0.2, d) * vAlpha;
  gl_FragColor = vec4(uColorGlow, alpha);
}
```

### Pattern 4: Tool-Call Lifecycle Cards

**What:** Each tool-call is one `ChatEvent` of kind `tool-call` in the ordered `chatEvents` array. The same event ID is updated in place as status transitions (`pending → running → awaiting-approval → completed | failed`). React renders a `<ToolCallCard>` that owns local expand/collapse UI state.

**When to use:** For any non-trivial side-effect the agent performs (MCP tool calls, memory extraction triggers in P7). Simple internal events (text-delta) are NOT cards.

**State machine:**
```
  pending ───► running ─┬─► completed
                         └─► failed
  pending ───► awaiting-approval ─┬─► running ─┬─► completed
                                   │           └─► failed
                                   └─► failed (denied / timeout)
```

**Bus events (additions to P2 schema, implemented in P3):**
```ts
// bus/schemas.ts (TS mirror of Swift Codable)

export type OutboundMessage =
  | { type: 'hudState'; state: HudState }
  | { type: 'chat/toolCallStart'; id: string; name: string; args: unknown | { awaitingApproval: true }; turnId: string }
  | { type: 'chat/toolCallRunning'; id: string }
  | { type: 'chat/toolCallAwaitingApproval'; id: string }
  | { type: 'chat/toolCallCompleted'; id: string; resultPreview: string }
  | { type: 'chat/toolCallFailed'; id: string; error: string }
  | { type: 'chat/textStart'; id: string; role: 'user' | 'assistant'; turnId: string }
  | { type: 'chat/tokenDelta'; id: string; delta: string }
  | { type: 'chat/textEnd'; id: string }
  | { type: 'chat/errorPart'; id: string; message: string; turnId: string }
  | { type: 'a11y'; reduceMotion: boolean; reduceTransparency: boolean }
  | { type: 'theme'; arcReactorGlow: string }
  | { type: 'handshake/helloFromSwift'; busProtocolVersion: string }
```

**Component sketch:**
```tsx
// chat/ToolCallCard.tsx
import { useState } from 'react'
import type { ChatEvent } from '../store/types'

type ToolCallEvent = Extract<ChatEvent, { kind: 'tool-call' }>

export function ToolCallCard({ event }: { event: ToolCallEvent }) {
  const [expanded, setExpanded] = useState(false)

  const statusLabel = {
    pending: 'Preparing…',
    running: 'Running',
    'awaiting-approval': 'Waiting for your approval',
    completed: 'Done',
    failed: 'Failed',
  }[event.status]

  const isApprovalArgs = typeof event.args === 'object'
    && event.args !== null
    && 'awaitingApproval' in (event.args as any)

  return (
    <div className={`tool-call-card tool-call-card--${event.status}`}
         role="group"
         aria-label={`Tool call ${event.name}, ${statusLabel}`}>
      <button
        type="button"
        className="tool-call-card__header"
        onClick={() => setExpanded(!expanded)}
        aria-expanded={expanded}>
        <span className="tool-call-card__status-dot" aria-hidden />
        <span className="tool-call-card__name">{event.name}</span>
        <span className="tool-call-card__status">{statusLabel}</span>
        <span className="tool-call-card__chevron" aria-hidden>{expanded ? '▾' : '▸'}</span>
      </button>
      {expanded && (
        <div className="tool-call-card__body">
          <div className="tool-call-card__section">
            <h4>Arguments</h4>
            <pre>{isApprovalArgs
              ? '(hidden until you approve)'
              : JSON.stringify(event.args, null, 2)}</pre>
          </div>
          {event.result !== undefined && (
            <div className="tool-call-card__section">
              <h4>Result</h4>
              <pre>{JSON.stringify(event.result, null, 2)}</pre>
            </div>
          )}
          {event.error && (
            <div className="tool-call-card__section tool-call-card__section--error">
              <h4>Error</h4>
              <pre>{event.error}</pre>
            </div>
          )}
        </div>
      )}
    </div>
  )
}
```

**SEC-pre-approval note:** `ToolCallStart.args` ships from Swift as `{awaitingApproval: true}` (not the real args) for `requiresConfirmation` tools, per R4-Sec5 / Phase 5 MCP-04. The card renders "(hidden until you approve)" as an explicit visible affordance. Raw args populate only after approval via a `chat/toolCallArgsRevealed` follow-up event (P5 concern; scaffold the union case now).

### Pattern 5: Streaming Tokens + Chronological Inlining

**What:** Every token-delta, tool-call start/end, and text-part start/end is appended (or upserted) to the `chatEvents` array in arrival order. React renders the array as a flat list. Because array ordering = event chronology, tool-call cards naturally interleave with text parts without any separate "rail."

**Tokens-per-frame batching:** P2's OutboundBatcher already batches `tokenDelta` @ ~30Hz Swift-side. React-side, `appendTokenToLastText` fires once per OutboundBatcher flush (not once per LLM token). We rely on that cadence; additional RAF batching on the React side is NOT needed unless we see jank in P4 text-loop profiling. If we do, the fallback is:

```ts
// Fallback pattern if Swift-side batching isn't enough
// Source: https://www.sitepoint.com/streaming-backends-react-controlling-re-render-chaos/

const tokenBufferRef = useRef('')
const rafRef = useRef<number | null>(null)

function bufferToken(id: string, delta: string) {
  tokenBufferRef.current += delta
  if (rafRef.current !== null) return
  rafRef.current = requestAnimationFrame(() => {
    rafRef.current = null
    useJarvisStore.getState().appendTokenToLastText(id, tokenBufferRef.current)
    tokenBufferRef.current = ''
  })
}
```

**Render discipline:** `TextPart.tsx` is a pure function of `event.text`. React 19 auto-batching + Zustand's selector = text component rerenders only when its own `text` changes. This is cheap; the expensive case is renderers that map `chatEvents` and rerender the whole list every token. Use a stable `key={event.id}` and children selectors to scope rerenders.

```tsx
// chat/ChatPanel.tsx
import { useJarvisStore } from '../store'
import { ChatEventRouter } from './ChatEvent'

export function ChatPanel() {
  const chatEvents = useJarvisStore((s) => s.chatEvents)
  return (
    <div className="chat-panel" role="log" aria-live="polite">
      {chatEvents.map((ev) => (
        <ChatEventRouter key={ev.id} event={ev} />
      ))}
    </div>
  )
}

// chat/ChatEvent.tsx — discriminator
export function ChatEventRouter({ event }: { event: ChatEvent }) {
  switch (event.kind) {
    case 'text':       return <TextPart event={event} />
    case 'tool-call':  return <ToolCallCard event={event} />
    case 'error':      return <ErrorPart event={event} />
  }
}
```

### Pattern 6: Bus Schema Parity (Swift ↔ TS)

**What:** A build-time script (`scripts/check-bus-protocol-version.sh`) asserts Swift's `BUS_PROTOCOL_VERSION` constant and TS's `BUS_PROTOCOL_VERSION.ts` export match. The SEC-09 acceptance criteria from P2 cover this mechanism; P3 *uses* it by extending the shared enum set with new cases.

**Schema extensions P3 must define (Swift and TS together, in lock-step):**
- `HudState` grows from 5 to 7 cases — add `booting`, `reconfiguring`.
- `OutboundMessage.type` adds `chat/*` messages listed above.
- `InboundMessage.type` adds `ready` (webview signals "HUD pumping" for the P1 startup barrier chain), `userTextInput` (TEXT-01, consumed here but sourced in P4), `hudEvent/toolCardExpanded` (optional, for telemetry).

**Anti-Patterns to Avoid**

- **Writing HUD state from a component.** `setHudState` is ONLY for the bus dispatcher. React components never call it. Lint rule: reject `setHudState` calls outside `src/bus/client.ts`.
- **Hooking `useJarvisStore` inside `useFrame`.** Rerenders per frame; kills 60 FPS instantly. Use `useJarvisStore.getState()` instead, or `subscribeWithSelector` with an imperative callback.
- **Rebuilding the BufferGeometry per render.** `useMemo` with a stable dep list. Changing particle count at runtime requires explicit `geometry.dispose()`.
- **Setting shader uniforms via React props.** Triggers three.js to diff + re-upload uniforms per frame. Use `useRef<ShaderMaterial>` + direct property writes in `useFrame`.
- **Rendering the full `chatEvents` array in a component that also selects `hudState`.** Any hudState change rerenders the whole chat. Scope selectors.
- **Using `evaluateJavaScript` with string-interpolated JSON.** P2 lint-enforced; still call it out — U+2028 / `</script>` injection.
- **Adding React-layer animations that ignore Reduce Motion.** Every animation must either check `a11y.reduceMotion` from store OR use CSS `@media (prefers-reduced-motion: reduce)`. WKWebView respects the OS setting at the CSS layer automatically.
- **Inlining CSS transforms on the same element that R3F renders into.** R3F owns the canvas; CSS transforms on the wrapper are fine. CSS transforms on the canvas itself conflict with devicePixelRatio.
- **Loading WKWebView via `loadHTMLString`.** No local resource resolution; assets 404. Use `loadFileRequest(_:allowingReadAccessTo:)`.

## Don't Hand-Roll

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| Particle-ring shader pipeline | Custom `THREE.ShaderMaterial` subclass | drei `shaderMaterial(uniforms, vert, frag)` | Auto-generates uniform getters/setters + constructor args. Saves ~30 LOC and matches R3F conventions. |
| External state for R3F components | Global var, module-scoped mutable, React context | Zustand with `subscribeWithSelector` | Built for exactly this; handles tearing via useSyncExternalStore under the hood in React 19. |
| Bundle webview for WKWebView | Hand-rolled esbuild script or raw Rollup | Vite 8 | File URLs + relative assets + HMR in dev + single built directory — Vite `base: './'` handles it. |
| TS/Swift schema drift prevention | Parallel hand-written enums with no check | SEC-09 pre-build script (P2) + shared enum test corpus | P2 ships this; P3 extends the enum list. |
| Stream token batching | Custom setState-per-token + debounce | Swift-side OutboundBatcher (P2) + RAF buffer fallback | The ChatGPT-smooth pattern. Per-token setState = 20 FPS stream. |
| Reduce Motion detection in JS | `window.matchMedia('(prefers-reduced-motion: reduce)')` polling | Emit from Swift via bus | Swift already observes `NSWorkspace.accessibilityDisplayShouldReduceMotion` (P1 MenuBarIconController does this). Single source of truth. |
| Transparent webview backing | Hand-set CSS `background: transparent` + hope | P1's `drawsBackground=false` + `underPageBackgroundColor=.clear` on the panel + CSS `body { background: transparent; }` | P1 landed the native side. React side must not emit opaque backgrounds. |
| Tool-call lifecycle rendering | Parallel UI list indexed by tool-call ID | Ordered `chatEvents` with upsert-by-id | Chronology = array order; tool cards interleave naturally with text parts. |

**Key insight:** this phase is *mostly* gluing a standard R3F scaffold onto a Swift-authoritative event stream. The novelty is the precedence ladder (HUD-08) and the interleaved chat-panel event log. Both are architectural; the renderer is stock.

## Particle Ring Visual Design (HUD-02)

Seven states, seven visual signatures. All seven derive from the same shader — only uniforms change. Inherits brand voice from UI-SPEC Surface 3 (menu-bar icon state animations) for consistency, but scales up to HUD-panel proportions.

| State | Color | Pulse | Rotate | Particle density modulation | Reduce-Motion fallback |
|-------|-------|-------|--------|------------------------------|------------------------|
| `booting` | grey `#6b7280` at 60% | subtle 0.3 Hz breath | 0.1 rad/s slow drift | normal | static ring, single 2pt "loading" dot orbits slowly or is simply static |
| `reconfiguring` | warm amber `#F59E0B` | 0.8 Hz breath | 0.3 rad/s drift | gaps in ring (20% missing, rotating) | static ring with 3-dot loading indicator below |
| `idle` | arc-reactor-glow color (theme token) at 85% | zero | zero | normal | identical (no motion to strip) |
| `thinking` | arc-reactor-glow | 1.5 Hz subtle breath | 1.0 rad/s | normal | 3 dots below ring rotate opacity (0→1 sequential) at 500ms |
| `listening` | arc-reactor-glow brightened to 100% | 3 Hz reactive (would bind to mic RMS in P6; P3 uses fake sine) | zero | ring thickness expands/contracts | single pulse dot, opacity blink 1.25s |
| `speaking` | arc-reactor-glow + outward wave from center | 2 Hz shimmer, phased | 0.2 rad/s | outward wave of bright particles at 900ms period | static ring with 0.8x opacity pulse, 0.8s period |
| `awaitingConfirmation` | amber `#F59E0B` | 2.5 Hz (higher amplitude) | zero | brighter all particles | static, with persistent dot at top-right corner |

**All Reduce-Motion fallbacks emit from the same shader by setting `uReduceMotion = 1` and letting the shader zero out time-based terms. Non-shader affordances (loading dots below the ring) render as separate simple DOM elements gated on `a11y.reduceMotion`.**

**Brand color inheritance (design language from P1):**
`BrandColor.arcReactorGlow` in Swift (`App/Theme/BrandColors.swift`) returns a light-mode `#1E88E5` / dark-mode `#64B5F6` / Increase-Contrast `NSColor.controlAccentColor`. At startup, Swift resolves the current NSColor to an RGB hex string and emits a `theme` message:

```swift
// Swift-side theme emission (add to AppDelegate bootstrap, after webview loads)
let appearance = NSApp.effectiveAppearance
let color = BrandColor.arcReactorGlow.usingColorSpace(.sRGB)
let hex = String(format: "#%02X%02X%02X",
                 Int((color?.redComponent ?? 0) * 255),
                 Int((color?.greenComponent ?? 0) * 255),
                 Int((color?.blueComponent ?? 0) * 255))
bridge.send(.theme(arcReactorGlow: hex))

// Re-emit on appearance changes
NSApp.effectiveAppearance.perform(#selector(...)) // observe via KVO on .effectiveAppearance
```

Webview side:
```ts
// bus dispatcher handler for 'theme'
case 'theme':
  useJarvisStore.getState().setTheme({ arcReactorGlow: msg.arcReactorGlow })
  document.documentElement.style.setProperty('--arc-reactor-glow', msg.arcReactorGlow)
  break
```

CSS side:
```css
/* theme/tokens.css */
:root {
  --arc-reactor-glow: #1E88E5; /* default; overridden by bus 'theme' on startup */
  --bg: transparent;
  --text-primary: rgba(255, 255, 255, 0.92);
  --text-secondary: rgba(255, 255, 255, 0.64);
  --card-bg: rgba(20, 24, 30, 0.72);
  --card-border: rgba(255, 255, 255, 0.08);
}

@media (prefers-reduced-motion: reduce) {
  * {
    animation-duration: 0.01ms !important;
    animation-iteration-count: 1 !important;
    transition-duration: 0.01ms !important;
  }
}
```

**Why not compute the RGB hex on the TS side?** Because macOS `NSColor` semantic resolution (Increase Contrast → `controlAccentColor` → user's Accent Color) is an AppKit concern. Any JS attempt to match this lags the system state by one event loop tick. Swift is the truth.

## HUD State Enum Wire Format

Swift `HudState` is a simple string-backed enum. TS mirror is a discriminated string literal union. The bus message for state is a tagged object:

```swift
// App/Theme/HudState.swift — P3 extends
public enum HudState: String, Sendable, CaseIterable, Equatable, Codable {
    case idle
    case listening
    case thinking
    case speaking
    case awaitingConfirmation
    case reconfiguring   // P3 adds
    case booting         // P3 adds

    public var voiceOverLabel: String {
        switch self {
        case .idle: return "Jarvis, idle"
        case .listening: return "Jarvis, listening"
        case .thinking: return "Jarvis, thinking"
        case .speaking: return "Jarvis, speaking"
        case .awaitingConfirmation: return "Jarvis, waiting for your confirmation"
        case .reconfiguring: return "Jarvis, reconfiguring audio"
        case .booting: return "Jarvis, starting up"
        }
    }
}
```

```ts
// webview/src/bus/schemas.ts
export type HudState =
  | 'idle' | 'listening' | 'thinking' | 'speaking'
  | 'awaitingConfirmation' | 'reconfiguring' | 'booting'

export const HUD_STATES = [
  'idle', 'listening', 'thinking', 'speaking',
  'awaitingConfirmation', 'reconfiguring', 'booting',
] as const
```

**On-wire (outbound from Swift via `callAsyncJavaScript`):**
```json
{ "type": "hudState", "state": "listening" }
```

**Exhaustive switches (no `default`):** TS's `never`-type-based exhaustiveness check requires:
```ts
function assertNever(x: never): never { throw new Error(`Unhandled: ${x}`) }
switch (msg.type) {
  case 'hudState': ...; break
  case 'chat/tokenDelta': ...; break
  // ... every case ...
  default: return assertNever(msg)  // compile error if schema grows without us
}
```

## Testing Strategy

### Unit tests (Vitest + React Testing Library)

**Component layer — what lives in `webview/src/chat/__tests__/`:**

- `ToolCallCard.test.tsx` — expand/collapse state, pre-approval args hidden, each status label renders, aria-expanded reflects state.
- `TextPart.test.tsx` — appendTokenToLastText produces incremental render, stable key doesn't re-key.
- `ChatPanel.test.tsx` — flat list renders each event kind; ordering preserved on upsert; one tool-call card in the middle of two text parts renders all three in order.

**Store layer — `webview/src/store/__tests__/store.test.ts`:**

- `appendTokenToLastText` is a no-op if no matching ID.
- `upsertToolCall` inserts new by ID, updates in place for existing ID.
- `subscribeWithSelector(getHudState)` fires only on `hudState` change — not on `chatEvents` push.

**Bus dispatch layer — `webview/src/bus/__tests__/dispatch.test.ts`:**

- Round-trip each outbound message shape through dispatch; store reflects expected changes.
- Exhaustive message table maps every `type` to a handler (missing handler = compile error via TS union exhaustiveness).
- BUS_PROTOCOL_VERSION constant matches fixture file generated by `scripts/check-bus-protocol-version.sh` (which P2 ships).

### Swift integration tests

- `HudStateCoordinatorTests.swift` (XCTest, `@MainActor`) — under `App/Tests/AppTests/`. Cover every precedence pair:
  - awaitingConfirm true + speaking agent = awaitingConfirmation ✓
  - awaitingConfirm true + listening voice = awaitingConfirmation ✓
  - awaitingConfirm false + speaking + listening + thinking = speaking ✓
  - speaking agent trumps listening voice ✓
  - listening voice trumps thinking agent ✓
  - reconfiguring voice shown only when nothing higher ✓
  - booting shown until markReady() ✓
  - no-op when state doesn't change (single bus send)
- `HudStateBusSmokeTests.swift` — inject a mock `WebviewBridge`, drive three mock AsyncStreams, assert the mock bridge receives the expected `.hudState` sequence.
- `WebviewBundleLoadTests.swift` — new in P3. Assert `webview/dist/index.html` exists post-build, assert `loadFileRequest` succeeds, assert JavaScript side posts a `ready` message back within 2s (handshake check — belongs to P2 but verified here end-to-end).

### E2E / visual regression (Playwright, scaffold only in P3; gate in P8)

- Scaffold a single `webview/tests/e2e/ring-renders.spec.ts` that boots Vite dev server, renders `<App />`, asserts a `<canvas>` element is present and nonempty. Visual diff snapshots are deferred to P8.

### Validation Architecture (phase gate)

Per `.planning/config.json` `workflow.nyquist_validation: true` — include the Validation Architecture section below.

## Runtime State Inventory

P3 is NOT a rename/refactor phase. This section is omitted per research protocol rules.

## Common Pitfalls

### Pitfall 1: R3F component hooks `useJarvisStore` and kills 60 FPS

**What goes wrong:** Calling `const s = useJarvisStore(state => state.hudState)` inside a component that's rendered by R3F's `<Canvas>` causes the component to rerender every time hudState changes. If ANY selector elsewhere is non-memoized, you can even get one rerender per `chatEvents` append.

**Why it happens:** Zustand subscriptions fire on the hook call's selector return. If the selector returns a new reference (like `state.chatEvents` after a slice), every subscriber fires.

**How to avoid:** In `useFrame`, read state via `useJarvisStore.getState()` — a snapshot, no subscription. For state-change *reactions* (e.g., reset particle positions when transitioning from listening to speaking), use `subscribeWithSelector` imperative API and call it inside `useEffect`. Never put the store hook inside `useFrame`.

**Warning signs:** Chrome DevTools → Performance flame chart shows React commit/render during a pure animation frame. Or console counter increments per frame.

### Pitfall 2: WKWebView `loadFileURL` with single-file readAccess

**What goes wrong:** `webView.loadFileURL(indexURL, allowingReadAccessTo: indexURL)` loads `index.html` but 404s on every `assets/index-abc123.js` sibling.

**Why it happens:** The Apple docs are clear but easy to misread: when `readAccessURL` references a single file, only that file may be loaded. Starting in iOS 26.4 beta, the second parameter must point to a parent directory.

**How to avoid:** Use `loadFileRequest(_:allowingReadAccessTo:)` (macOS 12+) with `readAccessURL` pointing to the `webview/` *directory*, not `index.html`. Alternative: implement a `WKURLSchemeHandler` (e.g., `jarvis://`) — but that adds serialization overhead and CORS complexity unless you mark the scheme as secure.

**Warning signs:** Safari Web Inspector (attached to WKWebView) shows `net::ERR_FAILED` on asset requests with same directory.

```swift
// Correct pattern
let bundleURL = Bundle.main.resourceURL!.appendingPathComponent("webview", isDirectory: true)
let indexURL = bundleURL.appendingPathComponent("index.html")
webView.loadFileRequest(URLRequest(url: indexURL), allowingReadAccessTo: bundleURL)
```

### Pitfall 3: Vite build `base: '/'` breaks file:// loading

**What goes wrong:** Vite's default `base: '/'` generates `<script src="/assets/index-abc123.js">` — the browser resolves this against `file:///` root and 404s.

**Why it happens:** Vite assumes a web root. WKWebView with file:// has no root concept; everything is relative to the current document.

**How to avoid:** `vite.config.ts` with `base: './'`:
```ts
export default {
  base: './',
  build: { outDir: 'dist', assetsDir: 'assets', emptyOutDir: true },
  plugins: [react()],
}
```
Verify the built `index.html` has `<script src="./assets/...">` not `<script src="/assets/...">`.

**Warning signs:** Webview renders as blank with empty body; inspect shows 404 on `.js` chunks.

### Pitfall 4: Hot reload breaks when Hardened Runtime + allow-jit is wrong

**What goes wrong:** Dev server works in browser; fails in WKWebView Release build with JSC assertion: "WebKit Threading Violation - initial use of WebKit from a secondary thread." Or simply crashes.

**Why it happens:** Hardened Runtime without `com.apple.security.cs.allow-jit` disables JSC JIT. WebGL + React 19's concurrent renderer hammer JSC.

**How to avoid:** Landed in P1 — `App/Jarvis.entitlements` has `com.apple.security.cs.allow-jit = true`. **Do not widen to `allow-unsigned-executable-memory` — MLX ships precompiled Metallib so this entitlement is unnecessary and broadens the attack surface per R2-S4.**

**Warning signs:** Debug build works, Release build crashes on webview load. Verify at scaffold per P1 entitlement probe.

### Pitfall 5: R3F `useFrame` runs even when panel is hidden

**What goes wrong:** `JarvisHUDPanel.dismiss()` calls `orderOut(nil)` but the webview continues executing. `useFrame` keeps running, burning CPU and battery.

**Why it happens:** WKWebView doesn't suspend JS when its window is ordered out. `requestAnimationFrame` pauses when WKWebView is literally offscreen but not when it's just hidden.

**How to avoid:** Swift-side, emit a `visibility` bus message from `NSPanel.orderOut` / `orderFront` calls:
```swift
public override func orderOut(_ sender: Any?) {
    super.orderOut(sender)
    bridge?.send(.visibility(false))
}
public override func orderFrontRegardless() {
    super.orderFrontRegardless()
    bridge?.send(.visibility(true))
}
```
Webview side, use this to pause `useFrame`:
```tsx
const visible = useJarvisStore((s) => s.visibility)
useFrame(() => {
  if (!visible) return
  // ... animation code
})
```

Also — bonus — when `visible` flips to false, set `hudState` to `booting` locally OR clear mesh time for a clean "materialize" on next summon.

**Warning signs:** Activity Monitor shows Jarvis Helper process using 5-15% CPU when the HUD panel is dismissed. Top shows WebContent process non-idle.

### Pitfall 6: Reduce Transparency fallback breaks WebGL compositing

**What goes wrong:** When the user enables Reduce Transparency, P1's `JarvisHUDPanel` sets `backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.95)`. The WKWebView inside this panel renders WebGL content with transparent body. If the React side doesn't also paint a matching opaque background, the ring appears *over* the system chrome (unusable).

**Why it happens:** We assumed transparency all the way down; P1's fallback tints the panel but we never told the webview.

**How to avoid:** Swift emits `a11y` bus message on startup AND when `NSWorkspace.accessibilityDisplayOptionsDidChangeNotification` fires:
```swift
NSWorkspace.shared.notificationCenter.addObserver(
    forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
    object: nil, queue: .main
) { [weak self] _ in
    self?.emitA11y()
}

private func emitA11y() {
    bridge.send(.a11y(
        reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
        reduceTransparency: NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
    ))
}
```
CSS side:
```css
body[data-reduce-transparency="true"] {
  background: #101418;  /* solid matches panel tint */
}
```
And a tiny `useEffect` to toggle the attribute off the a11y store slice.

**Warning signs:** Reduce Transparency on + summon HUD = transparent webview floating over opaque panel tint = broken compositing.

### Pitfall 7: Token-delta race with text-start

**What goes wrong:** Swift sends `chat/textStart` (assigns id=abc) → `chat/tokenDelta` with id=abc. React store handles textStart async via setState, then tokenDelta arrives before React commits. `appendTokenToLastText("abc", "hello")` finds no event with id=abc. Token lost.

**Why it happens:** Zustand's `set()` is synchronous, but message dispatch may be async if we queue with `setTimeout(handler, 0)` for some reason.

**How to avoid:** Bus dispatcher runs synchronously on the message-handler callback. Do not wrap in `setTimeout`, `queueMicrotask`, or `Promise.resolve().then`. Zustand store mutations within the dispatch callback are synchronous — the `textStart` setState commits before `tokenDelta` handler runs, because they're different message events on different event-loop ticks.

The race *can* happen if Swift bundles both in one `callAsyncJavaScript` call and they dispatch in same tick... but P2's OutboundBatcher handles one payload per flush, so each message is its own tick. Verify with a batched-event integration test.

**Warning signs:** Chat panel shows empty text part but streaming clearly happened; replay log has tokens, UI doesn't.

### Pitfall 8: R3F + StrictMode double-mount disposes GPU resources twice

**What goes wrong:** React 19 StrictMode in dev mounts every component twice to detect side-effect bugs. R3F ran `geometry.dispose()` twice, causing the second render to allocate a new GPU buffer. Visually fine, silently doubles memory.

**Why it happens:** R3F 9 handles StrictMode correctly by default, but if you `useMemo` a `THREE.BufferGeometry` and manually dispose in cleanup, you can double-dispose.

**How to avoid:** Don't manually dispose geometries in `useMemo` cleanup. R3F's reconciler disposes on unmount. Use:
```tsx
const geometry = useMemo(() => new THREE.BufferGeometry(), [])
// DO NOT return a cleanup that calls geometry.dispose()
```

Trust the reconciler. Only hand-dispose if you're passing around geometry refs that outlive the component (we don't).

**Warning signs:** WebGL context lost warnings in dev console. Memory growing per mount/unmount cycle.

### Pitfall 9: Tool-call args leak before approval

**What goes wrong:** Swift's `ToolCallStart.args` field ships the real args payload over the bus, even for `requiresConfirmation` tools. User can inspect the webview's Zustand state and see the raw AppleScript before approving.

**Why it happens:** Default Swift behavior is to serialize the full args. R4-Sec5 / MCP-04 acceptance criterion says args must ship as `{awaitingApproval: true}` for confirmation-required tools.

**How to avoid:** Swift side, the `ToolCallStart` emitter checks the tool registry for `requiresConfirmation == true` and substitutes the payload. A dedicated `chat/toolCallArgsRevealed` event ships the real args only after `broker.approve`.

```swift
let argsPayload: AnyEncodable = tool.requiresConfirmation
    ? AnyEncodable(["awaitingApproval": true])
    : AnyEncodable(rawArgs)
bridge.send(.toolCallStart(id: id, name: name, args: argsPayload, turnId: turnId))
```

(This is primarily P5's concern, but the P3 schema must support both shapes and the TS side must NOT crash on `{awaitingApproval: true}`.)

**Warning signs:** Penetration test — webview inspector reveals AppleScript source in tool-call event before user approves.

## Code Examples

### Swift ↔ TS BUS_PROTOCOL_VERSION parity

```swift
// App/Bus/BusProtocol.swift (belongs to P2; P3 imports)
public enum BusProtocol {
    public static let version = "jarvis-bus-v1.0"
}
```

```ts
// webview/src/bus/BUS_PROTOCOL_VERSION.ts
export const BUS_PROTOCOL_VERSION = 'jarvis-bus-v1.0' as const
```

The P2 script `scripts/check-bus-protocol-version.sh` asserts these match verbatim.

### Vite config for WKWebView bundle

```ts
// webview/vite.config.ts
import { defineConfig } from 'vite'
import react from '@vitejs/plugin-react'

export default defineConfig({
  base: './',                          // REQUIRED for file:// loading
  plugins: [react()],
  build: {
    outDir: 'dist',
    assetsDir: 'assets',
    emptyOutDir: true,
    sourcemap: 'hidden',               // include but don't link — Safari DevTools can still load on-demand
    rollupOptions: {
      output: {
        // Stable chunk names for easier replay diffing
        chunkFileNames: 'assets/[name]-[hash].js',
        entryFileNames: 'assets/[name]-[hash].js',
        assetFileNames: 'assets/[name]-[hash][extname]',
      },
    },
  },
  server: {
    port: 5174,
    strictPort: true,
  },
})
```

### React app entry

```tsx
// webview/src/main.tsx
import { StrictMode } from 'react'
import { createRoot } from 'react-dom/client'
import { App } from './App'
import { attachBus } from './bus/client'
import './theme/tokens.css'

// Attach bus BEFORE React mounts — Swift may be sending theme/a11y already
attachBus()

const root = createRoot(document.getElementById('root')!)
root.render(
  <StrictMode>
    <App />
  </StrictMode>
)

// Send 'ready' up to Swift so HudStateCoordinator can markReady()
window.webkit?.messageHandlers?.jarvis?.postMessage({
  type: 'ready',
  busProtocolVersion: 'jarvis-bus-v1.0',
})
```

### App shell

```tsx
// webview/src/App.tsx
import { Canvas } from '@react-three/fiber'
import { RingMesh } from './hud/RingMesh'
import { ChatPanel } from './chat/ChatPanel'
import { useJarvisStore } from './store'

export function App() {
  const reduceTransparency = useJarvisStore((s) => s.a11y.reduceTransparency)
  return (
    <div
      className="jarvis-hud"
      data-reduce-transparency={reduceTransparency}
    >
      <div className="jarvis-hud__ring">
        <Canvas
          camera={{ position: [0, 0, 3], fov: 50 }}
          gl={{ alpha: true, premultipliedAlpha: false, antialias: true }}
          dpr={[1, 2]}
        >
          <RingMesh particles={512} />
        </Canvas>
      </div>
      <div className="jarvis-hud__panel">
        <ChatPanel />
      </div>
    </div>
  )
}
```

**Canvas config notes:**
- `alpha: true` — allow transparent backing so the panel transparency shows through.
- `premultipliedAlpha: false` — WebGL default is true; switching makes particle edges anti-alias better against transparent background.
- `dpr: [1, 2]` — DPI cap at 2; 3x on Retina hammers perf with 512 particles.

## State of the Art

| Old Approach | Current Approach (2026) | When Changed | Impact |
|--------------|------------------------|--------------|--------|
| R3F 8 + React 18 | R3F 9 + React 19 | R3F 9 released late 2025 | Pair with React 19; types + perf improvements |
| Rollup-based Vite 7 | Rolldown-based Vite 8 | Vite 8 GA March 2026 | 10-30× faster builds; LightningCSS default |
| `InstancedMesh` for everything | `InstancedMesh` for unique meshes; `Points` for point clouds | Long-standing three.js guidance | Particle rings = `Points`, not `InstancedMesh` |
| Direct `useEffect` + custom subscribe | `useSyncExternalStore` via Zustand 5 | React 18 / 19 concurrent rendering | Tear-free external state |
| `loadFileURL(_:allowingReadAccessTo:)` with same path both args | `loadFileRequest(_:allowingReadAccessTo: directory)` | macOS 12 / iOS 15; iOS 26.4 tightened | Single-file readAccess blocks asset loads |
| AI SDK 4 `useChat` with `content: string` messages | AI SDK 5 `UIMessage.parts: MessagePart[]` | AI SDK 5 early 2026 | Parts shape supports inline tool-calls cleanly |
| Multiple writers to UI state with ad-hoc ordering | Single-writer coordinator with precedence ladder | Post-R1 H-A3 race resolution in this project | No races; testable; HUD-08 |
| Synchronous `evaluateJavaScript` with string-interpolated JSON | `callAsyncJavaScript(_:arguments:)` with primitive args | WKWebView API update iOS 14+ / macOS 11+ | XSS-safe; no U+2028 foothold |

**Deprecated/outdated in project's own pre-GSD docs:**
- Sonnet as primary model (PROJECT.md rejects — Opus 4.7 primary).
- HotKey SPM / Carbon `RegisterEventHotKey` (R3-S4 overturned — use `NSEvent.addGlobalMonitorForEvents`). Not directly a P3 concern but context.
- ~~R3F 8 pattern docs~~ use R3F 9 patterns only.

## Assumptions Log

| # | Claim | Section | Risk if Wrong |
|---|-------|---------|---------------|
| A1 | Vite 8 with `base: './'` produces WKWebView-compatible relative paths | §Pitfall 3, §Vite config | Webview renders blank; easy to detect; fallback is WKURLSchemeHandler |
| A2 | Swift-side OutboundBatcher at 30 Hz is sufficient token-pacing; React doesn't need additional RAF buffering | §Pattern 5 | If P2 batching lumps 100 tokens into one flush, React still has to render a 100-char string diff in a single commit — likely fine, but profile in P4. Fallback pattern provided. |
| A3 | 512 particles is a safe target for 60 FPS on 4-year-old Apple Silicon | §Pattern 3 | Downgrade to 256 if perf under WebGL-via-Metal disappoints; ring readability still holds |
| A4 | WKWebView on macOS 26 Tahoe handles `alpha: true` WebGL context without Metal compositing bugs | §App shell, §Pitfall 6 | Reports of Metal-backend issues exist (see Sources); mitigation is to set the panel background to solid dark and run the ring over opaque bg at Reduce Transparency time anyway |
| A5 | drei 10.7 `shaderMaterial` API is stable and accepts `.glsl?raw` imports | §Standard Stack | Fallback is hand-rolled `THREE.ShaderMaterial` subclass (~30 LOC extra) |
| A6 | React 19 StrictMode double-mount is handled by R3F 9 reconciler | §Pitfall 8 | Worst case: manually dispose in cleanup with a mount-count guard |
| A7 | Swift-side `NSWorkspace.accessibilityDisplayShouldReduceMotion` change notification fires reliably | §Pitfall 6 | P1 MenuBarIconController already relies on this; if unreliable, poll every second (acceptable for accessibility) |
| A8 | The chat panel event-log pattern (flat ordered array, upsert by ID) scales to expected per-session event counts (<500) without virtualization in P3 | §Pattern 5 | P8 hardening adds `@tanstack/react-virtual` if profiling shows need |
| A9 | A single Zustand store with 5-6 slices is simpler than N micro-stores for this scale | §Pattern 2 | Refactor to split stores later is trivial; premature optimization costs more |
| A10 | The 7 HudState cases are stable; no 8th state emerges in P4-P7 | §HUD State Enum | Adding a case is additive; existing precedence ladder just inserts; low risk |

**All assumptions are verifiable during scaffold or first iteration. None block P3 start.**

## Open Questions

1. **Does P2 ship `visibility` bus message, or is it P3's problem?**
   - What we know: Pitfall 5 identifies the need to pause `useFrame` when panel is dismissed.
   - What's unclear: P2's scope covers "typed JSON bus + handshake + OutboundBatcher"; `visibility` is a concrete message type, not bus infrastructure.
   - Recommendation: P3 adds `visibility` to the message schema (Swift + TS) as part of extending the enum; P2's plan check confirms no message types are hard-coded.

2. **Vite `vite-plugin-glsl` or raw `?raw` imports for shader strings?**
   - What we know: Vite 8 supports `.glsl?raw` out of the box. `vite-plugin-glsl` adds `#include` support.
   - What's unclear: Do we need `#include` in P3? Our two shaders are short.
   - Recommendation: Start with `?raw`. If shaders grow (e.g., reusable noise functions), adopt `vite-plugin-glsl` in P4.

3. **Should we ship a Playwright visual-regression baseline for the ring in P3?**
   - What we know: Visual regression adds P3 surface area (Playwright browser install, baseline image management, flakiness).
   - What's unclear: Whether the ring design is stable enough (it isn't; we'll iterate in P4-P6 based on how it reads during real usage).
   - Recommendation: Scaffold Playwright only with a "canvas is present" smoke test. Visual diffs land in P8 when the design is locked.

4. **HudState enum label for `reconfiguring` precedence vs `idle`?**
   - What we know: HUD-08 specifies `awaitingConfirmation > speaking > listening > thinking > idle > booting > reconfiguring`.
   - What's unclear: This ladder reads oddly — `reconfiguring` is LOWEST priority, lower than `idle`. ARCHITECTURE.md R4-A9 says "publish as HUD state with held-last-state policy" and that's not quite the same.
   - Recommendation: Implement the ladder literally per HUD-08. If at runtime during voice device changes the ring shows `idle` instead of `reconfiguring`, revisit — but start with the literal spec. Document the ambiguity for `gsd-plan-phase` discussion.

5. **Do we need to inline BrandColors.swift values at build time, or accept the single startup bus round-trip?**
   - What we know: Startup theme emission via bus works but there's a ~50ms window where the webview has `--arc-reactor-glow: #1E88E5` default before Swift's real value arrives.
   - What's unclear: Whether that 50ms flash matters. User won't perceive it; dark-mode flash-of-wrong-theme is a known web concern though.
   - Recommendation: Accept the default fallback. If it's visible in cold-launch smoke tests, add a `scripts/emit-theme-defaults.sh` Xcode build phase that writes `webview/src/theme/defaults.css` from `BrandColors.swift`'s literal hex strings. Premature.

6. **WKScriptMessageHandlerWithReply known broken for replyHandler?**
   - What we know: [Apple Developer Forums thread](https://forums.developer.apple.com/forums/thread/751086) reports "never a single functioning example" of `WKScriptMessageHandlerWithReply` replies working.
   - What's unclear: Whether the reports are stale (2021-2023 vintage) or still true on macOS 26 Tahoe.
   - Recommendation: P2 plan-check phase should exercise the reply path end-to-end. If broken, fall back to request-ID correlation over two one-way messages. P3 doesn't depend heavily on reply-shape messages, so this is mostly a P2 concern.

## Environment Availability

| Dependency | Required By | Available (probe) | Version | Fallback |
|------------|-------------|-------------------|---------|----------|
| `pnpm` | webview build + dev | Probe: `command -v pnpm` | — | npm (pnpm is preferred for workspace/lockfile discipline; npm works for P3) |
| `node` | Vite toolchain | Probe: `node --version` (>= 20.19 for Vite 8) | — | **Blocking**: install Node 20 LTS or 22 |
| `xcodegen` | Already required by P1 | P1 landed | 2.40.0+ | N/A |
| `rsync` | Copy `webview/dist` into app bundle | macOS default | — | `ditto` (macOS-native alternative in the build script) |

**Planner probe step (at phase scaffold):**
```bash
command -v pnpm && pnpm --version
node --version   # require >= 20.19
command -v rsync
```

**Missing deps blocking:** If `node` is absent, phase cannot proceed. Surface as a human-action item in the Phase 3 preflight.

## Validation Architecture

### Test Framework

| Property | Value |
|----------|-------|
| Swift framework | XCTest, already wired in P1 (`JarvisAppTests` target) |
| Webview framework | Vitest 3 + @testing-library/react 17 (new in P3) |
| Swift config file | `project.yml` (xcodegen generates `.xcodeproj`) |
| Webview config file | `webview/vitest.config.ts` (new) |
| Quick run (Swift) | `xcodebuild test -project Jarvis.xcodeproj -scheme Jarvis -only-testing:JarvisAppTests/HudStateCoordinatorTests` |
| Quick run (web) | `cd webview && pnpm test -- --run --reporter=verbose src/store src/chat` |
| Full suite (Swift) | `xcodebuild test -project Jarvis.xcodeproj -scheme Jarvis` |
| Full suite (web) | `cd webview && pnpm test -- --run` |
| Combined (phase gate) | `xcodebuild test ... && cd webview && pnpm test -- --run && pnpm typecheck` |

### Phase Requirements → Test Map

| Req ID | Behavior | Test Type | Automated Command | File Exists? |
|--------|----------|-----------|-------------------|--------------|
| HUD-01 | WKWebView loads R3F bundle; canvas element present; handshake completes | integration (smoke) | `xcodebuild test -only-testing:JarvisAppTests/WebviewBundleLoadTests` | ❌ Wave 0 |
| HUD-02 | Each of 7 HudStates renders distinct shader params | unit (web) | `pnpm test -- --run src/hud/__tests__/stateUniforms.test.ts` | ❌ Wave 0 |
| HUD-07 (card lifecycle) | Pending → running → completed produces 3 rendered states | unit (web) | `pnpm test -- --run src/chat/__tests__/ToolCallCard.test.tsx` | ❌ Wave 0 |
| HUD-07 (ring + card dual) | Tool-call event both flips hudState and appends card | integration | `pnpm test -- --run src/bus/__tests__/dispatch-toolcall.test.ts` | ❌ Wave 0 |
| HUD-08 (precedence) | Every precedence pair resolves correctly | unit (Swift) | `xcodebuild test -only-testing:JarvisAppTests/HudStateCoordinatorTests` | ❌ Wave 0 |
| HUD-08 (single writer) | Static analysis: only `HudStateCoordinator` calls `bridge.send(.hudState)` | lint | `swift-grep-enforce.sh: no .hudState outside HudStateCoordinator` | ❌ Wave 0 |
| TEXT-02 (streaming) | 20 tokenDelta events produce 20-char text part | integration | `pnpm test -- --run src/chat/__tests__/streaming.test.tsx` | ❌ Wave 0 |
| TEXT-02 (chronology) | Fixture stream with tool-call between text parts renders in correct order | integration | `pnpm test -- --run src/chat/__tests__/chronology.test.tsx` | ❌ Wave 0 |

### Sampling Rate

- **Per task commit:** `cd webview && pnpm test -- --run src/<touched>` + `xcodebuild test -only-testing:<touched>`. < 30s target.
- **Per wave merge:** full web suite + full JarvisAppTests suite. ~60s target.
- **Phase gate:** full suite green + `pnpm typecheck` + `xcodebuild` Release archive builds successfully + webview bundle loads and emits `ready`.

### Wave 0 Gaps

- [ ] `webview/` entire package (net-new in P3)
- [ ] `webview/vitest.config.ts` + `webview/tsconfig.json`
- [ ] `App/HUD/HudStateCoordinator.swift` + test file
- [ ] `App/Bus/*` — sourced from P2; P3 extends schemas with chat + a11y + theme + visibility
- [ ] `scripts/build-webview.sh` — or inline into `project.yml` postBuildScripts
- [ ] `App/Tests/AppTests/HudStateCoordinatorTests.swift`
- [ ] `App/Tests/AppTests/WebviewBundleLoadTests.swift`

## Security Domain

Per `.planning/config.json` — `security_enforcement` not explicitly set, so enabled by default.

### Applicable ASVS Categories

| ASVS Category | Applies | Standard Control |
|---------------|---------|-----------------|
| V2 Authentication | no | No auth in Jarvis (single-user, personal) |
| V3 Session Management | no | No sessions |
| V4 Access Control | partial | Tool-call pre-approval gate (MCP-04) — args hidden until approved |
| V5 Input Validation | yes | Bus schemas with hand-written Codable + exhaustive switches (no `default`). SEC-09 prebuild script enforces Swift ↔ TS parity |
| V6 Cryptography | no | No crypto in the HUD |
| V9 Communications | yes | WKWebView content loaded from file:// only; no remote URLs; CSP meta tag denies external network |
| V13 API | partial | Bus is the API between Swift ↔ JS; typed, versioned, handshake-gated |
| V14 Configuration | yes | Hardened Runtime + allow-jit (SEC-02); Content-Security-Policy in `index.html` |

### Known Threat Patterns for webview layer

| Pattern | STRIDE | Standard Mitigation |
|---------|--------|---------------------|
| XSS via `evaluateJavaScript` string interpolation | Tampering | `callAsyncJavaScript(arguments:)` with primitive args only (HUD-04 lint-enforced) |
| Untrusted content injection via tool-result preview | Tampering | Tool-result preview is sanitized/truncated at MCP boundary before reaching bus (SEC-07 runs in P5) |
| Tool-call args disclosure before user approval | Information disclosure | Args replaced with `{awaitingApproval: true}` until `broker.approve` (MCP-04 / R4-Sec5) |
| Bus protocol drift (Swift and TS out of sync) | Tampering | SEC-09 prebuild script + TS exhaustive-switch `never` + hand-written Codable |
| Remote content loaded into webview | Spoofing | CSP meta: `default-src 'self'; script-src 'self'; connect-src 'none';` |
| WebGL / JSC JIT missing entitlement → crash | Denial of service | SEC-02 — `allow-jit` from day one (P1) |
| Tokens leaked into DevTools / replay | Information disclosure | ReplayLog redacts keys matching `Bearer *` and SDK patterns (OBS-06 in P1); webview keys NEVER held in webview heap (SEC-01) |

**CSP meta tag for `index.html`:**
```html
<meta http-equiv="Content-Security-Policy" content="
  default-src 'self';
  script-src 'self';
  style-src 'self' 'unsafe-inline';
  img-src 'self' data:;
  connect-src 'none';
  font-src 'self';
  object-src 'none';
  base-uri 'self';
  frame-ancestors 'none';
">
```

**Why `style-src 'unsafe-inline'`:** R3F doesn't inline styles, but React inline-styles are convenient for state-driven styling (e.g., progress indicator widths). If we want stricter CSP we can refactor to CSS classes; defer.

## Sources

### Primary (HIGH confidence)

- [React Three Fiber v9 Migration Guide](https://r3f.docs.pmnd.rs/tutorials/v9-migration-guide) — verified R3F 9 pairs with React 19
- [Vite 8.0 Release Blog](https://vite.dev/blog/announcing-vite8) — Rolldown + LightningCSS confirmed as default in v8
- [three.js r184 Release](https://github.com/mrdoob/three.js/releases/tag/r184) — OnFrameUpdate, 3× shader compile
- [drei shaderMaterial docs](https://drei.docs.pmnd.rs/shaders/shader-material) — API reference
- [drei PointMaterial docs](https://drei.docs.pmnd.rs/shaders/point-material) — Point material helper
- [Zustand subscribeWithSelector middleware](https://zustand.docs.pmnd.rs/reference/middlewares/subscribe-with-selector) — subscription with selector API
- [useSyncExternalStore — React docs](https://react.dev/reference/react/useSyncExternalStore) — external store integration
- [flushSync — React docs](https://react.dev/reference/react-dom/flushSync) — synchronous flush (use sparingly)
- [Swift AsyncStream — Apple Developer Documentation](https://developer.apple.com/documentation/swift/asyncstream) — AsyncStream API
- [WKWebView.loadFileRequest — Apple Developer Documentation](https://developer.apple.com/documentation/webkit/wkwebview/3752237-loadfilerequest) — loading local content
- [WKScriptMessageHandlerWithReply — Apple Developer](https://developer.apple.com/documentation/webkit/wkscriptmessagehandlerwithreply) — reply handler API
- [prefers-reduced-motion — MDN](https://developer.mozilla.org/en-US/docs/Web/CSS/Reference/At-rules/@media/prefers-reduced-motion) — CSS reduce-motion

### Secondary (MEDIUM confidence, verified against multiple sources)

- [Maxime Heckel — Magical world of particles](https://blog.maximeheckel.com/posts/the-magical-world-of-particles-with-react-three-fiber-and-shaders/) — particle pattern reference
- [Maxime Heckel — Study of shaders](https://blog.maximeheckel.com/posts/the-study-of-shaders-with-react-three-fiber/) — R3F shader patterns
- [Vercel AI SDK 5 — Vercel blog](https://vercel.com/blog/ai-sdk-5) — `UIMessage.parts` shape
- [sitepoint — Controlling React streaming chaos](https://www.sitepoint.com/streaming-backends-react-controlling-re-render-chaos/) — RAF batching
- [SwiftUI + WKWebView messaging tutorial — Medium](https://medium.com/@yeeedward/messaging-between-wkwebview-and-native-application-in-swiftui-e985f0bfacf) — reply-handler caveats
- [three.js forum — InstancedMesh vs InstancedBufferGeometry](https://discourse.threejs.org/t/instancedmesh-vs-instancedbuffergeometry/31058) — when to use which
- [Vite 8 Beta announcement — Rolldown-powered](https://vite.dev/blog/announcing-vite8-beta) — bundler change
- [Testing in 2026: Jest vs Vitest — Nucamp](https://www.nucamp.co/blog/testing-in-2026-jest-react-testing-library-and-full-stack-testing-strategies) — industry 2026 recommendation
- [zustand docs — testing guide](https://github.com/pmndrs/zustand/blob/main/docs/guides/testing.md) — mock patterns

### Tertiary (LOW confidence — single source, flagged for scaffold-time validation)

- [Apple Developer Forums — WKScriptMessageHandlerWithReply broken](https://forums.developer.apple.com/forums/thread/751086) — reply handler reports; may be stale
- [WKWebView WebGL Metal issues — Apple Developer](https://developer.apple.com/forums/thread/45852) — 2021 vintage; verify on macOS 26 Tahoe
- [Chasing 240 FPS — DEV community](https://dev.to/gokhan_koc_88338a026508b3/chasing-240-fps-on-llm-chats-4gde) — anecdotal perf tuning
- [llm-ui library](https://github.com/llm-ui-kit/llm-ui) — community streaming library (not used, referenced as pattern)

### Project-internal (HIGH confidence — load-bearing for this phase)

- `CLAUDE.md` — architectural decisions, settled framework choices
- `.planning/PROJECT.md` — project context, constraints
- `.planning/REQUIREMENTS.md` — HUD-01/02/07/08, TEXT-02 exact wording
- `.planning/research/RESEARCH-DELTAS.md` — RESEARCH-DELTAS authoritative corrections
- `.planning/research/ARCHITECTURE.md` — single-writer pattern, AsyncChannel back-pressure, barrier chain
- `.planning/ROADMAP.md` — Phase 3 scope, success criteria
- `.planning/phases/01-foundations/01-03-SUMMARY.md` — what P1 shipped (panels, banner coord, HudState enum at 5 cases)
- `.planning/phases/01-foundations/01-UI-SPEC.md` — design contract inherited into P3 (arc-reactor-glow, Reduce Motion fallbacks, accessibility rules)
- `App/HUD/JarvisHUDPanel.swift` — panel + webView scaffold exists
- `App/Theme/HudState.swift` — P1 enum at 5 cases; P3 extends to 7
- `App/Theme/BrandColors.swift` — light/dark/contrast-aware glow color

## Metadata

**Confidence breakdown:**

- Standard stack: **HIGH** — R3F 9.6.0, drei 10.7.6, three r184, Vite 8, Zustand 5 all independently verified via npmjs / GitHub release pages.
- Architecture (HudStateCoordinator single-writer): **HIGH** — ARCHITECTURE.md + SE-0406 + Swift Forums all converge; P1 `HudState` enum and `JarvisHUDPanel` are in place.
- Particle ring design: **MEDIUM** — shader patterns well-documented; empirical perf at 512 particles on Apple Silicon is unverified until scaffold; Metal-backend compositing bugs are historically documented, may be fixed on macOS 26 Tahoe.
- Chat-panel event-log pattern: **MEDIUM-HIGH** — AI SDK 5 validates the parts-array approach; Zustand 5 + flat list is well-trodden React pattern; no novel territory.
- Bus schema parity: **HIGH** — P2 ships SEC-09; we just extend.
- Testing strategy: **MEDIUM** — Vitest + RTL for web is 2026-standard; Playwright visual-regression deferred intentionally.
- Token-streaming performance: **MEDIUM** — relies on P2 OutboundBatcher cadence we haven't measured; fallback RAF pattern documented.

**Research date:** 2026-04-22
**Valid until:** 2026-06-22 (Vite/R3F ecosystem moves fast; re-validate versions if P3 execution slips >6 weeks)

---

*Phase 3 research authored: 2026-04-22. Status: ready for `gsd-plan-phase 3`.*
