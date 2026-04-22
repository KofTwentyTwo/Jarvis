---
phase: 01-foundations
plan: 03
subsystem: ui
tags: [appkit, nspanel, nsstatusitem, wkwebview, swiftui, core-animation, accessibility, swift6, xctest]

# Dependency graph
requires:
  - phase: 01-foundations
    provides: "Plan 01-01 scaffold — Jarvis.xcodeproj App target, entitlements pair, Info.plist with JarvisEntitlementsVerified=false, Assets.xcassets skeleton, empty AppDelegate stub"
provides:
  - "App/Theme/HudState.swift — 5-case HudState enum with verbatim UI-SPEC VoiceOver labels"
  - "App/Theme/BrandColors.swift — BrandColor.arcReactorGlow with light/dark variants + Increase Contrast fallback"
  - "App/MenuBar/CAAnimationFactory.swift — Reduce-Motion-guarded helpers (breath/rotate/shimmer/glow/state-crossfade)"
  - "App/MenuBar/MenuBarIconController.swift — @MainActor NSStatusItem controller with 5-state CABasicAnimation machine, left-click vs right-click disambiguation, rate-limited VoiceOver announcements"
  - "App/MenuBar/MenuBarContextMenu.swift — NSMenu builder (Setup… / Settings…-disabled / Show Dev Overlay / Copy State Dump / Quit ⌘Q) with closure-trampoline actions"
  - "App/HUD/JarvisHUDPanel.swift — borderless 720×720 .nonactivatingPanel at .statusBar level with transparent WKWebView, Escape/⌘W dismiss, Reduce Transparency fallback"
  - "App/HUD/HUDBannerPanel.swift — .floating non-activating 360pt banner panel, top-trailing positioning, never steals focus"
  - "App/HUD/HUDBannerCoordinator.swift — priority-queue coordinator with pre-emption + dismissed-this-launch dedup"
  - "App/HUD/BannerContent.swift — 4 preset banners at priorities 1-4 (keychain-empty > input-monitoring-denied > hotkey-bind-failed > ollama-url-rejected)"
  - "App/HUD/HUDBanner.swift — SwiftUI banner view with arc-reactor-glow leading stripe on .hudWindow visual-effect background"
  - "App/AppDelegate.swift — EntitlementGateProbe protocol + test-injectable onEntitlementFailure, NSAlert .critical + NSApp.terminate on production path, menu-bar + HUD panel + banner panel install"
  - "App/Assets.xcassets/Icon-MenuBar-Template.imageset/Icon-MenuBar-Template.pdf — 22×22pt arc-reactor silhouette placeholder (outer 18pt ring + mid 12pt ring + filled 4pt core + six 60°-interval spokes)"
  - "JarvisAppTests xctest target + Jarvis.xcscheme wiring test action"
  - "PBXCopyFilesBuildPhase for Contents/Helpers preserved across 3 xcodegen regenerations"
affects:
  - "01-04-shell-wizard-wiring (wires setupAction/devOverlayToggleAction/stateDumpAction closures, enqueue banner triggers on IM-denied/keychain-empty/hotkey-fail/ollama-rejected, hotkey toggles JarvisHUDPanel)"
  - "01-05-codesign-entitlement-probe (verify-entitlements.sh --pre-codesign flips JarvisEntitlementsVerified to YES so AppDelegate gate passes)"
  - "Phase 3 HUD (loads R3F bundle into JarvisHUDPanel's transparent WKWebView)"

# Tech tracking
tech-stack:
  added:
    - "AppKit + QuartzCore (CABasicAnimation/CAKeyframeAnimation/CATransition for menu-bar state animations)"
    - "WebKit (WKWebView inside JarvisHUDPanel — empty in P1, renders R3F in P3)"
    - "SwiftUI + NSHostingView (HUDBanner view hosted inside HUDBannerPanel)"
    - "XCTest Unit Testing Bundle (JarvisAppTests target with Bundle Loader + TEST_HOST)"
  patterns:
    - "S-2: @MainActor on every AppKit-touching controller (MenuBarIconController, HUDBannerCoordinator, HUDBannerPanel, JarvisHUDPanel, AppDelegate)"
    - "S-6: Hard-block on safety failures — AppDelegate reads Info.plist JarvisEntitlementsVerified; NSAlert .critical + NSApp.terminate on false"
    - "S-7: Reduce Motion / Reduce Transparency / Increase Contrast fallbacks wired day one (each CAAnimationFactory helper guards shouldReduceMotion; JarvisHUDPanel honors shouldReduceTransparency; BrandColor.arcReactorGlow falls back under shouldIncreaseContrast)"
    - "XCTest host-skip: @MainActor static AppDelegate.isRunningAsTestHost detects XCTestConfigurationFilePath env var; production default onEntitlementFailure no-ops under XCTest to prevent host-app termination before test bundle loads"
    - "Core Animation gotcha #2: after layer.anchorPoint = (0.5, 0.5), re-anchor via layer.frame = button.bounds to avoid rotation jumping to bottom-left (Apple DevForums 88341)"
    - "NSMenuItem closure trampoline: @MainActor private ClosureTarget NSObject subclass holds a strong ref to the closure; NSMenuItem.target = ClosureTarget(action:), action = #selector(ClosureTarget.run)"

key-files:
  created:
    - "App/Theme/HudState.swift"
    - "App/Theme/BrandColors.swift"
    - "App/MenuBar/CAAnimationFactory.swift"
    - "App/MenuBar/MenuBarIconController.swift"
    - "App/MenuBar/MenuBarContextMenu.swift"
    - "App/HUD/JarvisHUDPanel.swift"
    - "App/HUD/HUDBannerPanel.swift"
    - "App/HUD/HUDBannerCoordinator.swift"
    - "App/HUD/BannerContent.swift"
    - "App/HUD/HUDBanner.swift"
    - "App/Assets.xcassets/Icon-MenuBar-Template.imageset/Icon-MenuBar-Template.pdf"
    - "App/Tests/AppTests/MenuBarIconControllerTests.swift"
    - "App/Tests/AppTests/JarvisHUDPanelTests.swift"
    - "App/Tests/AppTests/HUDBannerCoordinatorTests.swift"
    - "App/Tests/AppTests/AppDelegateEntitlementTests.swift"
    - "Jarvis.xcodeproj/xcshareddata/xcschemes/Jarvis.xcscheme"
  modified:
    - "App/AppDelegate.swift (was empty stub from Plan 01; now full entitlement gate + install chain)"
    - "App/Assets.xcassets/Icon-MenuBar-Template.imageset/Contents.json (added filename key)"
    - "project.yml (added JarvisAppTests target + scheme + Tests/ exclude + copyFiles stanza)"
    - "Jarvis.xcodeproj/project.pbxproj (regenerated by xcodegen 3×; PBXCopyFilesBuildPhase re-applied each time)"

key-decisions:
  - "XCTest host-skip in AppDelegate.defaultOnEntitlementFailure — required so Jarvis.app launching as test host doesn't terminate before JarvisAppTests loads; production path unchanged"
  - "Removed webView.isOpaque = false (get-only in Swift WKWebView); transparency still achieved via drawsBackground=false (KVO) + underPageBackgroundColor=.clear"
  - "onEntitlementFailure closure typed as @MainActor () -> Void (explicit) for Swift 6 strict-concurrency function-value conversion"
  - "Menu-bar arc-reactor silhouette authored via Swift + Core Graphics (no external tooling); 22×22pt PDF with outer 18pt ring + mid 12pt ring + filled 4pt core + six radial spokes at 60° intervals per UI-SPEC Surface 3 lines 374-383"
  - "Icon-MenuBar-Template.imageset idiom left as 'universal' per plan action block (Plan 01 scaffold had 'mac'; plan action overrides)"

patterns-established:
  - "xcodegen-regeneration dance: project.yml is the source of truth; after each regeneration the PBXCopyFilesBuildPhase for Contents/Helpers must be manually re-inserted (xcodegen strips empty copyFiles phases). Documented in 01-01 SUMMARY and re-validated here."
  - "Banner priority semantics: lower priority int = higher precedence; coordinator pre-empts the current banner only when the new banner's priority < current's; dismissed-this-launch is tracked by BannerContent.id in a Set<String> that persists until app restart"
  - "@MainActor XCTest discipline: tests are @MainActor final class X: XCTestCase; @testable import Jarvis for the App module; status-item cleanup via defer { NSStatusBar.system.removeStatusItem(item) } so tests don't leak menu-bar chrome"

requirements-completed: [SHELL-01, SHELL-03, SHELL-04]

# Metrics
duration: 57min
completed: 2026-04-22
---

# Phase 1 Plan 03: App Shell UI Summary

**Menu-bar NSStatusItem with 5-state CABasicAnimation machine, borderless transparent JarvisHUDPanel (WKWebView ready for R3F in P3), separate HUDBannerPanel + coordinator with 4 priority-ordered preset banners, and AppDelegate entitlement hard-block — 13 XCTest tests pass on Swift 6 strict concurrency.**

## Performance

- **Duration:** 57 min
- **Started:** 2026-04-22T17:30:10Z
- **Completed:** 2026-04-22T18:27:15Z
- **Tasks:** 3 of 3 complete
- **Files created:** 16 (10 sources + 1 PDF + 4 test files + 1 xcscheme)
- **Files modified:** 4 (AppDelegate.swift, Icon-MenuBar-Template/Contents.json, project.yml, project.pbxproj)
- **Tests added:** 13 (all pass; see "Test Count" below)

## Accomplishments

- `MenuBarIconController` drives 5 HudState animations (idle / listening / thinking / speaking / awaitingConfirmation) via Core Animation on `NSStatusItem.button.layer.transform`/`opacity`; no `layer.contents` swaps (RESEARCH Q7 rule); Reduce Motion fallbacks active in every helper.
- Left-click toggles HUD; right-click or Ctrl-click shows a 5-item NSMenu (Setup… / Settings… (disabled) / Show Dev Overlay / Copy State Dump / Quit Jarvis ⌘Q). Click-type disambiguation done via `NSApp.currentEvent` inspection per D-16.
- `JarvisHUDPanel` exposes the full UI-SPEC Surface 7 style envelope: `.borderless` + `.nonactivatingPanel`, `.statusBar` level, `.canJoinAllSpaces`/`.fullScreenAuxiliary`/`.transient` collection behavior, transparent WKWebView (`drawsBackground=false` via KVO + `underPageBackgroundColor=.clear`), Escape + ⌘W dismiss via `cancelOperation(_:)` / `performClose(_:)`, Reduce Transparency fallback to `windowBackgroundColor@95%`.
- `HUDBannerPanel` is a *separate* `.floating` panel (UI-SPEC Surface 5 "Critical decision") — `canBecomeKey=false` + `canBecomeMain=false` so it never steals keyboard focus, positioned 24pt from right edge / 8pt below system menu bar on the main display.
- `HUDBannerCoordinator` owns a priority queue with pre-emption, 300ms gap between banners on drain, and a `dismissedThisLaunch: Set<String>` that prevents re-enqueue of manually-dismissed banners until app restart.
- `BannerContent` presets wired at priorities 1-4: **keychain-empty (1) > input-monitoring-denied (2) > hotkey-bind-failed (3) > ollama-url-rejected (4)**; each carries title, body, and optional Action (label + URL) per UI-SPEC Surface 5 copywriting table.
- `AppDelegate` hard-blocks on missing `JarvisEntitlementsVerified` Info.plist key via an `EntitlementGateProbe` protocol (production `InfoPlistEntitlementGateProbe` + mock-injectable for tests). Critical NSAlert with Quit / Show Details buttons; Show Details opens `~/Library/Logs/Jarvis/system.log` in Console.app.
- `AppDelegate.applicationWillFinishLaunching` installs menu-bar + HUD panel + banner panel (when verified). Plan 04 prepends logging bootstrap and appends config / Keychain / hotkey wiring.
- 13 XCTest cases across 4 test classes in a new `JarvisAppTests` unit-test bundle target — Swift 6 strict concurrency clean. Tests exercise: HudState VoiceOver labels, menu-bar state transitions + accessibility label updates + same-state no-op + context menu structure, HUD panel style flags + summon/dismiss + Escape dismissal, banner enqueue + priority pre-emption + dismiss-drain + dismissed-this-launch dedup, AppDelegate hard-block triggers on false probe + does-not-trigger on true probe.

## Task Commits

1. **Task 1:** HudState + BrandColors + CAAnimationFactory + menu-bar template PDF + Contents.json update — `c19d6b2` (feat)
2. **Task 2:** MenuBarIconController + MenuBarContextMenu + JarvisAppTests target (project.yml + pbxproj) + MenuBarIconControllerTests — `f8da4b7` (feat)
3. **Task 3:** BannerContent + HUDBanner + HUDBannerPanel + HUDBannerCoordinator + JarvisHUDPanel + AppDelegate entitlement gate + 3 new test files — `122153d` (feat)

_No separate test/refactor commits — plan marked tasks as `tdd="true"` but the action blocks folded test files into the same commit as the production code (the tests exercise pure-logic surfaces, not RED-before-GREEN protocol fixtures)._

## Menu-Bar state→animation mapping

```swift
switch newState {
case .idle:
    break  // static, no animation
case .listening:
    if let a = CAAnimationFactory.makeBreath()  { layer.add(a, forKey: "state.breath")   }  // scale 1.0↔1.04, 0.625s autoreverse
case .thinking:
    if let a = CAAnimationFactory.makeRotate()  { layer.add(a, forKey: "state.rotate")   }  // rotation.z 0→2π, 1.5s linear
case .speaking:
    if let a = CAAnimationFactory.makeShimmer() { layer.add(a, forKey: "state.shimmer")  }  // opacity [1.0, 0.65, 1.0] keyframe, 0.9s
case .awaitingConfirmation:
    if let a = CAAnimationFactory.makeGlow()    { layer.add(a, forKey: "state.glow")     }  // opacity 1.0↔0.55, 0.5s autoreverse (1Hz)
}
```

Every helper returns `nil` when `NSWorkspace.shared.accessibilityDisplayShouldReduceMotion == true`. A `CAAnimationFactory.makeStateCrossfade()` (150ms fade, UI-SPEC Surface 3 transition) is added to the layer on every transition, regardless of Reduce Motion.

## HUD panel style flags (JarvisHUDPanel)

```swift
super.init(
    contentRect: NSRect(origin: .zero, size: NSSize(width: 720, height: 720)),
    styleMask: [.borderless, .nonactivatingPanel],
    backing: .buffered,
    defer: false
)
self.level = .statusBar
self.isMovableByWindowBackground = true
self.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
self.hasShadow = false
self.backgroundColor = .clear
self.isOpaque = false
self.titleVisibility = .hidden
self.hidesOnDeactivate = false
// WKWebView:
self.webView.underPageBackgroundColor = .clear
self.webView.setValue(false, forKey: "drawsBackground") // macOS 26 private-key force
```

Reduce Transparency fallback applied at `init`:

```swift
if NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency {
    self.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.95)
}
```

## Banner priority order + preset IDs

| Priority | ID | Title | Trigger (Plan 04 wires) |
|---------:|----|-------|-------------------------|
| 1 | `keychain-empty` | "No API key configured" | Keychain fetch on `.anthropic` returns `.itemNotFound` at launch |
| 2 | `input-monitoring-denied` | "Limited hotkey mode" | `IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)` returns `false` |
| 3 | `hotkey-bind-failed` | "Hotkey unavailable" | `HotkeyBinder.bind(...)` throws `.alreadyClaimed` |
| 4 | `ollama-url-rejected` | "Ollama config rejected" | `OllamaConfig` decoder throws `ConfigError.invalidOllamaHost` |

Coordinator semantics:
- **Enqueue while idle:** show immediately.
- **Enqueue while another banner visible AND incoming priority < visible priority:** pre-empt (visible goes back into queue sorted by priority).
- **Enqueue while another banner visible AND incoming priority ≥ visible priority:** insert into queue sorted ascending.
- **`dismissCurrent()`:** remember `id` in `dismissedThisLaunch` set; pop next from queue after 300ms.
- **Re-enqueue same `id` after dismiss:** no-op until app restart.

## AppDelegate hard-block flow

```
applicationWillFinishLaunching(_:)
 └─ entitlementProbe.isVerified()  (reads Bundle.main Info.plist JarvisEntitlementsVerified)
     ├── true  → installMenuBar() → installHUDPanel() → installBannerPanel()   (skipped when XCTest host)
     └── false → onEntitlementFailure()
                   └── defaultOnEntitlementFailure()
                          ├── isRunningAsTestHost? → return   (no-op under XCTest)
                          └── otherwise → presentEntitlementFailureAlert()    (NSAlert .critical)
                                          └── NSApp.terminate(nil)
```

Test-injectable seams:
- `entitlementProbe: EntitlementGateProbe` (default `InfoPlistEntitlementGateProbe`) — tests inject a `MockProbe` returning false to drive the gate.
- `onEntitlementFailure: @MainActor () -> Void` (default `AppDelegate.defaultOnEntitlementFailure`) — tests inject a closure that sets `failureCalled = true` instead of running the alert+terminate path.

## Test Count

| File | Tests | Coverage |
|------|-------|----------|
| `MenuBarIconControllerTests.swift` | 4 | state transition updates accessibility label, same-state is no-op, context menu items + Settings…-disabled, HudState VoiceOver labels verbatim |
| `JarvisHUDPanelTests.swift` | 3 | panel style + level + collectionBehavior + isOpaque + hidesOnDeactivate flags, summon/dismiss toggle `isSummoned`, Escape via `cancelOperation(nil)` dismisses |
| `HUDBannerCoordinatorTests.swift` | 4 | enqueue-while-idle shows immediately, higher-priority pre-empts, `dismissCurrent` drains queue after 0.3s async gap, dismissed-this-launch blocks re-enqueue |
| `AppDelegateEntitlementTests.swift` | 2 | `applicationWillFinishLaunching` fires `onEntitlementFailure` when probe returns false; does NOT fire when probe returns true |

**Total: 13 tests passing, 0 failures. Swift 6 strict concurrency clean.**

## Wiring Open Items for Plan 04

Plan 04 owns the closure wiring on these seams — the API shape is locked here:

| Seam | Current state | Plan 04 action |
|------|---------------|----------------|
| `MenuBarContextMenu.setupAction` | empty closure `{}` | open `OnboardingWizardController.open(atFirstUnresolved:)` |
| `MenuBarContextMenu.devOverlayToggleAction` | empty closure `{}` | enqueue `BannerContent(id: "dev-overlay-p4", …, body: "Dev Overlay lands in Phase 4.")` |
| `MenuBarContextMenu.stateDumpAction` | empty closure `{}` | `NSPasteboard.general.setString(stateDumpJSON, forType: .string)` + enqueue brief "State dump copied to clipboard." banner |
| `HUDBannerCoordinator.enqueue(.keychainEmpty)` call site | unwired | call from AppDelegate bootstrap after `Keychain.fetch(.anthropic)` returns `.itemNotFound` |
| `HUDBannerCoordinator.enqueue(.inputMonitoringDenied)` call site | unwired | call from `HotkeyBinder` after `IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)` returns `false` |
| `HUDBannerCoordinator.enqueue(.hotkeyBindFailed)` call site | unwired | call from `HotkeyBinder.bind(...)` catch block |
| `HUDBannerCoordinator.enqueue(.ollamaURLRejected)` call site | unwired | call from `ConfigLoader.loadSnapshots` catch block on `ConfigError.invalidOllamaHost` |
| Banner action button handlers — `Open Setup` / `Rebind` / `Reveal config` | URL path opens via `NSWorkspace.shared.open`; non-URL actions are no-op after `dismissCurrent` | wire to `OnboardingWizardController`, `HotkeyBinder.rebind()`, `NSWorkspace.shared.activateFileViewerSelecting` for config path |
| `AppDelegate.toggleHUD` hotkey trigger | wired only to left-click | add `HotkeyBinder.onTrigger = { [weak self] in self?.toggleHUD() }` in bootstrap |
| Logging bootstrap call-site | absent (comment marker "Plan 04 prepends") | `JarvisLogHandlerFactory.bootstrap()` as first line of `applicationWillFinishLaunching` |
| Config / Keychain loads | absent (comment marker "Plan 04 appends") | `ConfigLoader.loadSnapshots()` + `Keychain.fetch(.anthropic)` after panel install |

## Decisions Made

- **XCTest host-skip logic in AppDelegate.** The host app launches before the XCTest bundle loads; if `applicationWillFinishLaunching` runs the production gate it reads `JarvisEntitlementsVerified=false` from the unsigned Debug Info.plist, calls `NSApp.terminate`, and the test runner dies with "Early unexpected exit, operation never finished bootstrapping." Fix: `AppDelegate.isRunningAsTestHost` checks `XCTestConfigurationFilePath` env var; `defaultOnEntitlementFailure` returns early when true, and the install-chain skips AppKit surface creation when true. Tests still exercise the gate directly via injected mocks so the failure path is still covered. This is inline with common Apple test-host patterns but is worth calling out because the plan's code didn't anticipate it (see Deviations §1).
- **WKWebView.isOpaque removed.** Swift bridges `NSView.isOpaque` as get-only on `WKWebView`. The plan's code `self.webView.isOpaque = false` is a compile error. Transparency still works via `drawsBackground=false` (KVO) + `underPageBackgroundColor = .clear` + the parent panel's `isOpaque=false`+`backgroundColor=.clear`.
- **onEntitlementFailure type annotated `@MainActor () -> Void`.** Swift 6 strict concurrency rejects the implicit conversion of a `@MainActor`-isolated static function reference to a plain `() -> Void`. Explicit annotation is required.
- **PBXCopyFilesBuildPhase is manually re-applied after each `xcodegen generate`.** xcodegen silently drops empty `copyFiles:` blocks. Plan 01 SUMMARY documented this maintenance cost; this plan re-applied the patch 3 times (once after adding the test target, once after adding Task 2 sources, once after adding Task 3 sources).

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 1 - Bug] WKWebView.isOpaque is get-only in Swift — removed assignment**
- **Found during:** Task 3 (JarvisHUDPanel compile)
- **Issue:** The plan's action block wrote `self.webView.isOpaque = false`, but `WKWebView.isOpaque` (inherited from `NSView`) is bridged into Swift as a read-only property. Build failed with `error: cannot assign to property: 'isOpaque' is a get-only property`.
- **Fix:** Removed the assignment. Transparency is still achieved via `self.webView.underPageBackgroundColor = .clear` and `self.webView.setValue(false, forKey: "drawsBackground")` (KVO on the Objective-C `drawsBackground` property) plus the parent panel's `isOpaque=false` + `backgroundColor=.clear`.
- **Files modified:** `App/HUD/JarvisHUDPanel.swift`
- **Verification:** Build succeeds; JarvisHUDPanel still renders with a transparent backing in manual smoke test (panel summoned via `panel.summon()` shows the empty webview without opaque white background).
- **Committed in:** `122153d` (Task 3 commit)

**2. [Rule 1 - Bug] AppDelegate host-skip: XCTest runner killed by production gate**
- **Found during:** Task 3 (running JarvisHUDPanelTests + HUDBannerCoordinatorTests + AppDelegateEntitlementTests)
- **Issue:** The host Jarvis.app is launched before the test bundle loads. `applicationWillFinishLaunching` fires with the real `InfoPlistEntitlementGateProbe` which reads `JarvisEntitlementsVerified=false` (Plan 01 scaffold default; Plan 05 flips it to true at codesign). The default `onEntitlementFailure` called `NSApp.terminate(nil)` → host process dies before the test bundle can load → `Testing failed: Jarvis encountered an error (Early unexpected exit, operation never finished bootstrapping)`. The plan's tests inject their own `onEntitlementFailure`, but that doesn't help because it's the host app's *own* delegate that terminates before the test code runs.
- **Fix:** Introduced `AppDelegate.isRunningAsTestHost` (checks `ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil`) and `AppDelegate.defaultOnEntitlementFailure` (no-op under XCTest, production NSAlert+terminate otherwise). The install chain in `applicationWillFinishLaunching` also skips AppKit surface creation under XCTest so we don't leak status items. The test-injection seams (`entitlementProbe` + `onEntitlementFailure`) remain the primary way to test the gate; the XCTest guard is purely for host-app survival.
- **Files modified:** `App/AppDelegate.swift`
- **Verification:** All 13 JarvisAppTests pass; `AppDelegateEntitlementTests.test_hardBlockTriggersOnMissingVerification` still exercises the failure path by injecting its own closure (the injected closure bypasses `defaultOnEntitlementFailure` entirely).
- **Committed in:** `122153d` (Task 3 commit)

**3. [Rule 1 - Bug] `onEntitlementFailure` closure type needs explicit `@MainActor` annotation under Swift 6**
- **Found during:** Task 3 (AppDelegate compile after deviation #2 fix)
- **Issue:** Swift 6 strict concurrency rejected the implicit conversion of `AppDelegate.defaultOnEntitlementFailure` (a `@MainActor @Sendable () -> ()` function value) to the declared property type `() -> Void`. Error: `converting function value of type '@MainActor @Sendable () -> ()' to '() -> Void' loses global actor 'MainActor'`.
- **Fix:** Annotated the property type: `var onEntitlementFailure: @MainActor () -> Void = AppDelegate.defaultOnEntitlementFailure`.
- **Files modified:** `App/AppDelegate.swift`
- **Verification:** Build succeeds; all 13 JarvisAppTests pass; test-injected closures still work (tests pass a plain `() -> Void` which promotes to `@MainActor () -> Void` because the test class is `@MainActor`).
- **Committed in:** `122153d` (Task 3 commit)

**4. [Rule 3 - Blocking] PBXCopyFilesBuildPhase re-applied after every xcodegen regeneration**
- **Found during:** Task 2 + Task 3 (after each `xcodegen generate` that picked up new sources)
- **Issue:** xcodegen silently drops empty `copyFiles: files: []` blocks despite project.yml declaring them. The result: the `PBXCopyFilesBuildPhase` with `dstPath=Contents/Helpers` vanishes from the pbxproj. Plan 01's MCP-05 acceptance criterion requires this phase be present (it registers the codesign destination for Plan 05's deepest-first walk) and Plan 01 SUMMARY explicitly calls this out as manual maintenance.
- **Fix:** After each regeneration, manually re-insert the `PBXCopyFilesBuildPhase` section (id `9A5E7F3F1A2B3C4D5E6F7081`) and add its reference into the Jarvis target's `buildPhases` list. Done 3 times in this plan.
- **Files modified:** `Jarvis.xcodeproj/project.pbxproj` (3 times; final state committed in each task commit)
- **Verification:** `grep -c 'PBXCopyFilesBuildPhase' Jarvis.xcodeproj/project.pbxproj` returns 3 (section begin + section end + references) after each regen; `test -d build/Build/Products/Debug/Jarvis.app/Contents/Helpers` returns 0 after each subsequent rebuild.
- **Committed in:** `f8da4b7`, `122153d` (the phase survived across both regeneration rounds)

---

**Total deviations:** 4 auto-fixed (3 Rule 1 bugs in plan spec code, 1 Rule 3 blocking — xcodegen maintenance)
**Impact on plan:** All four are corrections to plan-provided spec code or scaffold maintenance. None change the plan's scope, surfaces, or interfaces. Task 3's AppDelegate tests would have been un-runnable without deviations 1-3; the PBXCopyFilesBuildPhase re-application is a documented Plan 01 maintenance cost.

## Issues Encountered

- **xcodegen strips empty `copyFiles` blocks** — addressed via Deviation §4. A future plan could switch the pbxproj to hand-rolled (drop `project.yml`) if the maintenance becomes painful, but for now the regeneration is cheap and project.yml stays the source of truth for everything except the Helpers phase.
- **JarvisHUDPanel content-view side-effect warning noise during tests** — `Unhandled disconnected scene <NSStatusItemScene ...>` and similar messages appear after `MenuBarIconControllerTests` completes. These are cosmetic macOS status-item teardown chatter (the status item is removed via `defer { NSStatusBar.system.removeStatusItem(item) }` before the test exits); they do not indicate a leak or failure.

## User Setup Required

None — no external service configuration required for this plan. The Plan 01 open item (App ID capability on developer.apple.com) remains the only pending human step before `/gsd-verify-phase 1` closes, and this plan does not alter that pending status.

## Next Phase Readiness

- **Plan 04 (`shell-wizard-wiring`) is unblocked.** All interfaces this plan declared are in place: `HudState`, `MenuBarIconController` + `setLeftClickAction`, `JarvisHUDPanel` + `summon`/`dismiss`/`isSummoned`, `HUDBannerCoordinator` + `enqueue`/`dismissCurrent`/`clear`, `BannerContent` presets, `MenuBarContextMenu.build(setupAction:devOverlayToggleAction:stateDumpAction:)`, and the AppDelegate bootstrap chain with marked prepend/append slots for logging/config/keychain/hotkey.
- **Plan 05 (`codesign-entitlement-probe`) has a breadcrumb.** `JarvisEntitlementsVerified` is read in `AppDelegate.applicationWillFinishLaunching`; Plan 05's `verify-entitlements.sh --pre-codesign` must flip this key to true before codesign runs, and the Plan 01 breadcrumb (removing Debug `CODE_SIGNING_ALLOWED=NO`) remains pending.
- **Phase 3 HUD is unblocked for panel host.** `JarvisHUDPanel.webView` is a fully-configured transparent `WKWebView`; P3 just needs to call `webView.loadFileURL` with the Vite-built R3F bundle.
- **Manual smoke test (not automated):** Launching the Debug .app directly from the build artifacts exits immediately because `JarvisEntitlementsVerified=false` triggers the NSAlert. This is **expected** — Plan 05 flips the key. To smoke-test the full menu-bar + HUD install chain now, temporarily edit Info.plist to `<true/>` locally (do not commit), run `xcodebuild build`, open the `.app`, observe the status-item icon appear with placeholder arc-reactor silhouette, left-click → transparent 720×720 panel centers on active display, Escape → dismisses. Right-click → context menu with all 5 items, "Settings…" disabled. Revert Info.plist.

## Known Stubs

- `MenuBarContextMenu.build(setupAction:devOverlayToggleAction:stateDumpAction:)` — all three closures are empty `{}` at the AppDelegate installer call site. Plan 04 wires them. Stub is intentional per plan's `<interfaces>` section (closures "wired by Plan 04").
- `HUDBannerCoordinator` is installed but never enqueued with anything. Plan 04 wires the four enqueue call-sites (Keychain empty, Input Monitoring denied, hotkey bind fail, Ollama URL rejected). Stub is intentional — the coordinator surface is tested via direct `enqueue(_:)` calls in XCTest.
- `JarvisHUDPanel.webView` loads no content. Phase 3 loads the R3F bundle via `loadFileURL`. Stub is intentional per UI-SPEC Surface 7 line 538 "P1 does not render R3F content."
- Banner action buttons for "Open Setup" / "Rebind" / "Reveal config" — URL-based actions open via `NSWorkspace.shared.open` (works for Input Monitoring's System Settings deep-link); the label-only actions are no-op after `dismissCurrent`. Plan 04 wires them to wizard / hotkey rebinder / Finder reveal.
- `App/Assets.xcassets/Icon-MenuBar-Template.imageset/Icon-MenuBar-Template.pdf` is a *placeholder* arc-reactor silhouette (concentric circles + 6 radial spokes). UI-SPEC Open Items §1 explicitly accepts this placeholder; final design-pass art lands post-P1.
- `App/Assets.xcassets/AppIcon.appiconset/` — empty slots (Plan 01 scaffold). Real app icon art lands post-P1 per UI-SPEC Open Items §2.

None of these stubs prevent Plan 01-03's goal (static menu-bar + HUD skeleton rendering with test-proven state machines and entitlement gate).

## Self-Check: PASSED

Verified:
- `App/Theme/HudState.swift` — FOUND (5 cases, verbatim VoiceOver labels)
- `App/Theme/BrandColors.swift` — FOUND (arcReactorGlow with light/dark/increase-contrast branches)
- `App/MenuBar/CAAnimationFactory.swift` — FOUND (5 helpers, all Reduce Motion guarded)
- `App/MenuBar/MenuBarIconController.swift` — FOUND (@MainActor, anchorPoint re-anchor, 5-state machine)
- `App/MenuBar/MenuBarContextMenu.swift` — FOUND (5 items, Settings… disabled, ⌘Q on Quit)
- `App/HUD/JarvisHUDPanel.swift` — FOUND (.borderless + .nonactivatingPanel, .statusBar level, transparent WKWebView, cancelOperation override)
- `App/HUD/HUDBannerPanel.swift` — FOUND (.floating, canBecomeKey=false)
- `App/HUD/HUDBannerCoordinator.swift` — FOUND (priority queue, pre-emption, dismissed-this-launch dedup)
- `App/HUD/BannerContent.swift` — FOUND (4 preset banners, priorities 1-4)
- `App/HUD/HUDBanner.swift` — FOUND (SwiftUI view with accent stripe + visual-effect background)
- `App/Assets.xcassets/Icon-MenuBar-Template.imageset/Icon-MenuBar-Template.pdf` — FOUND (2368 bytes, PDF 1.3)
- `App/AppDelegate.swift` — FOUND (EntitlementGateProbe protocol, install chain, entitlement failure alert static)
- `App/Tests/AppTests/MenuBarIconControllerTests.swift` — FOUND (4 tests)
- `App/Tests/AppTests/JarvisHUDPanelTests.swift` — FOUND (3 tests)
- `App/Tests/AppTests/HUDBannerCoordinatorTests.swift` — FOUND (4 tests)
- `App/Tests/AppTests/AppDelegateEntitlementTests.swift` — FOUND (2 tests)
- `Jarvis.xcodeproj/xcshareddata/xcschemes/Jarvis.xcscheme` — FOUND (wires test action against JarvisAppTests)
- Commit `c19d6b2` (Task 1) — FOUND in git log
- Commit `f8da4b7` (Task 2) — FOUND in git log
- Commit `122153d` (Task 3) — FOUND in git log
- `xcodebuild -project Jarvis.xcodeproj -scheme Jarvis -configuration Debug build` exits 0
- `xcodebuild test -project Jarvis.xcodeproj -scheme Jarvis` runs 13 tests, all pass
- `PBXCopyFilesBuildPhase` present in pbxproj (Plan 01 invariant preserved)
- `test -d build/Build/Products/Debug/Jarvis.app/Contents/Helpers` returns 0 (post-rebuild)
- No `import Keychain` / `import Config` / `import JarvisLogging` in `App/` (Plan 02 territory respected)

---
*Phase: 01-foundations*
*Plan: 03 (app-shell-ui)*
*Completed: 2026-04-22*
