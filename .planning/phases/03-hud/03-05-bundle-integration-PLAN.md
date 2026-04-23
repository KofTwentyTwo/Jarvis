---
phase: 03-hud
plan: 05
type: execute
wave: 3
depends_on: [03-01, 03-02, 03-03, 03-04]
files_modified:
  - project.yml
  - scripts/build-webview.sh
  - scripts/check-single-writer-hudstate.sh
  - App/AppDelegate.swift
  - App/HUD/HudStateCoordinator.swift
  - App/Resources/webview/index.html
  - App/Resources/webview/.gitignore
  - App/Tests/AppTests/WebviewBundleLoadTests.swift
  - App/Tests/AppTests/HudStateCoordinatorBusWiringTests.swift
  - .gitignore
autonomous: true
requirements: [HUD-01, HUD-08]
tags: [swift, xcodegen, wkwebview, hud, integration, loadFileRequest, bundle, end-to-end]

assumptions:
  - "Plan 03-05 runs in Wave 3 AFTER Plans 03-01 + 03-02 + 03-03 + 03-04 all land. No parallel execution possible — this plan depends on the outputs of all four earlier plans."
  - "Plan 03-01 shipped `App/HUD/HudStateCoordinator.swift` with a Bus-agnostic `emit: @MainActor (App.HudState) -> Void` injection seam. This plan wires that closure to `webviewBridge.send(.hudState(bus-cast))` using a small `App.HudState → Bus.HudState` rawValue bridge."
  - "Plan 03-04 shipped a working webview bundle at `webview/packages/hud/dist/` that needs to land at `Jarvis.app/Contents/Resources/webview/` before codesign. Blue-folder xcodegen wiring from Plan 02-03 is reused (Plan 02-03 SUMMARY line 112 'blue-folder reference')."
  - "Plan 02-03 wired `installBus()` to load `App/Resources/webview/bus-harness.html`. This plan REPLACES that load target with the R3F bundle's `index.html` (same directory, different file)."
  - "`bus-harness.html` is KEPT in the bundle during this plan's work (as a fallback + for 02-04 parity script) — it just isn't loaded into the panel anymore. Plan 02-04 `scripts/check-bus-harness-parity.sh` still needs it to exist. A future plan can retire `bus-harness.html` when it's truly unused."
  - "Pre-build script `scripts/build-webview.sh` wraps `cd webview && pnpm install --frozen-lockfile && pnpm --filter @jarvis/bus build && pnpm --filter @jarvis/hud build && rsync -a --delete webview/packages/hud/dist/ App/Resources/webview/`. Committed `App/Resources/webview/` serves as the bundle-vendored artifact (same pattern as Plan 02-03's bus-harness.html); the build script refreshes it. .gitignore excludes the `dist/`-copied JS chunks but INCLUDES the index.html + the `webview/.gitignore` pattern file so the directory structure survives checkout."
  - "Webview bundle size (expected ~1 MB based on three.js + R3F + React 19 ESM) is committed into App/Resources/webview/ to avoid CI build-time pnpm install. If this is unacceptable the user can swap to build-on-CI; Plan 03-05 commits the artifacts as the default."
  - "The WKWebView JIT entitlement (Plan 01) is already in Debug + Release entitlement files. No entitlement changes needed."
  - "End-to-end integration test: `WebviewBundleLoadTests` boots `AppDelegate` with real `installBus()`, waits for `uiReady` within 2 seconds, asserts `handshakeState == .armed`. This test EXERCISES the full pipeline: bundle load → injection.js → @jarvis/bus auto-ack → helloAck → armed. An XCTest-host-host-aware short-circuit is already in place per 02-03 deviation #5."
  - "Xcode 26 `xcodebuild test -only-testing:JarvisAppTests` is a known broken path per 02-03 SUMMARY line 220 (`debug/xctest-launch-runningboard-error-5.md`). The end-to-end integration test uses `xcodebuild build` + post-build verification (find Jarvis.app/Contents/Resources/webview/index.html + spawn App briefly + observe uiReady in logs) rather than XCTest. This is a deliberate workaround documented in the plan and tracked as a Phase 1 UAT item."

must_haves:
  truths:
    - "`App/Resources/webview/index.html` exists AND references `./assets/*.js` (from Plan 03-02's Vite build with `base: './'`)"
    - "`App/Resources/webview/assets/` directory exists with at least one `.js` chunk ≥100 KB (the React+R3F+three bundle)"
    - "`scripts/build-webview.sh` is executable; running it from repo root rebuilds webview/packages/hud/dist/ and rsyncs to App/Resources/webview/"
    - "`project.yml` `preBuildScripts` (or postBuildScripts — whichever is right for the codesign ordering) invokes `scripts/build-webview.sh` BEFORE `verify-entitlements.sh --pre-codesign` + `codesign.sh` so the webview bundle is covered by the signature"
    - "`AppDelegate.installBus()` is modified: the `Bundle.main.url(forResource: \"bus-harness\", withExtension: \"html\", subdirectory: \"webview\")` call is replaced with `Bundle.main.url(forResource: \"index\", withExtension: \"html\", subdirectory: \"webview\")` — the HUD now loads the R3F bundle"
    - "`AppDelegate` constructs a `HudStateCoordinator` wired to the `webviewBridge` via an `emit` closure that bridges `App.HudState → Bus.HudState` (rawValue-keyed) and calls `webviewBridge.send(.hudState(...))` on the MainActor"
    - "The HudStateCoordinator is STARTED with three AsyncStreams (agent + voice + confirmation) — Phase 3 provides NO producers for these, so installBus() creates three dormant AsyncStreams with never-yielding continuations that are retained by AppDelegate. Phase 4/5/6 will replace these dormant producers with real subsystem-emitted streams."
    - "On handshake armed, AppDelegate.installBus() calls `coordinator.markReady()` so the HUD transitions from `.booting` to `.idle` as soon as the webview is responsive"
    - "`scripts/check-single-writer-hudstate.sh` is activated as an Xcode pre-build script (added in Plan 03-01 but not wired until now); runs on every build; fails the build if `BusOutbound.hudState(...)` is constructed outside `HudStateCoordinator.swift`"
    - "`App/Tests/AppTests/WebviewBundleLoadTests.swift` asserts: (a) `Bundle.main.url(forResource: \"index\", withExtension: \"html\", subdirectory: \"webview\")` resolves, (b) at least one file matching `assets/*.js` exists under the webview subdirectory, (c) the HTML content references relative paths (`./assets/`) not absolute"
    - "`App/Tests/AppTests/HudStateCoordinatorBusWiringTests.swift` asserts: AppDelegate wires the coordinator's emit closure to bridge.send; an injected mock bridge observes the .hudState outbound call when the coordinator's emit closure fires via a test-triggered `markReady()` or explicit state transition"
    - "All existing Phase 1 + Phase 2 XCTest cases still green (47 Bus + 20+ App tests)"
  artifacts:
    - path: "scripts/build-webview.sh"
      provides: "Pre-codesign webview build + rsync-to-bundle script"
      contains: "pnpm --filter @jarvis/hud build"
    - path: "App/Resources/webview/index.html"
      provides: "R3F bundle entry HTML (replaces bus-harness.html as the load target)"
      contains: "Content-Security-Policy"
    - path: "App/HUD/HudStateCoordinator.swift"
      provides: "Coordinator from Plan 03-01 — this plan adds the Bus.HudState rawValue bridge helper"
      contains: "Bus.HudState"
    - path: "App/AppDelegate.swift"
      provides: "installBus() updated to load index.html; constructs + starts HudStateCoordinator; activates markReady() on handshake armed"
      contains: "HudStateCoordinator"
    - path: "App/Tests/AppTests/WebviewBundleLoadTests.swift"
      provides: "Bundle presence + index.html relative-path assertions"
      contains: "index.html"
    - path: "App/Tests/AppTests/HudStateCoordinatorBusWiringTests.swift"
      provides: "Wiring-observation tests for coordinator → bridge emit"
      contains: "HudStateCoordinator"
    - path: "project.yml"
      provides: "preBuildScripts chain: build-webview.sh → verify-entitlements --pre-codesign → codesign.sh → verify-entitlements --post-codesign"
      contains: "build-webview.sh"
  key_links:
    - from: "App/AppDelegate.swift"
      to: "App/HUD/HudStateCoordinator.swift"
      via: "construction + start() + markReady()"
      pattern: "HudStateCoordinator\\("
    - from: "App/AppDelegate.swift installBus"
      to: "App/Resources/webview/index.html"
      via: "Bundle.main.url(forResource: \"index\", withExtension: \"html\", subdirectory: \"webview\")"
      pattern: "forResource: \"index\""
    - from: "App/HUD/HudStateCoordinator.swift emit closure (wired in AppDelegate)"
      to: "packages/Bus/Sources/Bus/WebviewBridge.swift send"
      via: "rawValue bridge + bridge.send(.hudState(busState))"
      pattern: "bridge\\.send\\(\\.hudState"
---

<objective>
Wire Phase 3's four earlier plans into a working end-to-end HUD experience. This is the integration plan — zero new component work, all plumbing. The user should be able to build `Jarvis.app` and cold-launch it; the HUD panel, when summoned, loads the R3F bundle, completes the bus handshake in <2 seconds, shows the particle ring transitioning `.booting → .idle`, and renders an empty chat panel ready for Phase 4's orchestrator to populate.

Components of the integration:
1. **Pre-build script** (`scripts/build-webview.sh`) that runs `pnpm install --frozen-lockfile` + `pnpm --filter @jarvis/bus build` + `pnpm --filter @jarvis/hud build` + rsyncs `webview/packages/hud/dist/` into `App/Resources/webview/` BEFORE `verify-entitlements.sh --pre-codesign` + `codesign.sh`.
2. **xcodegen project.yml wiring** — add the pre-build script to `preBuildScripts` in the correct order; ensure the blue-folder reference at `App/Resources/webview` (already present from Plan 02-03) covers the new bundle files.
3. **AppDelegate.installBus()** — replace the `bus-harness.html` load target with `index.html`; construct a `HudStateCoordinator` and start it with three dormant AsyncStreams; wire the coordinator's `emit` closure to `webviewBridge.send(.hudState(...))`; call `coordinator.markReady()` on `onHandshakeArmed`.
4. **App.HudState → Bus.HudState bridge** — a trivial `String`-rawValue round-trip helper inside HudStateCoordinator.swift (or a dedicated `HudStateBridge.swift` utility — whichever composes more cleanly).
5. **`scripts/check-single-writer-hudstate.sh` activation** — wire it into `project.yml` preBuildScripts now that HudStateCoordinator is actually called from AppDelegate.
6. **Integration tests** — `WebviewBundleLoadTests` asserts bundle presence + relative paths; `HudStateCoordinatorBusWiringTests` asserts the wiring observation.

Purpose: HUD-01 + HUD-08 end-to-end validation. After this plan, the success criteria from ROADMAP §Phase 3 are demonstrable with a single `xcodebuild build && Jarvis.app/Contents/MacOS/Jarvis` launch: the R3F ring renders, the bus handshake completes, state transitions Swift → webview work, and the chat panel is ready to receive Phase 4's streaming events. Any end-to-end bug from the earlier plans (version drift, CSP violation, loadFileRequest scoping, JSC JIT entitlement mismatch) surfaces HERE, not in Phase 4 when we're trying to debug orchestrator semantics.

Output: a launchable, code-signed, build-hardened `Jarvis.app` whose HUD renders the R3F bundle. The path from agent-state-transition to pixel is fully wired end-to-end, with no producer yet but architecturally complete. All Phase 3 requirements (HUD-01, HUD-02, HUD-07, HUD-08, TEXT-02) are closed from within Phase 3's scope.
</objective>

<execution_context>
@~/.claude/get-shit-done/workflows/execute-plan.md
@~/.claude/get-shit-done/templates/summary.md
</execution_context>

<context>
@CLAUDE.md
@.planning/PROJECT.md
@.planning/ROADMAP.md
@.planning/REQUIREMENTS.md
@.planning/phases/03-hud/03-RESEARCH.md
@.planning/phases/02-bus/02-03-SUMMARY.md
@App/AppDelegate.swift
@App/HUD/JarvisHUDPanel.swift
@App/HUD/HudStateCoordinator.swift
@App/Theme/HudState.swift
@packages/Bus/Sources/Bus/Protocol.swift
@packages/Bus/Sources/Bus/BusOutbound.swift
@packages/Bus/Sources/Bus/WebviewBridge.swift
@scripts/codesign.sh
@scripts/verify-entitlements.sh
@project.yml

<interfaces>
<!-- From Plan 03-01 (Plan 03-01 ships HudStateCoordinator; this plan consumes it): -->

```swift
@MainActor
public final class HudStateCoordinator {
    public init(emit: @escaping @MainActor (HudState) -> Void)
    public func start(
        agent: AsyncStream<AgentHudIntent>,
        voice: AsyncStream<VoiceHudIntent>,
        confirmation: AsyncStream<ConfirmHudIntent>
    )
    public func markReady()
    public var currentStateForTests: HudState { get }
}
```

<!-- App.HudState (Plan 03-01 at 7 cases) and Bus.HudState (Plan 02-01 at 7 cases) share rawValues verbatim: -->

Both enums have these 7 String-rawValue cases:
`"idle"`, `"listening"`, `"thinking"`, `"speaking"`, `"awaitingConfirmation"`, `"reconfiguring"`, `"booting"`

So the bridge is a 1-line rawValue round-trip:
```swift
guard let busState = Bus.HudState(rawValue: appState.rawValue) else {
    assertionFailure("HudState rawValue drift: \(appState.rawValue) not a Bus case")
    return
}
```

<!-- From `AppDelegate.installBus()` (Plan 02-03): -->

Current body (excerpt from 02-03):
```swift
let bridge = WebviewBridge(webView: panel.webView, alertPresenter: ...)
bridge.onHandshakeArmed = { [weak self] in ... }
webviewBridge = bridge
guard let harnessURL = Bundle.main.url(forResource: "bus-harness", withExtension: "html", subdirectory: "webview") else { ... }
panel.webView.loadFileURL(harnessURL, allowingReadAccessTo: resourcesDir)
```

Change: `bus-harness` → `index`; add HudStateCoordinator construction + start + emit-closure wiring; call `coordinator.markReady()` inside `onHandshakeArmed`.

<!-- Project.yml current shape (from Read: lines 40-80): -->

Current `project.yml` has:
```yaml
packages:
  Keychain: ...
  Config: ...
  Logging: ...
  Shell: ...
  Bus: ...
targets:
  Jarvis:
    sources:
      - path: App
        excludes: [Info.plist, *.entitlements, Tests/**, Resources/**]
      - path: App/Resources/webview
        type: folder
        buildPhase: resources
    settings: { ... }
    preBuildScripts: # may or may not exist yet; verify via Read
```

Plan 03-05 adds a `preBuildScripts` entry for `scripts/build-webview.sh` BEFORE the existing `verify-entitlements.sh --pre-codesign` and `codesign.sh` chain.
</interfaces>
</context>

<tasks>

<task type="auto">
  <name>Task 1: Pre-build webview integration — scripts/build-webview.sh + project.yml preBuildScripts wiring + commit the webview bundle artifacts under App/Resources/webview/</name>
  <files>scripts/build-webview.sh, project.yml, App/Resources/webview/index.html, App/Resources/webview/.gitignore, .gitignore</files>
  <action>
    1. Create `scripts/build-webview.sh`:
       ```bash
       #!/usr/bin/env bash
       # Pre-build script: produces webview/packages/hud/dist/ and rsyncs into
       # App/Resources/webview/ so the R3F bundle is covered by the app bundle
       # codesign pass.
       #
       # Order matters:
       #   build-webview.sh (this script)
       #   verify-entitlements.sh --pre-codesign
       #   codesign.sh (signs Jarvis.app INCLUDING Contents/Resources/webview/)
       #   verify-entitlements.sh --post-codesign
       set -euo pipefail
       SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
       REPO_ROOT="$(dirname "$SCRIPT_DIR")"
       cd "$REPO_ROOT/webview"
       # Install only if lockfile newer than node_modules stamp (content-hash sentinel).
       LOCKFILE_SHA=$(shasum -a 256 pnpm-lock.yaml | cut -d' ' -f1)
       STAMP_FILE="node_modules/.jarvis-lock-sha256"
       if [ ! -d node_modules ] || [ ! -f "$STAMP_FILE" ] || [ "$(cat "$STAMP_FILE" 2>/dev/null)" != "$LOCKFILE_SHA" ]; then
           echo "[build-webview] pnpm install (lockfile changed or fresh)..."
           pnpm install --frozen-lockfile
           echo "$LOCKFILE_SHA" > "$STAMP_FILE"
       fi
       echo "[build-webview] building @jarvis/bus..."
       pnpm --filter @jarvis/bus build
       echo "[build-webview] building @jarvis/hud..."
       pnpm --filter @jarvis/hud build
       echo "[build-webview] rsync dist/ -> App/Resources/webview/..."
       # Preserve App/Resources/webview/.gitignore + any non-dist files (e.g. the
       # bus-harness.html Plan 02-03 committed which Plan 02-04's parity script
       # still needs to exist). Only rsync the dist contents; do not --delete
       # the destination because other vendored assets coexist here.
       rsync -a --exclude=.gitignore --exclude=bus-harness.html \
             "$REPO_ROOT/webview/packages/hud/dist/" \
             "$REPO_ROOT/App/Resources/webview/"
       echo "[build-webview] done"
       ```
       Make it executable: `chmod +x scripts/build-webview.sh`.
    2. Update `project.yml` to add the pre-build script. Locate the existing preBuildScripts section (from Phase 1; if absent, create it) and ensure this ordering:
       ```yaml
       preBuildScripts:
         - name: Build webview bundle
           script: |
             bash "$SRCROOT/scripts/build-webview.sh"
           basedOnDependencyAnalysis: false
           runOnlyWhenInstalling: false
         - name: Verify single-writer HUD state
           script: |
             bash "$SRCROOT/scripts/check-single-writer-hudstate.sh"
           basedOnDependencyAnalysis: false
         - name: Verify entitlements (pre-codesign)
           script: |
             bash "$SRCROOT/scripts/verify-entitlements.sh" --pre-codesign
           basedOnDependencyAnalysis: false
         # ... existing codesign.sh + post-codesign verify steps stay here
       ```
       If Phase 1 already wired verify-entitlements / codesign via a different mechanism (e.g. `postBuildScripts` or a custom `buildPhases` array), adapt — but keep the ordering invariant: webview build → single-writer lint → entitlement pre-verify → codesign → entitlement post-verify.
    3. Create `App/Resources/webview/.gitignore`:
       ```
       # Assets directory is regenerated by scripts/build-webview.sh every build.
       # We commit index.html (stable entry) but let the build script manage
       # hashed asset files freely.
       assets/
       ```
       This lets index.html stay source-of-truth-committed while the hashed asset chunks are regenerated. Alternatively, commit EVERYTHING — simpler but makes commits noisier whenever dependencies update. Plan 03-05 decision: commit index.html only, gitignore assets/. Document in SUMMARY.md.
    4. Run `bash scripts/build-webview.sh` to produce the initial bundle. Commit `App/Resources/webview/index.html` (from the rsync). Do NOT commit `App/Resources/webview/assets/*` (gitignored).
    5. Update top-level `.gitignore` if needed to exclude `webview/*/node_modules` and `webview/*/dist` — Phase 2 likely already did this; verify and don't duplicate.
    6. Run `xcodegen generate && xcodebuild build -project Jarvis.xcodeproj -scheme Jarvis -destination 'platform=macOS,arch=arm64' -configuration Debug` — build succeeds.
    7. Confirm the built app bundle has the webview subdirectory with the new index.html:
       `find Jarvis.app/Contents/Resources/webview/index.html` → resolves.
       `find Jarvis.app/Contents/Resources/webview/assets -name '*.js'` → at least one file.
       `grep -q './assets/' Jarvis.app/Contents/Resources/webview/index.html` → 0 exit.
  </action>
  <verify>
    <automated>bash scripts/build-webview.sh &amp;&amp; xcodegen generate &amp;&amp; xcodebuild build -project Jarvis.xcodeproj -scheme Jarvis -destination 'platform=macOS,arch=arm64' -configuration Debug 2>&amp;1 | tail -5 &amp;&amp; test -f App/Resources/webview/index.html &amp;&amp; test -d App/Resources/webview/assets &amp;&amp; BUILT=$(find ~/Library/Developer/Xcode/DerivedData -name 'Jarvis.app' -path '*/Debug/*' 2>/dev/null | head -1) &amp;&amp; test -f "$BUILT/Contents/Resources/webview/index.html" &amp;&amp; grep -q '\./assets/' "$BUILT/Contents/Resources/webview/index.html"</automated>
  </verify>
  <done>
    - `scripts/build-webview.sh` exists and is executable.
    - Running it produces `webview/packages/hud/dist/*` and rsyncs it into `App/Resources/webview/` without deleting bus-harness.html.
    - `project.yml` preBuildScripts chain runs build-webview.sh BEFORE single-writer lint BEFORE verify-entitlements --pre-codesign BEFORE codesign.sh.
    - `xcodebuild build` succeeds.
    - The built app bundle has `Contents/Resources/webview/index.html` with relative asset paths.
    - `cd packages/Bus && swift test` stays 47/47 green (proves no regression in existing Bus package tests).
  </done>
</task>

<task type="auto" tdd="true">
  <name>Task 2: AppDelegate.installBus() updates — load index.html instead of bus-harness.html; construct + start HudStateCoordinator; wire emit closure; markReady() on handshake armed; activate single-writer lint</name>
  <files>App/AppDelegate.swift, App/HUD/HudStateCoordinator.swift, scripts/check-single-writer-hudstate.sh, App/Tests/AppTests/HudStateCoordinatorBusWiringTests.swift</files>
  <behavior>
    - Test W1 (HudStateCoordinatorBusWiringTests.test_coordinatorConstructedInInstallBus): after `applicationWillFinishLaunching` with a mocked Bundle that has both bus-harness.html AND index.html, `delegate.hudStateCoordinator != nil`.
    - Test W2 (test_emitClosureBridgesToBusSend): inject a recording evaluator into `WebviewBridge`; drive the coordinator through a state change; assert the recorded evaluator arguments include a hudState JSON matching the expected bus rawValue string.
    - Test W3 (test_markReadyCalledOnHandshakeArmed): install the bridge; simulate handshake armed via `bridge.handleHelloAck(BUS_PROTOCOL_VERSION)`; assert `coordinator.currentStateForTests != .booting` (any state promoted off booting is correct).
    - Test W4 (test_appHudStateRawValueMatchesBusHudState): table-driven assertion that every `App.HudState.allCases.map(\\.rawValue)` also exists in `Bus.HudState.allCases.map(\\.rawValue)`. Catches rawValue drift between the two enums.
    - Test W5 (test_dormantStreamsHeldByDelegate): after installBus(), `delegate.dormantAgentContinuation`, `delegate.dormantVoiceContinuation`, `delegate.dormantConfirmContinuation` are all non-nil (these are held so the coordinator's for-await Tasks don't drain). Future Phase 4/5/6 replace these with real producer streams.
    - Test W6 (test_installBusLoadsIndexNotHarness): assert `panel.webView.url` (after mocked loadFileURL) targets `index.html` not `bus-harness.html` (via a test-visible capture of the last loaded URL on the panel's webView — use a subclass of JarvisHUDPanel that records the last loadFileURL call).
    - Test B1 (WebviewBundleLoadTests.test_indexHtmlInBundle): `Bundle.main.url(forResource: "index", withExtension: "html", subdirectory: "webview")` resolves when running inside the built app (not under XCTest-host mode, which may lack the resource — document).
    - Test B2 (WebviewBundleLoadTests.test_assetsDirectoryNonEmpty): same Bundle URL → parent → `assets/` → ≥1 .js file.
    - Test B3 (WebviewBundleLoadTests.test_indexHtmlReferencesRelativePaths): read index.html; grep for `src="./assets/`; assert ≥1 match; grep for `src="/assets/`; assert 0 matches.
  </behavior>
  <action>
    1. Update `App/HUD/HudStateCoordinator.swift` (from Plan 03-01) to add a Bus bridge helper. The coordinator itself is already Bus-agnostic; add a file-scope free function (or a static on a small helper type):
       ```swift
       import Bus // OK for this utility — NOT on the coordinator class itself.
       /// Bridges `App.HudState` (UI concerns, voiceOverLabel) to `Bus.HudState`
       /// (wire format). Lock-step via shared rawValue strings. A drift in
       /// rawValue between the two enums is an internal bug — the assertion
       /// catches it in Debug; in Release we fall back to `.idle` to avoid
       /// wedging the HUD on a dev-time typo.
       public func busState(from appState: HudState) -> Bus.HudState {
           guard let bus = Bus.HudState(rawValue: appState.rawValue) else {
               assertionFailure("HudState rawValue drift: \(appState.rawValue) not in Bus.HudState")
               return .idle
           }
           return bus
       }
       ```
       NOTE: both enums are `public enum HudState: String`. Because `App.HudState` and `Bus.HudState` share the same short name, the file-scope `busState(from:)` MUST be placed in a context that can name both types. Two options:
       (a) Keep the function in `HudStateCoordinator.swift` and rely on `import Bus` making `Bus.HudState` available; reference the App enum unqualified (via its own module) and the Bus enum qualified (`Bus.HudState`).
       (b) Move the helper to a new tiny file `App/HUD/HudStateBridge.swift` that imports Bus and exports a single function. Option (b) is cleaner; do that.
       Create `App/HUD/HudStateBridge.swift`:
       ```swift
       import Bus
       /// Translate the App-side HudState into the Bus-side HudState for wire
       /// emission. Bridges the two same-named enums whose rawValue strings are
       /// kept in lock-step by construction — if they drift, the fallback to
       /// .idle prevents a crash but fires an assertion in Debug.
       @MainActor
       public func busHudState(from app: HudState) -> Bus.HudState {
           guard let bus = Bus.HudState(rawValue: app.rawValue) else {
               assertionFailure("HudState rawValue drift: \(app.rawValue) not in Bus.HudState")
               return .idle
           }
           return bus
       }
       ```
       (The `@MainActor` annotation isn't strictly required — the function is a pure value transform — but it aligns call-site expectations since the only caller is the coordinator's emit closure which is @MainActor.)
    2. Update `App/AppDelegate.swift`:
       - Add property: `var hudStateCoordinator: HudStateCoordinator?`
       - Add private stored properties for the three dormant stream continuations so they don't deinit:
         ```swift
         private var dormantAgentContinuation: AsyncStream<AgentHudIntent>.Continuation?
         private var dormantVoiceContinuation: AsyncStream<VoiceHudIntent>.Continuation?
         private var dormantConfirmContinuation: AsyncStream<ConfirmHudIntent>.Continuation?
         ```
         (Mark these `internal` so `@testable import App` can assert W5.)
       - Modify `installBus()`:
         - Change `forResource: "bus-harness"` → `forResource: "index"`
         - After constructing the `bridge`, construct the coordinator:
           ```swift
           let coordinator = HudStateCoordinator(emit: { [weak bridge] appState in
               guard let bridge else { return }
               Task { @MainActor in
                   try? await bridge.send(.hudState(busHudState(from: appState)))
               }
           })
           // Create three dormant streams — Phase 4/5/6 replace with real producers.
           let (agentStream, agentCont) = AsyncStream<AgentHudIntent>.makeStream()
           let (voiceStream, voiceCont) = AsyncStream<VoiceHudIntent>.makeStream()
           let (confirmStream, confirmCont) = AsyncStream<ConfirmHudIntent>.makeStream()
           self.dormantAgentContinuation = agentCont
           self.dormantVoiceContinuation = voiceCont
           self.dormantConfirmContinuation = confirmCont
           coordinator.start(agent: agentStream, voice: voiceStream, confirmation: confirmStream)
           self.hudStateCoordinator = coordinator
           ```
         - Update the existing `bridge.onHandshakeArmed` callback to call `coordinator.markReady()` so the first `.hudState(.idle)` fires immediately after handshake:
           ```swift
           bridge.onHandshakeArmed = { [weak self] in
               self?.systemLogger?.info("bus handshake armed — HUD ready")
               self?.hudStateCoordinator?.markReady()
               self?.onBusArmed?()
           }
           ```
    3. Update `scripts/check-single-writer-hudstate.sh` — switch the allowlist from `HudStateCoordinator.swift` (as Plan 03-01 drafted) to `HudStateCoordinator.swift` PLUS `HudStateBridge.swift` (which also constructs `.hudState(...)` indirectly via the emit closure — actually, re-reading, `HudStateBridge.swift` returns a `Bus.HudState` which is then passed INTO `.hudState(...)` at the AppDelegate call site). The .hudState(_:) construction site is in `AppDelegate.swift` inside the emit closure. Update the allowlist to include `AppDelegate.swift` — but ONLY INSIDE the specific emit-closure block.
       A simpler, more honest lint: allow `.hudState(...)` inside `AppDelegate.swift` AND `HudStateCoordinator.swift` AND `HudStateBridge.swift`, forbid it anywhere else:
       ```bash
       HITS=$(grep -rn '\.hudState(' App/ packages/ --include='*.swift' \
           | grep -v '/Tests/' \
           | grep -v 'App/HUD/HudStateCoordinator.swift' \
           | grep -v 'App/HUD/HudStateBridge.swift' \
           | grep -v 'App/AppDelegate.swift' \
           | grep -v 'packages/Bus/Sources/Bus/BusOutbound.swift' \
           | grep -v '//' || true)
       ```
       Rationale: AppDelegate is the wiring layer. Phase 4 + later plans should NOT add new `.hudState(...)` call sites — instead, they drive the coordinator's input streams (voice → coordinator, agent → coordinator, confirm → coordinator) which funnel into the single emit call at AppDelegate. The lint still catches the canonical R1 H-A3 anti-pattern (voice or agent directly constructing `.hudState`), just with a 2-file allowlist instead of 1.
    4. Create `App/Tests/AppTests/HudStateCoordinatorBusWiringTests.swift`. Because the XCTest-host-launch path is broken on Xcode 26 per 02-03 SUMMARY line 220, focus these tests on path that COMPILE and can be driven via a direct AppDelegate instance:
       - W1, W5 can be driven by instantiating `AppDelegate()`, mocking `entitlementProbe`/`configLoader`/`keychainStore`, and calling `applicationWillFinishLaunching(...)` directly. The test-host short-circuit per 02-03 deviation #5 skips the loadFileURL in XCTest, but still constructs the bridge + coordinator.
       - W2, W3 use the existing `FakeJSEvaluator` pattern from 02-03's `WebviewBridgeOutboundTests` to observe outbound calls.
       - W4 is a pure compile-time+runtime assertion: `for appCase in App.HudState.allCases { XCTAssertNotNil(Bus.HudState(rawValue: appCase.rawValue)) }`.
       - W6 requires a test double of JarvisHUDPanel. Simplest approach: extract the "which HTML file does installBus load?" decision into an internal `@testable` String property on AppDelegate (e.g., `var webviewEntryFilename: String = "index"` — set once in installBus so tests can assert it equals "index"). This is less invasive than subclassing JarvisHUDPanel.
    5. Create `App/Tests/AppTests/WebviewBundleLoadTests.swift`. All three tests (B1, B2, B3) need access to the BUILT bundle. Since `xcodebuild test -only-testing:` is broken, these are STRUCTURAL tests that inspect the repo-level `App/Resources/webview/` directory (which the build script keeps in sync):
       ```swift
       func test_indexHtmlInRepoWebviewDir() throws {
           let fm = FileManager.default
           let srcRoot = URL(fileURLWithPath: #filePath)
               .deletingLastPathComponent() // AppTests/
               .deletingLastPathComponent() // Tests/
               .deletingLastPathComponent() // App/
               .deletingLastPathComponent() // repo root
           let indexHTML = srcRoot.appendingPathComponent("App/Resources/webview/index.html")
           XCTAssertTrue(fm.fileExists(atPath: indexHTML.path), "index.html must be committed at App/Resources/webview/")
       }
       func test_indexHtmlReferencesRelativeAssets() throws {
           let srcRoot = repoRoot() // helper using #filePath as above
           let indexHTML = srcRoot.appendingPathComponent("App/Resources/webview/index.html")
           let html = try String(contentsOf: indexHTML, encoding: .utf8)
           XCTAssertTrue(html.contains("./assets/"), "index.html must reference relative asset paths per Vite base: './'")
           XCTAssertFalse(html.contains("src=\"/assets/"), "index.html must NOT reference absolute /assets/ paths (WKWebView file:// breaks them)")
       }
       ```
       (B2 test_assetsDirectoryNonEmpty is skipped at the XCTest layer because `App/Resources/webview/assets/` is gitignored — the asset directory only exists after `scripts/build-webview.sh` runs. Instead, test that AT LEAST the index.html references a specific assets/*.js path which Vite generated. If the build script hasn't run yet, the test fails — that's correct behavior because we want to catch "someone committed an index.html without building".)
    6. Run `xcodegen generate && xcodebuild build -project Jarvis.xcodeproj -scheme Jarvis -destination 'platform=macOS,arch=arm64' -configuration Debug`. Build succeeds.
    7. Run `cd packages/Bus && swift test` — 47/47 green.
    8. Run `bash scripts/check-single-writer-hudstate.sh` — exit 0 (AppDelegate is now allowlisted).
    9. Attempt `xcodebuild test` targeted at the new tests; document any RunningBoard error per 02-03 SUMMARY in this plan's SUMMARY.md. Structural tests (reading files from repo) work fine under `swift test` if we put them in a `swift test`-compatible path — but App tests are Xcode-scheme-bound. Acceptable outcome: tests compile clean; document the Xcode 26 xctest-launch blocker as a Phase 1 UAT item that Plan 01-05 flagged.
  </action>
  <verify>
    <automated>xcodegen generate &amp;&amp; xcodebuild build -project Jarvis.xcodeproj -scheme Jarvis -destination 'platform=macOS,arch=arm64' -configuration Debug 2>&amp;1 | tail -5 &amp;&amp; cd packages/Bus &amp;&amp; swift test 2>&amp;1 | tail -5 &amp;&amp; cd .. &amp;&amp; bash scripts/check-single-writer-hudstate.sh &amp;&amp; grep -c 'HudStateCoordinator' App/AppDelegate.swift &amp;&amp; grep -c 'forResource: "index"' App/AppDelegate.swift</automated>
  </verify>
  <done>
    - `App/AppDelegate.swift` constructs + starts a HudStateCoordinator in installBus().
    - Bridge emit closure translates App.HudState → Bus.HudState via busHudState() helper.
    - installBus() loads `index.html` (not bus-harness.html).
    - Three dormant stream continuations are held by AppDelegate (Phase 4/5/6 replace them).
    - `coordinator.markReady()` fires on `onHandshakeArmed`.
    - `scripts/check-single-writer-hudstate.sh` exits 0 with AppDelegate + HudStateCoordinator + HudStateBridge allowlisted.
    - `HudStateCoordinatorBusWiringTests.swift` + `WebviewBundleLoadTests.swift` compile clean.
    - `xcodebuild build` succeeds end-to-end.
    - `cd packages/Bus && swift test` stays 47/47 green.
  </done>
</task>

<task type="auto">
  <name>Task 3: End-to-end smoke — launch the built app, observe uiReady + HUD render via a spawn-and-sample approach (workaround for broken xcodebuild test on Xcode 26)</name>
  <files>scripts/smoke-test-hud.sh, App/Tests/AppTests/WebviewBundleLoadTests.swift</files>
  <action>
    1. Create `scripts/smoke-test-hud.sh`:
       ```bash
       #!/usr/bin/env bash
       # End-to-end smoke: boot Jarvis.app briefly, assert uiReady arrives.
       # Workaround for Xcode 26 xcodebuild test RunningBoard error — this
       # validates what xctest would if it weren't broken.
       set -euo pipefail
       SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
       REPO_ROOT="$(dirname "$SCRIPT_DIR")"
       # Locate built app.
       BUILT_APP=$(find ~/Library/Developer/Xcode/DerivedData -type d -name 'Jarvis.app' -path '*/Debug/*' 2>/dev/null | head -1)
       if [[ -z "$BUILT_APP" ]]; then
           echo "ERROR: No built Jarvis.app found in DerivedData. Run xcodebuild build first." >&2
           exit 1
       fi
       echo "[smoke] using built app: $BUILT_APP"
       echo "[smoke] verifying webview bundle..."
       test -f "$BUILT_APP/Contents/Resources/webview/index.html" || { echo "MISSING index.html"; exit 1; }
       test -d "$BUILT_APP/Contents/Resources/webview/assets" || { echo "MISSING assets/"; exit 1; }
       ASSET_COUNT=$(ls "$BUILT_APP/Contents/Resources/webview/assets/"*.js 2>/dev/null | wc -l | tr -d ' ')
       test "$ASSET_COUNT" -ge 1 || { echo "NO JS CHUNKS in assets/"; exit 1; }
       # Verify relative paths survived.
       grep -q "\./assets/" "$BUILT_APP/Contents/Resources/webview/index.html" || { echo "index.html LACKS ./assets/"; exit 1; }
       ! grep -q 'src="/assets/' "$BUILT_APP/Contents/Resources/webview/index.html" || { echo "index.html HAS absolute /assets/"; exit 1; }
       echo "[smoke] PASS: bundle is present, relative paths preserved, $ASSET_COUNT asset chunks"
       # Optional runtime smoke (user-driven; not in CI):
       #   open "$BUILT_APP" &
       #   sleep 3
       #   tail -20 ~/Library/Logs/Jarvis/system.log | grep -q "bus handshake armed"
       #   osascript -e 'tell application "Jarvis" to quit' || true
       # The runtime launch is intentionally a manual step documented in
       # the SUMMARY.md post-plan checklist — CI does not spawn GUI apps.
       ```
       `chmod +x scripts/smoke-test-hud.sh`.
    2. Run `scripts/smoke-test-hud.sh` after a clean `xcodebuild build`. It should pass.
    3. Append a manual-UAT section to the plan's SUMMARY.md (see output section) that documents the expected manual smoke test:
       1. Open the built `.app` from DerivedData.
       2. Click the menu-bar J icon → HUD panel summons.
       3. Observe the particle ring (should appear within ~200ms).
       4. Observe state transition from `.booting` → `.idle` (check `~/Library/Logs/Jarvis/system.log` for `bus handshake armed` + `HUD ready`).
       5. Dismiss the HUD (Escape key).
       6. Quit the app.
    4. Document the smoke script in `README.md` usage (if README is still the historical injection-note one, skip — otherwise add a `scripts/smoke-test-hud.sh` invocation under a "Smoke Testing" section).
  </action>
  <verify>
    <automated>xcodegen generate &amp;&amp; xcodebuild build -project Jarvis.xcodeproj -scheme Jarvis -destination 'platform=macOS,arch=arm64' -configuration Debug 2>&amp;1 | tail -3 &amp;&amp; bash scripts/smoke-test-hud.sh</automated>
  </verify>
  <done>
    - `scripts/smoke-test-hud.sh` is executable.
    - It passes after `xcodebuild build`.
    - Manual UAT checklist is documented in SUMMARY.md.
  </done>
</task>

</tasks>

<threat_model>
## Trust Boundaries

| Boundary | Description |
|----------|-------------|
| Webview bundle filesystem scope | `loadFileURL` with `allowingReadAccessTo:` is scoped to `App/Resources/webview/` parent directory. WKWebView cannot escape to parent dirs. Vite's `base: './'` keeps asset refs inside the bundle. |
| Bundle integrity at codesign time | `scripts/build-webview.sh` runs BEFORE codesign.sh. Post-codesign, any tampering with `Contents/Resources/webview/*.js` invalidates the signature and macOS Gatekeeper refuses to launch. |
| HudState single-writer (runtime) | Enforced at compile time by `scripts/check-single-writer-hudstate.sh` allowlisting only HudStateCoordinator + HudStateBridge + AppDelegate. Runtime enforcement relies on the coordinator being the only AppDelegate-held writer — no way for Phase 4+ code to insert another without failing the lint. |
| Dormant stream retention | Three AsyncStream continuations are held by AppDelegate; without this, Swift 6 continuation drop would terminate the coordinator's three for-await Tasks. The pattern is intentional. |

## STRIDE Threat Register

| Threat ID | Category | Component | Disposition | Mitigation Plan |
|-----------|----------|-----------|-------------|-----------------|
| T-03-40 | Tampering | Bundle asset poisoning post-codesign | mitigate | Codesign covers the full `App/Resources/webview/` directory (blue-folder reference in project.yml from Plan 02-03). Any mutation post-install invalidates the signature. |
| T-03-41 | Tampering | Build-step ordering — webview build runs AFTER codesign | mitigate | Task 1 explicit ordering: `build-webview.sh` first, then entitlement pre-verify, then codesign.sh, then post-verify. A misordered project.yml would be caught by `find Jarvis.app/Contents/Resources/webview/assets/*.js` failing post-build. |
| T-03-42 | Spoofing | Malicious webview loaded via loadFileURL path traversal | mitigate | `Bundle.main.url(forResource:subdirectory:)` produces a sandboxed URL; `allowingReadAccessTo:` is scoped to the webview parent dir. No user-controlled path concatenation. |
| T-03-43 | Tampering | App.HudState vs Bus.HudState rawValue drift | mitigate | `busHudState()` helper asserts on drift; Test W4 table-enforces that every App.HudState rawValue exists in Bus.HudState at test time. If they ever diverge, the test fires. |
| T-03-44 | DoS | HudStateCoordinator never ready (handshake timeout) | mitigate | `onHandshakeMismatch` default from Plan 02-03 is `NSApp.terminate`. Hard-block on mismatch. `markReady()` inside `onHandshakeArmed` closure means boot state persists if handshake fails — user sees `.booting` forever and the PO modal simultaneously. |
| T-03-45 | Repudiation | Missing uiReady (webview bundle didn't load) | mitigate | Plan 02-03's handshake timeout fires after 2s; HUD never promotes from booting. User sees the failure mode visibly (vs. silent no-op). The existing timeout + alertPresenter path (02-03) catches this. |
| T-03-46 | DoS | Pre-build pnpm install slow/flaky in CI | accept | `scripts/build-webview.sh` uses `--frozen-lockfile` + content-hash stamp for cache. Committing the full `App/Resources/webview/` directory (including assets) is an alternative if CI is slow; Plan 03-05 defers that decision to SUMMARY.md. |
</threat_model>

<verification>
Phase-gate for Plan 03-05:
1. `xcodegen generate && xcodebuild build -project Jarvis.xcodeproj -scheme Jarvis -destination 'platform=macOS,arch=arm64' -configuration Debug` succeeds.
2. `bash scripts/build-webview.sh` exits 0 with webview/packages/hud/dist/ synced to App/Resources/webview/.
3. `bash scripts/check-single-writer-hudstate.sh` exits 0 with the AppDelegate allowlist active.
4. `bash scripts/smoke-test-hud.sh` passes after a clean build.
5. `cd packages/Bus && swift test` reports 47/47 green.
6. `cd webview && pnpm --filter @jarvis/hud test` reports ≥36 tests passing (from Plans 03-02/03/04).
7. Built app bundle has `Contents/Resources/webview/index.html` + `Contents/Resources/webview/assets/*.js` + relative asset paths.
8. `grep -c 'HudStateCoordinator' App/AppDelegate.swift` ≥ 2 (construction + markReady).
9. `grep -c 'busHudState' App/HUD/HudStateBridge.swift` ≥ 1.
10. Running the app manually (not in CI) shows the ring + handshake-armed log message within 3 seconds of cold-launch.
11. All Phase 3 must_haves from Plans 03-01 through 03-04 remain satisfied (truths/artifacts/key-links from the prior plans' frontmatter).
</verification>

<success_criteria>
- Phase 3 closes: HUD-01, HUD-02, HUD-07, HUD-08, TEXT-02 all validated through at least one test path + a manual smoke observation.
- The user can build + launch Jarvis.app; the HUD panel shows the R3F particle ring with state `.idle` within 2 seconds of summon.
- HudStateCoordinator is the sole writer of HUD state, wired to the bus via a rawValue bridge, starting in `.booting` and promoting to `.idle` on handshake armed.
- Pre-build script chain produces + signs the webview bundle correctly.
- All tests from Plans 03-01 through 03-04 remain green.
- `cd packages/Bus && swift test` stays 47/47 green — no regression in Phase 2 bus package.
- The xcodebuild-test-launch blocker from Xcode 26 is documented as a known limitation (inherited from 02-03); Plan 03-05 does NOT fix it (Phase 1 or a dedicated test-infra plan handles it).
</success_criteria>

<output>
After completion, create `.planning/phases/03-hud/03-05-SUMMARY.md`:
- Frontmatter `requirements-completed: [HUD-01, HUD-08]` (rounds out coverage of all Phase 3 REQ IDs; HUD-02/HUD-07/TEXT-02 were closed within-webview by Plans 03-03/03-04 and Plan 03-05 integrates end-to-end).
- Decisions: committing `index.html` to the repo while gitignoring `assets/*`; pre-build-script ordering vs codesign; dormant AsyncStream continuation retention pattern; the 3-file allowlist for the single-writer lint (HudStateCoordinator + HudStateBridge + AppDelegate).
- Known stubs: three dormant producer streams (Phase 4 replaces agent; Phase 5 replaces confirmation; Phase 6 replaces voice); `audioLevel` bus message has a no-op dispatcher arm awaiting Phase 6.
- Manual UAT checklist (6 steps):
  1. `xcodebuild build -configuration Debug` clean
  2. `scripts/smoke-test-hud.sh` passes
  3. Open built Jarvis.app from DerivedData
  4. Menu-bar click summons HUD panel
  5. Ring visible; state logs show `.booting` → `.idle`
  6. Manual trigger of `hudStateCoordinator` by simulating inbound intent (optional dev-overlay action — future plan)
- Xcode 26 xcodebuild test blocker documented; structural file-read tests replace XCTest-launch tests per 02-03 precedent.
- Phase 4 ready: AgentOrchestrator replaces the dormant agent stream with a real AsyncStream producer that emits `.thinking` / `.speaking` intents; Phase 4 also extends @jarvis/bus with richer chat-lifecycle messages and updates the webview dispatcher.
- Phase 6 ready: VoiceController replaces the dormant voice stream with real `.listening` / `.reconfiguring` intents; also enables the audio-level bus message flow.
- Phase 5 ready: ConfirmationBroker replaces the dormant confirmation stream; tool-call approval UI is rendered in a native NSPanel (per RESEARCH Pitfall 9) but the "(hidden until you approve)" webview defense-in-depth from Plan 03-04 continues to render.
</output>
