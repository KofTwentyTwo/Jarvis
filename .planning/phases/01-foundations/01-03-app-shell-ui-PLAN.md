---
phase: 01-foundations
plan: 03
type: execute
wave: 2
depends_on: [01]
files_modified:
  - App/AppDelegate.swift
  - App/MenuBar/MenuBarIconController.swift
  - App/MenuBar/MenuBarContextMenu.swift
  - App/MenuBar/CAAnimationFactory.swift
  - App/HUD/JarvisHUDPanel.swift
  - App/HUD/HUDBannerPanel.swift
  - App/HUD/HUDBannerCoordinator.swift
  - App/HUD/HUDBanner.swift
  - App/HUD/BannerContent.swift
  - App/Theme/BrandColors.swift
  - App/Theme/HudState.swift
  - App/Assets.xcassets/Icon-MenuBar-Template.imageset/Icon-MenuBar-Template.pdf
  - App/Assets.xcassets/AppIcon.appiconset/Contents.json
autonomous: true
requirements: [SHELL-01, SHELL-03, SHELL-04]
must_haves:
  truths:
    - "NSStatusItem installed in the menu bar on app launch with a template PDF icon (arc-reactor silhouette or placeholder concentric circles)"
    - "Menu-bar icon animates via Core Animation on layer transform/opacity (not layer.contents replacement) across five states: idle, listening, thinking, speaking, awaitingConfirmation"
    - "Left-click on menu-bar icon invokes toggleHUD:; right-click / Ctrl+click shows NSMenu with Setup… / Settings… (disabled stub) / Show Dev Overlay / Copy State Dump / Quit (⌘Q)"
    - "JarvisHUDPanel is a borderless transparent NSPanel, 720×720, level=.statusBar, collectionBehavior=[.canJoinAllSpaces, .fullScreenAuxiliary, .transient], summons/dismisses via summon()/dismiss(), Escape key dismisses"
    - "HUDBannerPanel is a separate floating panel distinct from the main HUD (UI-SPEC Surface 5 decision) — 360pt wide, top-trailing corner, level=.floating, hosts a SwiftUI HUDBanner view"
    - "AppDelegate.applicationWillFinishLaunching reads JarvisEntitlementsVerified from Info.plist and presents a critical NSAlert + terminates if the flag is false/missing"
    - "Reduce Motion, Reduce Transparency, and Increase Contrast accessibility fallbacks are honored per UI-SPEC Surface 3 and 7"
  artifacts:
    - path: "App/AppDelegate.swift"
      provides: "Entitlement hard-block at applicationWillFinishLaunching + menu-bar + HUD panel installation"
      contains: "JarvisEntitlementsVerified"
    - path: "App/MenuBar/MenuBarIconController.swift"
      provides: "@MainActor NSStatusItem controller with CABasicAnimation state machine"
      contains: "NSStatusItem"
    - path: "App/HUD/JarvisHUDPanel.swift"
      provides: "Borderless transparent always-on-top NSPanel"
      contains: ".nonactivatingPanel"
    - path: "App/HUD/HUDBannerPanel.swift"
      provides: "Floating banner panel — separate from HUD main"
      contains: ".floating"
    - path: "App/Theme/BrandColors.swift"
      provides: "arcReactorGlow with light/dark + Increase Contrast fallback"
      contains: "arcReactorGlow"
  key_links:
    - from: "App/AppDelegate.swift"
      to: "Info.plist JarvisEntitlementsVerified"
      via: "Bundle.main.object(forInfoDictionaryKey:)"
      pattern: "JarvisEntitlementsVerified"
    - from: "App/MenuBar/MenuBarIconController.swift"
      to: "App/Assets.xcassets/Icon-MenuBar-Template.imageset"
      via: "NSImage(named: \"Icon-MenuBar-Template\") with isTemplate=true"
      pattern: "Icon-MenuBar-Template"
    - from: "App/HUD/JarvisHUDPanel.swift"
      to: "WKWebView (empty in P1; P3 loads R3F bundle)"
      via: "content view installs WKWebView edge-to-edge"
      pattern: "WKWebView"
---

<objective>
Build the App target's AppKit surfaces: the `NSStatusItem` menu-bar item with Core Animation state-machine, the borderless transparent `NSPanel` HUD skeleton (empty WKWebView inside — P3 loads R3F), the separate `HUDBannerPanel` for degraded-mode banners (Input Monitoring denied, Keychain empty, hotkey-bind failure, Ollama URL rejected — per UI-SPEC Surface 5), the brand theme, the asset catalog contents, and the `AppDelegate` entitlement hard-block per RESEARCH §Pattern 1. This plan runs in parallel with Plan 02 because it touches only `App/*` files and does not import the `Keychain`, `Config`, or `JarvisLogging` packages — their wiring lands in Plan 04 (Wizard + Shell package + full AppDelegate wire-up).

Purpose: Get the static menu-bar + HUD skeleton rendering before wizard/hotkey/config logic arrives. The UI-SPEC design contract (Surfaces 3, 4, 5, 6, 7) is normative; this plan implements it.

Output: An App target that shows a menu-bar icon on launch, opens a transparent floating panel on left-click (no hotkey yet — Plan 04), presents the right-click context menu, and hard-blocks with an NSAlert if the build hasn't been entitlement-verified.
</objective>

<execution_context>
@~/.claude/get-shit-done/workflows/execute-plan.md
@~/.claude/get-shit-done/templates/summary.md
</execution_context>

<context>
@CLAUDE.md
@.planning/PROJECT.md
@.planning/phases/01-foundations/01-CONTEXT.md
@.planning/phases/01-foundations/01-UI-SPEC.md
@.planning/phases/01-foundations/01-RESEARCH.md
@.planning/phases/01-foundations/01-PATTERNS.md
@.planning/phases/01-01-SUMMARY.md

<interfaces>
<!-- Contracts this plan establishes for downstream plans (04 wires them together) -->

HudState enum (used by menu-bar animation + future voice/agent states):
```swift
public enum HudState: String, Sendable, CaseIterable {
    case idle, listening, thinking, speaking, awaitingConfirmation
    public var voiceOverLabel: String { ... }
}
```

MenuBarIconController public API (installed by AppDelegate in Plan 04):
```swift
@MainActor
public final class MenuBarIconController {
    public init(statusItem: NSStatusItem, contextMenu: NSMenu)
    public func transition(to state: HudState)
    public func setAction(_ leftClick: @escaping () -> Void)  // wired by Plan 04
}
```

JarvisHUDPanel public API (installed by AppDelegate):
```swift
@MainActor
public final class JarvisHUDPanel: NSPanel {
    public func summon(on screen: NSScreen?)
    public func dismiss()
    public var isSummoned: Bool { get }
}
```

HUDBannerCoordinator public API (the enqueue() call sites wire in Plan 04 for Input Monitoring denial, etc.):
```swift
@MainActor
public final class HUDBannerCoordinator {
    public init(panel: HUDBannerPanel)
    public func enqueue(_ content: BannerContent)
    public func dismissCurrent()
    public func clear()
}

public struct BannerContent: Sendable, Equatable {
    public let id: String           // priority key for de-dup
    public let priority: Int        // lower = higher priority
    public let title: String
    public let body: String
    public let action: Action?
    public struct Action: Sendable, Equatable {
        public let label: String
        public let url: URL?        // deep link (e.g., System Settings)
    }
}
```

Predefined banner priorities (from UI-SPEC Surface 5):
1. keychain-empty (highest)
2. input-monitoring-denied
3. hotkey-bind-failed
4. ollama-url-rejected

PATTERNS cross-refs:
- S-2 `@MainActor` on every AppKit-touching service
- S-6 Hard-block on safety failures (AppDelegate entitlement check)
- S-7 Reduce Motion / Reduce Transparency / Increase Contrast fallbacks
</interfaces>
</context>

<tasks>

<task type="auto" tdd="true">
  <name>Task 1: Build HudState, BrandColors, CAAnimationFactory, AppIcon placeholder, menu-bar template PDF placeholder</name>
  <files>App/Theme/HudState.swift, App/Theme/BrandColors.swift, App/MenuBar/CAAnimationFactory.swift, App/Assets.xcassets/Icon-MenuBar-Template.imageset/Icon-MenuBar-Template.pdf, App/Assets.xcassets/Icon-MenuBar-Template.imageset/Contents.json, App/Assets.xcassets/AppIcon.appiconset/Contents.json</files>
  <behavior>
    - `HudState.idle.voiceOverLabel == "Jarvis, idle"` (and likewise for the other four states per UI-SPEC Surface 3 lines 413-417)
    - `BrandColors.arcReactorGlow` returns an `NSColor` that falls back to `NSColor.controlAccentColor` when `NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast == true`
    - `CAAnimationFactory.makeBreath()` returns a `CABasicAnimation` on `"transform.scale"` with `autoreverses = true`, `repeatCount = .infinity`, `duration = 0.625` (UI-SPEC Surface 3 Listening state)
    - `CAAnimationFactory.makeRotate()` returns a `CABasicAnimation` on `"transform.rotation.z"` with `duration = 1.5`
    - `CAAnimationFactory.makeBreath()` returns nil or a static-fallback helper when `shouldReduceMotion == true` (UI-SPEC Reduce Motion fallback line 400)
  </behavior>
  <read_first>
    - App/Assets.xcassets/Icon-MenuBar-Template.imageset/Contents.json (from Plan 01 — confirm `"template-rendering-intent": "template"` present)
    - App/Assets.xcassets/AppIcon.appiconset/Contents.json (from Plan 01)
    - .planning/phases/01-foundations/01-UI-SPEC.md §Color lines 94-113 (BrandColors spec: #1E88E5@85% light, #64B5F6@90% dark, controlAccentColor fallback on Increase Contrast)
    - .planning/phases/01-foundations/01-UI-SPEC.md §Surface 3 lines 385-404 (state → animation mapping + Reduce Motion fallbacks)
    - .planning/phases/01-foundations/01-RESEARCH.md §Question 7 lines 818-858 (CABasicAnimation helpers verbatim: makeBreath, makeRotate, makeShimmer, makeGlow)
    - .planning/phases/01-foundations/01-PATTERNS.md §F lines 77-82 (asset catalog + BrandColors) and §C line 52 (CAAnimationFactory contract)
    - .planning/phases/01-foundations/01-CONTEXT.md D-14 (state→animation mapping) and D-15 (awaitingConfirmation is attention-grabbing but not alarming)
  </read_first>
  <action>
    **Create `App/Theme/HudState.swift`:**
    ```swift
    import Foundation

    public enum HudState: String, Sendable, CaseIterable, Equatable {
        case idle
        case listening
        case thinking
        case speaking
        case awaitingConfirmation

        public var voiceOverLabel: String {
            switch self {
            case .idle: return "Jarvis, idle"
            case .listening: return "Jarvis, listening"
            case .thinking: return "Jarvis, thinking"
            case .speaking: return "Jarvis, speaking"
            case .awaitingConfirmation: return "Jarvis, waiting for your confirmation"
            }
        }
    }
    ```

    **Create `App/Theme/BrandColors.swift`** per UI-SPEC §Color Custom brand tokens:
    ```swift
    import AppKit

    public enum BrandColor {
        /// Arc-reactor glow — used only for the HUD banner leading-edge accent stripe.
        /// Light mode: #1E88E5 at 85% opacity
        /// Dark mode: #64B5F6 at 90% opacity
        /// Falls back to NSColor.controlAccentColor under Increase Contrast.
        public static var arcReactorGlow: NSColor {
            if NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast {
                return NSColor.controlAccentColor
            }
            return NSColor(name: nil, dynamicProvider: { appearance in
                let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                if isDark {
                    return NSColor(red: 0x64/255.0, green: 0xB5/255.0, blue: 0xF6/255.0, alpha: 0.90)
                } else {
                    return NSColor(red: 0x1E/255.0, green: 0x88/255.0, blue: 0xE5/255.0, alpha: 0.85)
                }
            })
        }
    }
    ```

    **Create `App/MenuBar/CAAnimationFactory.swift`** — verbatim helpers from RESEARCH Q7 with Reduce Motion guards per UI-SPEC Surface 3 fallbacks:
    ```swift
    import AppKit
    import QuartzCore

    @MainActor
    public enum CAAnimationFactory {
        /// Listening: breathing pulse ~0.8 Hz, scale 1.0 ↔ 1.04, sine ease.
        public static func makeBreath() -> CABasicAnimation? {
            if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion { return nil }
            let a = CABasicAnimation(keyPath: "transform.scale")
            a.fromValue = 1.0
            a.toValue = 1.04
            a.duration = 0.625
            a.autoreverses = true
            a.repeatCount = .infinity
            a.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            return a
        }

        /// Thinking: inner-ring rotation, 1.5 s period, linear.
        public static func makeRotate() -> CABasicAnimation? {
            if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion { return nil }
            let a = CABasicAnimation(keyPath: "transform.rotation.z")
            a.fromValue = 0
            a.toValue = 2 * CGFloat.pi
            a.duration = 1.5
            a.repeatCount = .infinity
            a.timingFunction = CAMediaTimingFunction(name: .linear)
            return a
        }

        /// Speaking: opacity shimmer, 900ms period, ease-in-out.
        public static func makeShimmer() -> CAKeyframeAnimation? {
            if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion { return nil }
            let a = CAKeyframeAnimation(keyPath: "opacity")
            a.values = [1.0, 0.65, 1.0]
            a.keyTimes = [0.0, 0.5, 1.0]
            a.duration = 0.9
            a.repeatCount = .infinity
            return a
        }

        /// AwaitingConfirmation: opacity glow, 1 Hz, ease-in-out, higher amplitude than breath.
        public static func makeGlow() -> CABasicAnimation? {
            if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion { return nil }
            let a = CABasicAnimation(keyPath: "opacity")
            a.fromValue = 1.0
            a.toValue = 0.55
            a.duration = 0.5
            a.autoreverses = true
            a.repeatCount = .infinity
            a.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            return a
        }

        /// 150ms crossfade between state animations (UI-SPEC Surface 3 transition spec).
        public static func makeStateCrossfade() -> CATransition {
            let t = CATransition()
            t.type = .fade
            t.duration = 0.15
            return t
        }
    }
    ```

    **Create menu-bar template icon (placeholder)** — UI-SPEC Open Items §1 accepts a placeholder concentric-circle silhouette if final art isn't ready. Hand-author a 22×22pt PDF with:
    - Outer ring: 1pt stroke circle, diameter 18pt
    - Mid ring: 0.75pt stroke circle, diameter 12pt
    - Inner core: 0.5pt stroke circle, diameter 4pt, FILLED at 100%
    - Six radial spokes, 0.5pt stroke, at 60° intervals
    - Pure black on transparent; template-rendering-intent
    - File: `App/Assets.xcassets/Icon-MenuBar-Template.imageset/Icon-MenuBar-Template.pdf`

    Tool suggestion: use `librsvg` or `rsvg-convert` to generate from an SVG spec if available, or a pre-built PDF drop-in placeholder. Acceptable to use a simpler 3-concentric-circles placeholder if a full 6-spoke asset requires a design pass.

    **Verify/update** `App/Assets.xcassets/Icon-MenuBar-Template.imageset/Contents.json` to contain:
    ```json
    {
      "images": [
        {
          "filename": "Icon-MenuBar-Template.pdf",
          "idiom": "universal"
        }
      ],
      "info": {
        "author": "xcode",
        "version": 1
      },
      "properties": {
        "template-rendering-intent": "template",
        "preserves-vector-representation": true
      }
    }
    ```

    **App/Assets.xcassets/AppIcon.appiconset/Contents.json** — ship the Contents.json with all required slots (16pt 1x/2x, 32pt 1x/2x, 128pt 1x/2x, 256pt 1x/2x, 512pt 1x/2x) but with `"filename"` missing from each (placeholder only — real art lands post-P1 per UI-SPEC Open Items §2). Accept Xcode's "missing image" warnings.

    **Tests** are not added in this task because `CAAnimationFactory` / `BrandColor` are purely declarative AppKit wrappers. A single XCTest for `HudState.voiceOverLabel` goes into Plan 03 Task 3's `App/Tests/AppTests` suite alongside MenuBarIconController.
  </action>
  <verify>
    <automated>xcodebuild -project Jarvis.xcodeproj -scheme Jarvis -configuration Debug build -destination 'platform=macOS' -derivedDataPath build 2>&amp;1 | tail -10</automated>
  </verify>
  <acceptance_criteria>
    - `test -f App/Theme/HudState.swift && grep -c 'case idle\|case listening\|case thinking\|case speaking\|case awaitingConfirmation' App/Theme/HudState.swift` returns ≥ 5
    - `grep '"Jarvis, idle"\|"Jarvis, listening"\|"Jarvis, thinking"\|"Jarvis, speaking"\|"Jarvis, waiting for your confirmation"' App/Theme/HudState.swift` returns 5 matches (verbatim UI-SPEC labels)
    - `test -f App/Theme/BrandColors.swift && grep 'accessibilityDisplayShouldIncreaseContrast' App/Theme/BrandColors.swift` returns 1 match
    - `grep '0x1E/255.0.*0x88/255.0.*0xE5/255.0' App/Theme/BrandColors.swift` returns 1 match (light-mode hex)
    - `grep '0x64/255.0.*0xB5/255.0.*0xF6/255.0' App/Theme/BrandColors.swift` returns 1 match (dark-mode hex)
    - `test -f App/MenuBar/CAAnimationFactory.swift && grep -c 'makeBreath\|makeRotate\|makeShimmer\|makeGlow\|makeStateCrossfade' App/MenuBar/CAAnimationFactory.swift` returns ≥ 5
    - `grep 'accessibilityDisplayShouldReduceMotion' App/MenuBar/CAAnimationFactory.swift` returns ≥ 4 matches (one guard per helper)
    - `grep '"transform.scale"' App/MenuBar/CAAnimationFactory.swift` returns 1 match; `grep '"transform.rotation.z"' App/MenuBar/CAAnimationFactory.swift` returns 1 match
    - `test -f App/Assets.xcassets/Icon-MenuBar-Template.imageset/Icon-MenuBar-Template.pdf` (placeholder PDF present)
    - `jq -r '.properties."template-rendering-intent"' App/Assets.xcassets/Icon-MenuBar-Template.imageset/Contents.json` returns `template`
    - `jq -r '.properties."preserves-vector-representation"' App/Assets.xcassets/Icon-MenuBar-Template.imageset/Contents.json` returns `true`
    - `xcodebuild -project Jarvis.xcodeproj -scheme Jarvis -configuration Debug build -derivedDataPath build` exits 0 (app still compiles with new sources)
  </acceptance_criteria>
  <done>HudState enum + BrandColors + CAAnimationFactory compile in the App target under Swift 6 strict; menu-bar template PDF is in the asset catalog with correct template-rendering-intent.</done>
</task>

<task type="auto" tdd="true">
  <name>Task 2: Build MenuBarIconController + MenuBarContextMenu with left-click/right-click behavior</name>
  <files>App/MenuBar/MenuBarIconController.swift, App/MenuBar/MenuBarContextMenu.swift, App/Tests/AppTests/MenuBarIconControllerTests.swift</files>
  <behavior>
    - Test: `MenuBarIconController(statusItem:contextMenu:)` installs a `button.image` from asset `Icon-MenuBar-Template` with `isTemplate = true`; `button.layer.anchorPoint == (0.5, 0.5)`
    - Test: `transition(to: .idle)` removes all `state.*` animations from `button.layer`
    - Test: `transition(to: .listening)` adds an animation with key `state.breath` (or the `nil`-returning Reduce Motion fallback path is exercised)
    - Test: `transition(to: .thinking)` adds `state.rotate`
    - Test: `transition(to: newState)` where `newState == currentState` is a no-op (no animations removed/added)
    - Test: accessibility label updates on each transition (`button.accessibilityLabel(...) == state.voiceOverLabel`)
    - Test: context menu carries items: `Setup…`, `Settings…` (disabled), separator, `Show Dev Overlay`, `Copy State Dump`, separator, `Quit Jarvis` with ⌘Q
  </behavior>
  <read_first>
    - App/Theme/HudState.swift (from Task 1 — state enum)
    - App/MenuBar/CAAnimationFactory.swift (from Task 1 — animation helpers)
    - .planning/phases/01-foundations/01-UI-SPEC.md §Surface 3 lines 366-422 (menu-bar item full spec: layout, state, click, accessibility)
    - .planning/phases/01-foundations/01-UI-SPEC.md §Surface 4 lines 424-446 (context menu items + ordering)
    - .planning/phases/01-foundations/01-RESEARCH.md §Question 7 lines 753-869 (full MenuBarIconController shape including layer configureButtonLayer, transition(to:), known gotchas)
    - .planning/phases/01-foundations/01-PATTERNS.md §C lines 49-52 (MenuBar file classifications)
    - .planning/phases/01-foundations/01-CONTEXT.md D-13 (custom template PDF, isTemplate=true), D-14 (state→animation mapping, crossfade), D-16 (left-click summons HUD; right-click shows menu)
  </read_first>
  <action>
    **`App/MenuBar/MenuBarIconController.swift`** — full `@MainActor` class per RESEARCH Q7 lines 756-858:
    ```swift
    import AppKit
    import QuartzCore

    @MainActor
    public final class MenuBarIconController {
        public let statusItem: NSStatusItem
        private let contextMenu: NSMenu
        private var currentState: HudState = .idle
        private var onLeftClick: (() -> Void)?
        private var lastAccessibilityAnnouncement: Date = .distantPast

        public init(statusItem: NSStatusItem, contextMenu: NSMenu) {
            self.statusItem = statusItem
            self.contextMenu = contextMenu
            configureButton()
        }

        public func setLeftClickAction(_ action: @escaping () -> Void) {
            self.onLeftClick = action
        }

        public func transition(to newState: HudState) {
            guard newState != currentState else { return }
            guard let button = statusItem.button, let layer = button.layer else { return }

            layer.add(CAAnimationFactory.makeStateCrossfade(), forKey: "crossfade")
            layer.removeAnimation(forKey: "state.breath")
            layer.removeAnimation(forKey: "state.rotate")
            layer.removeAnimation(forKey: "state.shimmer")
            layer.removeAnimation(forKey: "state.glow")

            switch newState {
            case .idle:
                break
            case .listening:
                if let a = CAAnimationFactory.makeBreath() { layer.add(a, forKey: "state.breath") }
            case .thinking:
                if let a = CAAnimationFactory.makeRotate() { layer.add(a, forKey: "state.rotate") }
            case .speaking:
                if let a = CAAnimationFactory.makeShimmer() { layer.add(a, forKey: "state.shimmer") }
            case .awaitingConfirmation:
                if let a = CAAnimationFactory.makeGlow() { layer.add(a, forKey: "state.glow") }
            }

            currentState = newState
            button.setAccessibilityLabel(newState.voiceOverLabel)
            announceRateLimited(newState.voiceOverLabel)
        }

        public var state: HudState { currentState }

        private func configureButton() {
            guard let button = statusItem.button else { return }
            button.image = NSImage(named: "Icon-MenuBar-Template")
            button.image?.isTemplate = true

            button.wantsLayer = true
            if let layer = button.layer {
                layer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
                layer.frame = button.bounds   // re-anchor after changing anchorPoint (Q7 gotcha #2)
            }

            button.setAccessibilityLabel(currentState.voiceOverLabel)
            button.setAccessibilityHelp("Click to summon or dismiss Jarvis. Right-click for more options.")
            button.setAccessibilityRole(.button)

            // Wire action. `sendAction:to:` lets us inspect NSApp.currentEvent for left vs right click.
            button.target = self
            button.action = #selector(handleClick(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        @objc private func handleClick(_ sender: NSStatusBarButton) {
            guard let event = NSApp.currentEvent else { return }
            let isRightClick = event.type == .rightMouseUp
                || event.modifierFlags.contains(.control)
            if isRightClick {
                statusItem.menu = contextMenu
                sender.performClick(nil)
                statusItem.menu = nil   // reset so left-click next time doesn't open menu
            } else {
                onLeftClick?()
            }
        }

        private func announceRateLimited(_ label: String) {
            // UI-SPEC line 421: no more than once per 3s.
            let now = Date()
            guard now.timeIntervalSince(lastAccessibilityAnnouncement) >= 3.0 else { return }
            lastAccessibilityAnnouncement = now
            NSAccessibility.post(
                element: NSApp as Any,
                notification: .announcementRequested,
                userInfo: [.announcement: label]
            )
        }
    }
    ```

    **`App/MenuBar/MenuBarContextMenu.swift`** — NSMenu builder per UI-SPEC Surface 4 lines 428-436:
    ```swift
    import AppKit

    @MainActor
    public enum MenuBarContextMenu {
        /// Builds the menu. Action targets are wired by AppDelegate (Plan 04) via `setAction(for:)`.
        public static func build(
            setupAction: @escaping () -> Void,
            devOverlayToggleAction: @escaping () -> Void,
            stateDumpAction: @escaping () -> Void
        ) -> NSMenu {
            let menu = NSMenu()

            let setup = NSMenuItem(title: "Setup…", action: nil, keyEquivalent: "")
            setup.target = SetupTarget(action: setupAction)
            setup.action = #selector(SetupTarget.run)
            menu.addItem(setup)

            let settings = NSMenuItem(title: "Settings…", action: nil, keyEquivalent: "")
            settings.isEnabled = false
            settings.toolTip = "Coming soon"
            menu.addItem(settings)

            menu.addItem(NSMenuItem.separator())

            let devOverlay = NSMenuItem(title: "Show Dev Overlay", action: nil, keyEquivalent: "")
            devOverlay.target = SetupTarget(action: devOverlayToggleAction)
            devOverlay.action = #selector(SetupTarget.run)
            menu.addItem(devOverlay)

            let stateDump = NSMenuItem(title: "Copy State Dump", action: nil, keyEquivalent: "")
            stateDump.target = SetupTarget(action: stateDumpAction)
            stateDump.action = #selector(SetupTarget.run)
            menu.addItem(stateDump)

            menu.addItem(NSMenuItem.separator())

            let quit = NSMenuItem(title: "Quit Jarvis", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
            quit.keyEquivalentModifierMask = [.command]
            menu.addItem(quit)

            return menu
        }
    }

    /// Objective-C-visible trampoline for closure-based menu actions.
    @MainActor
    private final class SetupTarget: NSObject {
        let action: () -> Void
        init(action: @escaping () -> Void) { self.action = action; super.init() }
        @objc func run() { action() }
    }
    ```

    Note: The trampoline pattern stores strong refs on menu items; this is deliberate so closures survive the menu's lifetime. In Plan 04 the setup closure is wired to `OnboardingWizardController.open(atFirstUnresolved:)`.

    **Tests** in `App/Tests/AppTests/MenuBarIconControllerTests.swift` (the App target's test target — if Jarvis.xcodeproj doesn't yet have an App test target, add it now as part of this task with scheme name `JarvisAppTests`):
    ```swift
    import XCTest
    import AppKit
    @testable import Jarvis   // App target module

    @MainActor
    final class MenuBarIconControllerTests: XCTestCase {
        func test_stateTransitionUpdatesAccessibilityLabel() {
            let statusBar = NSStatusBar.system
            let item = statusBar.statusItem(withLength: NSStatusItem.variableLength)
            defer { statusBar.removeStatusItem(item) }

            let menu = MenuBarContextMenu.build(setupAction: {}, devOverlayToggleAction: {}, stateDumpAction: {})
            let controller = MenuBarIconController(statusItem: item, contextMenu: menu)

            controller.transition(to: .listening)
            XCTAssertEqual(controller.state, .listening)
            XCTAssertEqual(item.button?.accessibilityLabel(), "Jarvis, listening")

            controller.transition(to: .thinking)
            XCTAssertEqual(item.button?.accessibilityLabel(), "Jarvis, thinking")
        }

        func test_sameStateTransitionIsNoOp() {
            let statusBar = NSStatusBar.system
            let item = statusBar.statusItem(withLength: NSStatusItem.variableLength)
            defer { statusBar.removeStatusItem(item) }

            let menu = MenuBarContextMenu.build(setupAction: {}, devOverlayToggleAction: {}, stateDumpAction: {})
            let controller = MenuBarIconController(statusItem: item, contextMenu: menu)

            controller.transition(to: .idle)
            let firstAnimations = item.button?.layer?.animationKeys()?.sorted() ?? []
            controller.transition(to: .idle)  // second call — should no-op
            let secondAnimations = item.button?.layer?.animationKeys()?.sorted() ?? []
            XCTAssertEqual(firstAnimations, secondAnimations)
        }

        func test_contextMenuItems() {
            let menu = MenuBarContextMenu.build(setupAction: {}, devOverlayToggleAction: {}, stateDumpAction: {})
            let titles = menu.items.map(\.title)
            XCTAssertTrue(titles.contains("Setup…"))
            XCTAssertTrue(titles.contains("Settings…"))
            XCTAssertTrue(titles.contains("Show Dev Overlay"))
            XCTAssertTrue(titles.contains("Copy State Dump"))
            XCTAssertTrue(titles.contains("Quit Jarvis"))
            // Settings… disabled
            XCTAssertFalse(menu.items.first { $0.title == "Settings…" }!.isEnabled)
        }
    }
    ```

    Ensure Xcode project has an App test target named `JarvisAppTests` (Jarvis.xcodeproj) — if not present from Plan 01, add a Unit Testing Bundle target here, linking against the `Jarvis` host app.
  </action>
  <verify>
    <automated>xcodebuild test -project Jarvis.xcodeproj -scheme Jarvis -destination 'platform=macOS' -derivedDataPath build -only-testing:JarvisAppTests/MenuBarIconControllerTests 2>&amp;1 | tail -15</automated>
  </verify>
  <acceptance_criteria>
    - `test -f App/MenuBar/MenuBarIconController.swift && grep -c 'NSStatusItem\|NSStatusBarButton' App/MenuBar/MenuBarIconController.swift` returns ≥ 2
    - `grep '@MainActor' App/MenuBar/MenuBarIconController.swift` returns ≥ 1 match (S-2)
    - `grep 'isTemplate = true' App/MenuBar/MenuBarIconController.swift` returns 1 match (D-13)
    - `grep 'anchorPoint' App/MenuBar/MenuBarIconController.swift` returns ≥ 1 match (Q7 gotcha #2)
    - `grep 'layer.frame = button.bounds' App/MenuBar/MenuBarIconController.swift` returns 1 match (Q7 gotcha #2 re-anchor)
    - `grep -c 'state.breath\|state.rotate\|state.shimmer\|state.glow' App/MenuBar/MenuBarIconController.swift` returns ≥ 8 (remove + add per state — UI-SPEC Surface 3)
    - `grep '.rightMouseUp' App/MenuBar/MenuBarIconController.swift` returns ≥ 1 match (D-16 right-click detection)
    - `grep 'Setup…\|Settings…\|Show Dev Overlay\|Copy State Dump\|Quit Jarvis' App/MenuBar/MenuBarContextMenu.swift` returns all 5 matches (UI-SPEC Surface 4)
    - `grep 'keyEquivalent: "q"' App/MenuBar/MenuBarContextMenu.swift` returns 1 match (⌘Q)
    - `xcodebuild test -project Jarvis.xcodeproj -scheme Jarvis -destination 'platform=macOS' -derivedDataPath build -only-testing:JarvisAppTests/MenuBarIconControllerTests` exits 0 with ≥ 3 passing tests
  </acceptance_criteria>
  <done>`MenuBarIconController` installs a status-item template image, animates across five states with Reduce Motion fallbacks, distinguishes left-click from right-click, and exposes a 5-item NSMenu with ⌘Q wired to Quit.</done>
</task>

<task type="auto" tdd="true">
  <name>Task 3: Build JarvisHUDPanel + HUDBannerPanel + HUDBannerCoordinator + BannerContent + AppDelegate entitlement hard-block</name>
  <files>App/HUD/JarvisHUDPanel.swift, App/HUD/HUDBannerPanel.swift, App/HUD/HUDBannerCoordinator.swift, App/HUD/HUDBanner.swift, App/HUD/BannerContent.swift, App/AppDelegate.swift, App/Tests/AppTests/JarvisHUDPanelTests.swift, App/Tests/AppTests/HUDBannerCoordinatorTests.swift, App/Tests/AppTests/AppDelegateEntitlementTests.swift</files>
  <behavior>
    - Test: `JarvisHUDPanel` is created with `styleMask = [.borderless, .nonactivatingPanel]`, `level = .statusBar`, `collectionBehavior.contains(.canJoinAllSpaces)` and `.fullScreenAuxiliary`, `backgroundColor == .clear`, `isOpaque == false`, `hidesOnDeactivate == false`
    - Test: `summon()` orders the panel front with `orderFrontRegardless()`; `dismiss()` calls `orderOut(nil)`
    - Test: pressing Escape while panel is keyWindow dismisses it (via `cancelOperation(_:)` override)
    - Test: when `accessibilityDisplayShouldReduceTransparency == true`, panel's visual-effect backing falls back to `windowBackgroundColor` at 95% opacity (UI-SPEC Surface 7 line 590)
    - Test: `HUDBannerCoordinator.enqueue(.keychainEmpty)` shows banner; subsequent `.inputMonitoringDenied` goes to queue; `dismissCurrent()` drains queue to next
    - Test: banner priority ordering — enqueueing `.inputMonitoringDenied` first then `.keychainEmpty` → `.keychainEmpty` shows first (priority 1 < 2)
    - Test: `AppDelegate.applicationWillFinishLaunching` reads `JarvisEntitlementsVerified` from `Info.plist`; if false, calls a `presentEntitlementFailureAlert()` (injectable for test) and `NSApp.terminate(_:)`. Pure-logic test: inject a mock `EntitlementGateProbe` that returns false → expect `terminate` to be called
  </behavior>
  <read_first>
    - App/Theme/BrandColors.swift (from Task 1)
    - App/Theme/HudState.swift (from Task 1)
    - .planning/phases/01-foundations/01-UI-SPEC.md §Surface 5 lines 450-503 (HUDBannerPanel + HUDBanner + HUDBannerCoordinator full spec)
    - .planning/phases/01-foundations/01-UI-SPEC.md §Surface 6 lines 506-532 (NSAlert modals for hard-blockers)
    - .planning/phases/01-foundations/01-UI-SPEC.md §Surface 7 lines 536-592 (JarvisHUDPanel full spec)
    - .planning/phases/01-foundations/01-RESEARCH.md §Pattern 1 lines 1249-1294 (AppDelegate entitlement hard-block shape — copy verbatim)
    - .planning/phases/01-foundations/01-RESEARCH.md §Open Question 7 line 1546 (statusItem button layer may be nil on first launch — DispatchQueue.main.async guard)
    - .planning/phases/01-foundations/01-PATTERNS.md §D lines 55-60 (HUD panel file classifications) and §B line 44 (AppDelegate lifecycle pattern)
  </read_first>
  <action>
    **`App/HUD/BannerContent.swift`**:
    ```swift
    import Foundation

    public struct BannerContent: Sendable, Equatable, Identifiable {
        public let id: String
        public let priority: Int
        public let title: String
        public let body: String
        public let action: Action?

        public struct Action: Sendable, Equatable {
            public let label: String
            public let url: URL?
            public init(label: String, url: URL?) { self.label = label; self.url = url }
        }

        public init(id: String, priority: Int, title: String, body: String, action: Action?) {
            self.id = id
            self.priority = priority
            self.title = title
            self.body = body
            self.action = action
        }
    }

    /// Preset banners per UI-SPEC Surface 5 copywriting table + priority order.
    public extension BannerContent {
        static let keychainEmpty = BannerContent(
            id: "keychain-empty",
            priority: 1,
            title: "No API key configured",
            body: "Jarvis can't reach Claude until you set up an API key.",
            action: .init(label: "Open Setup", url: nil)
        )
        static let inputMonitoringDenied = BannerContent(
            id: "input-monitoring-denied",
            priority: 2,
            title: "Limited hotkey mode",
            body: "Jarvis can't see global key presses. The hotkey will only work when Jarvis is frontmost.",
            action: .init(
                label: "Open System Settings",
                url: URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")
            )
        )
        static let hotkeyBindFailed = BannerContent(
            id: "hotkey-bind-failed",
            priority: 3,
            title: "Hotkey unavailable",
            body: "Couldn't register your hotkey — another app may have claimed it. Click the menu-bar icon to summon Jarvis.",
            action: .init(label: "Rebind", url: nil)
        )
        static let ollamaURLRejected = BannerContent(
            id: "ollama-url-rejected",
            priority: 4,
            title: "Ollama config rejected",
            body: "The configured Ollama URL isn't local. Only 127.0.0.1 and localhost are allowed. Check config.json.",
            action: .init(label: "Reveal config", url: nil)
        )
    }
    ```

    **`App/HUD/HUDBanner.swift`** — SwiftUI view per UI-SPEC Surface 5 layout:
    ```swift
    import SwiftUI
    import AppKit

    struct HUDBanner: View {
        let content: BannerContent
        let onAction: () -> Void
        let onDismiss: () -> Void

        var body: some View {
            HStack(spacing: 0) {
                Rectangle()
                    .fill(Color(nsColor: BrandColor.arcReactorGlow))
                    .frame(width: 4)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(content.title).font(.headline).foregroundColor(Color(NSColor.labelColor))
                            Text(content.body).font(.body).foregroundColor(Color(NSColor.secondaryLabelColor))
                        }
                        Spacer(minLength: 8)
                        Button(action: onDismiss) {
                            Image(systemName: "xmark")
                                .font(.system(size: 11, weight: .semibold))
                                .frame(width: 24, height: 24)
                        }
                        .buttonStyle(.plain)
                        .foregroundColor(Color(NSColor.secondaryLabelColor))
                        .accessibilityLabel("Dismiss notification")
                    }
                    if let action = content.action {
                        Button(action.label, action: onAction)
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                    }
                }
                .padding(.leading, 16)
                .padding(.trailing, 16)
                .padding(.vertical, 12)
            }
            .background(
                VisualEffectBackground(material: .hudWindow, blendingMode: .behindWindow)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(Color(NSColor.separatorColor), lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
    }

    struct VisualEffectBackground: NSViewRepresentable {
        let material: NSVisualEffectView.Material
        let blendingMode: NSVisualEffectView.BlendingMode
        func makeNSView(context: Context) -> NSVisualEffectView {
            let v = NSVisualEffectView()
            v.material = material
            v.blendingMode = blendingMode
            v.state = .active
            return v
        }
        func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
            nsView.material = material
            nsView.blendingMode = blendingMode
        }
    }
    ```

    **`App/HUD/HUDBannerPanel.swift`** — `.floating` non-activating panel per UI-SPEC Surface 5 lines 458-464:
    ```swift
    import AppKit
    import SwiftUI

    @MainActor
    public final class HUDBannerPanel: NSPanel {
        public init() {
            let initialFrame = NSRect(x: 0, y: 0, width: 360, height: 96)
            super.init(
                contentRect: initialFrame,
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            self.level = .floating
            self.isMovableByWindowBackground = false
            self.isOpaque = false
            self.backgroundColor = .clear
            self.hasShadow = true
            self.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
            self.hidesOnDeactivate = false
            self.titleVisibility = .hidden
        }

        public override var canBecomeKey: Bool { false }
        public override var canBecomeMain: Bool { false }

        public func host(_ view: some View) {
            self.contentView = NSHostingView(rootView: view)
            self.positionTopTrailing()
        }

        /// Position banner 24pt from right edge, 8pt below system menu-bar height.
        public func positionTopTrailing() {
            guard let screen = NSScreen.main else { return }
            let visibleFrame = screen.visibleFrame
            let bannerWidth: CGFloat = 360
            let bannerHeight: CGFloat = self.contentView?.fittingSize.height ?? 96
            let x = visibleFrame.maxX - bannerWidth - 24
            let y = visibleFrame.maxY - bannerHeight - 8
            self.setFrame(NSRect(x: x, y: y, width: bannerWidth, height: bannerHeight), display: true)
        }
    }
    ```

    **`App/HUD/HUDBannerCoordinator.swift`** per UI-SPEC Surface 5 per-condition lifecycle:
    ```swift
    import AppKit
    import SwiftUI

    @MainActor
    public final class HUDBannerCoordinator {
        public let panel: HUDBannerPanel
        private var queue: [BannerContent] = []
        private var current: BannerContent?
        private var dismissedThisLaunch: Set<String> = []

        public init(panel: HUDBannerPanel) { self.panel = panel }

        /// Enqueue a banner. If nothing is showing, render immediately; else push by priority.
        public func enqueue(_ content: BannerContent) {
            if dismissedThisLaunch.contains(content.id) { return }
            // De-duplicate by id (if same condition re-triggers, ignore while dismissed).
            if current?.id == content.id { return }
            if queue.contains(where: { $0.id == content.id }) { return }

            if current == nil {
                showBanner(content)
            } else {
                queue.append(content)
                queue.sort { $0.priority < $1.priority }
                // Pre-empt: if new banner's priority is strictly better than current, push current back
                if let top = queue.first, let c = current, top.priority < c.priority {
                    queue.removeFirst()
                    queue.append(c)
                    queue.sort { $0.priority < $1.priority }
                    showBanner(top)
                }
            }
        }

        public func dismissCurrent() {
            if let c = current { dismissedThisLaunch.insert(c.id) }
            current = nil
            panel.orderOut(nil)
            if !queue.isEmpty {
                let next = queue.removeFirst()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                    self?.showBanner(next)
                }
            }
        }

        public func clear() {
            queue.removeAll()
            current = nil
            panel.orderOut(nil)
        }

        public var currentBanner: BannerContent? { current }
        public var queuedCount: Int { queue.count }

        private func showBanner(_ content: BannerContent) {
            current = content
            let view = HUDBanner(
                content: content,
                onAction: { [weak self] in self?.handleAction(for: content) },
                onDismiss: { [weak self] in self?.dismissCurrent() }
            )
            panel.host(view)
            panel.orderFrontRegardless()
        }

        private func handleAction(for content: BannerContent) {
            if let url = content.action?.url {
                NSWorkspace.shared.open(url)
            }
            // Other action paths (Open Setup, Rebind hotkey, Reveal config) wire in Plan 04.
            dismissCurrent()
        }
    }
    ```

    **`App/HUD/JarvisHUDPanel.swift`** — full borderless transparent panel per UI-SPEC Surface 7 lines 540-590:
    ```swift
    import AppKit
    import WebKit

    @MainActor
    public final class JarvisHUDPanel: NSPanel {
        private var webView: WKWebView!
        private let hudSize = NSSize(width: 720, height: 720)

        public init() {
            super.init(
                contentRect: NSRect(origin: .zero, size: hudSize),
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

            let config = WKWebViewConfiguration()
            self.webView = WKWebView(frame: .zero, configuration: config)
            self.webView.translatesAutoresizingMaskIntoConstraints = false
            self.webView.isOpaque = false
            self.webView.underPageBackgroundColor = .clear
            self.webView.setValue(false, forKey: "drawsBackground")   // macOS 26 private-key force

            let container = NSView()
            container.wantsLayer = true
            container.addSubview(self.webView)
            NSLayoutConstraint.activate([
                self.webView.topAnchor.constraint(equalTo: container.topAnchor),
                self.webView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
                self.webView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                self.webView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            ])
            self.contentView = container
            self.setAccessibilityLabel("Jarvis HUD")
            self.setAccessibilityRole(.window)
            applyReduceTransparencyIfNeeded()
        }

        public override var canBecomeKey: Bool { true }
        public override var canBecomeMain: Bool { false }

        public var isSummoned: Bool { self.isVisible }

        public func summon(on screen: NSScreen? = nil) {
            let targetScreen = screen ?? NSScreen.screenWithMouse() ?? NSScreen.main
            if let frame = targetScreen?.visibleFrame {
                let x = frame.midX - hudSize.width / 2
                let y = frame.midY - hudSize.height / 2
                self.setFrame(NSRect(x: x, y: y, width: hudSize.width, height: hudSize.height), display: true)
            }
            self.orderFrontRegardless()
            NSAccessibility.post(element: self as Any,
                                  notification: .announcementRequested,
                                  userInfo: [.announcement: "Jarvis opened"])
        }

        public func dismiss() {
            self.orderOut(nil)
            NSAccessibility.post(element: self as Any,
                                  notification: .announcementRequested,
                                  userInfo: [.announcement: "Jarvis dismissed"])
        }

        /// Escape key dismisses (UI-SPEC Surface 7 line 576).
        public override func cancelOperation(_ sender: Any?) {
            dismiss()
        }

        /// ⌘W dismiss (UI-SPEC Surface 7 line 578).
        public override func performClose(_ sender: Any?) {
            dismiss()
        }

        private func applyReduceTransparencyIfNeeded() {
            guard NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency else { return }
            self.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.95)
            self.isOpaque = false
        }
    }

    extension NSScreen {
        static func screenWithMouse() -> NSScreen? {
            let mouseLocation = NSEvent.mouseLocation
            return NSScreen.screens.first { NSMouseInRect(mouseLocation, $0.frame, false) }
        }
    }
    ```

    **`App/AppDelegate.swift`** — entitlement hard-block per RESEARCH §Pattern 1 lines 1258-1293. AppDelegate in THIS plan does NOT yet import `Keychain`, `Config`, or `JarvisLogging` (Plan 04 adds full wiring). It ONLY exercises the Info.plist read + NSAlert + menu-bar + HUD panel installation:
    ```swift
    import AppKit

    /// For test injection: protocol allows a mock that returns false without touching Info.plist.
    public protocol EntitlementGateProbe: Sendable {
        func isVerified() -> Bool
    }

    public struct InfoPlistEntitlementGateProbe: EntitlementGateProbe {
        public init() {}
        public func isVerified() -> Bool {
            Bundle.main.object(forInfoDictionaryKey: "JarvisEntitlementsVerified") as? Bool ?? false
        }
    }

    @MainActor
    final class AppDelegate: NSObject, NSApplicationDelegate {
        /// Overridable for tests.
        var entitlementProbe: EntitlementGateProbe = InfoPlistEntitlementGateProbe()
        /// Overridable for tests — called on entitlement failure instead of presenting NSAlert + terminate.
        var onEntitlementFailure: () -> Void = {
            AppDelegate.presentEntitlementFailureAlert()
            NSApp.terminate(nil)
        }

        var statusItem: NSStatusItem?
        var menuBarController: MenuBarIconController?
        var hudPanel: JarvisHUDPanel?
        var bannerPanel: HUDBannerPanel?
        var bannerCoordinator: HUDBannerCoordinator?

        func applicationWillFinishLaunching(_ notification: Notification) {
            // (S-8) Logging bootstrap happens here in Plan 04; this plan leaves the call site open.
            // 1. Entitlement hard-block.
            guard entitlementProbe.isVerified() else {
                onEntitlementFailure()
                return
            }
            // 2. Menu-bar + HUD panel install.
            installMenuBar()
            installHUDPanel()
            installBannerPanel()
            // 3. Config load / Keychain fetch / Hotkey binding — all Plan 04.
        }

        private func installMenuBar() {
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            self.statusItem = item
            let menu = MenuBarContextMenu.build(
                setupAction: { /* wired Plan 04 — opens wizard */ },
                devOverlayToggleAction: { /* stub: Plan 04 shows "Dev Overlay lands in Phase 4" banner */ },
                stateDumpAction: { /* stub: Plan 04 copies state JSON to clipboard */ }
            )
            self.menuBarController = MenuBarIconController(statusItem: item, contextMenu: menu)
            self.menuBarController?.setLeftClickAction { [weak self] in
                self?.toggleHUD()
            }
        }

        private func installHUDPanel() {
            let panel = JarvisHUDPanel()
            panel.orderOut(nil)
            self.hudPanel = panel
        }

        private func installBannerPanel() {
            let panel = HUDBannerPanel()
            panel.orderOut(nil)
            self.bannerPanel = panel
            self.bannerCoordinator = HUDBannerCoordinator(panel: panel)
        }

        private func toggleHUD() {
            guard let panel = hudPanel else { return }
            if panel.isSummoned { panel.dismiss() } else { panel.summon() }
        }

        static func presentEntitlementFailureAlert() {
            let alert = NSAlert()
            alert.alertStyle = .critical
            alert.messageText = "Jarvis can't start"
            alert.informativeText = """
            A build verification check failed at launch. The app has been \
            stopped to prevent a crash. Reinstall Jarvis or rebuild from source with the correct entitlements.
            """
            alert.addButton(withTitle: "Quit")
            alert.addButton(withTitle: "Show Details")
            let response = alert.runModal()
            if response == .alertSecondButtonReturn {
                let log = URL(fileURLWithPath:
                    (NSHomeDirectory() as NSString).appendingPathComponent("Library/Logs/Jarvis/system.log"))
                NSWorkspace.shared.open(log)
            }
        }
    }
    ```

    **Tests** in `App/Tests/AppTests/`:

    `JarvisHUDPanelTests.swift`:
    ```swift
    import XCTest
    @testable import Jarvis

    @MainActor
    final class JarvisHUDPanelTests: XCTestCase {
        func test_panelHasExpectedStyleAndLevel() {
            let panel = JarvisHUDPanel()
            XCTAssertTrue(panel.styleMask.contains(.borderless))
            XCTAssertTrue(panel.styleMask.contains(.nonactivatingPanel))
            XCTAssertEqual(panel.level, .statusBar)
            XCTAssertTrue(panel.collectionBehavior.contains(.canJoinAllSpaces))
            XCTAssertTrue(panel.collectionBehavior.contains(.fullScreenAuxiliary))
            XCTAssertTrue(panel.collectionBehavior.contains(.transient))
            XCTAssertFalse(panel.isOpaque)
            XCTAssertFalse(panel.hidesOnDeactivate)
        }

        func test_summonAndDismiss() {
            let panel = JarvisHUDPanel()
            XCTAssertFalse(panel.isSummoned)
            panel.summon()
            XCTAssertTrue(panel.isSummoned)
            panel.dismiss()
            XCTAssertFalse(panel.isSummoned)
        }

        func test_escapeDismissesViaCancelOperation() {
            let panel = JarvisHUDPanel()
            panel.summon()
            XCTAssertTrue(panel.isSummoned)
            panel.cancelOperation(nil)  // simulates Escape
            XCTAssertFalse(panel.isSummoned)
        }
    }
    ```

    `HUDBannerCoordinatorTests.swift`:
    ```swift
    import XCTest
    @testable import Jarvis

    @MainActor
    final class HUDBannerCoordinatorTests: XCTestCase {
        func test_enqueueShowsImmediatelyWhenIdle() {
            let panel = HUDBannerPanel()
            let coordinator = HUDBannerCoordinator(panel: panel)
            coordinator.enqueue(.inputMonitoringDenied)
            XCTAssertEqual(coordinator.currentBanner?.id, "input-monitoring-denied")
            XCTAssertEqual(coordinator.queuedCount, 0)
        }

        func test_priorityPreemption() {
            let panel = HUDBannerPanel()
            let coordinator = HUDBannerCoordinator(panel: panel)
            coordinator.enqueue(.inputMonitoringDenied)  // priority 2
            coordinator.enqueue(.keychainEmpty)          // priority 1 — higher → preempt
            XCTAssertEqual(coordinator.currentBanner?.id, "keychain-empty",
                           "Higher priority (keychain-empty) should preempt inputMonitoringDenied")
        }

        func test_dismissDrainsQueue() {
            let panel = HUDBannerPanel()
            let coordinator = HUDBannerCoordinator(panel: panel)
            coordinator.enqueue(.keychainEmpty)
            coordinator.enqueue(.hotkeyBindFailed)
            XCTAssertEqual(coordinator.currentBanner?.id, "keychain-empty")
            coordinator.dismissCurrent()
            // Queue drain is async (0.3s delay in showBanner); wait via runloop.
            let exp = expectation(description: "next banner shows")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                XCTAssertEqual(coordinator.currentBanner?.id, "hotkey-bind-failed")
                exp.fulfill()
            }
            wait(for: [exp], timeout: 2.0)
        }

        func test_dismissedThisLaunchDoesNotRe_enqueue() {
            let panel = HUDBannerPanel()
            let coordinator = HUDBannerCoordinator(panel: panel)
            coordinator.enqueue(.ollamaURLRejected)
            coordinator.dismissCurrent()
            coordinator.enqueue(.ollamaURLRejected)
            XCTAssertNil(coordinator.currentBanner, "Same banner dismissed-this-launch should not re-enqueue")
        }
    }
    ```

    `AppDelegateEntitlementTests.swift`:
    ```swift
    import XCTest
    @testable import Jarvis

    @MainActor
    final class AppDelegateEntitlementTests: XCTestCase {
        private struct MockProbe: EntitlementGateProbe {
            let verified: Bool
            func isVerified() -> Bool { verified }
        }

        func test_hardBlockTriggersOnMissingVerification() {
            let delegate = AppDelegate()
            delegate.entitlementProbe = MockProbe(verified: false)
            var failureCalled = false
            delegate.onEntitlementFailure = { failureCalled = true }

            delegate.applicationWillFinishLaunching(Notification(name: .init("test")))
            XCTAssertTrue(failureCalled, "Entitlement failure callback should fire when probe returns false")
        }

        func test_noHardBlockWhenVerified() {
            let delegate = AppDelegate()
            delegate.entitlementProbe = MockProbe(verified: true)
            var failureCalled = false
            delegate.onEntitlementFailure = { failureCalled = true }

            delegate.applicationWillFinishLaunching(Notification(name: .init("test")))
            XCTAssertFalse(failureCalled, "Entitlement failure should NOT fire when probe returns true")
        }
    }
    ```
  </action>
  <verify>
    <automated>xcodebuild test -project Jarvis.xcodeproj -scheme Jarvis -destination 'platform=macOS' -derivedDataPath build -only-testing:JarvisAppTests/JarvisHUDPanelTests -only-testing:JarvisAppTests/HUDBannerCoordinatorTests -only-testing:JarvisAppTests/AppDelegateEntitlementTests 2>&amp;1 | tail -20</automated>
  </verify>
  <acceptance_criteria>
    - `test -f App/HUD/JarvisHUDPanel.swift && grep -c '.borderless\|.nonactivatingPanel' App/HUD/JarvisHUDPanel.swift` returns ≥ 2
    - `grep 'level = .statusBar' App/HUD/JarvisHUDPanel.swift` returns 1 match
    - `grep 'collectionBehavior = \[.canJoinAllSpaces, .fullScreenAuxiliary, .transient\]' App/HUD/JarvisHUDPanel.swift` returns 1 match
    - `grep 'drawsBackground' App/HUD/JarvisHUDPanel.swift` returns 1 match (macOS 26 private-key force per UI-SPEC Surface 7 line 562)
    - `grep 'cancelOperation' App/HUD/JarvisHUDPanel.swift` returns ≥ 1 match (Escape dismissal per UI-SPEC Surface 7 line 576)
    - `grep 'accessibilityDisplayShouldReduceTransparency' App/HUD/JarvisHUDPanel.swift` returns 1 match (UI-SPEC line 590)
    - `test -f App/HUD/HUDBannerPanel.swift && grep 'level = .floating' App/HUD/HUDBannerPanel.swift` returns 1 match
    - `grep 'canBecomeKey\|canBecomeMain' App/HUD/HUDBannerPanel.swift` returns ≥ 2 matches (both `false` per banner-never-steals-focus)
    - `test -f App/HUD/HUDBannerCoordinator.swift && grep -c 'keychainEmpty\|inputMonitoringDenied\|hotkeyBindFailed\|ollamaURLRejected' App/HUD/BannerContent.swift` returns ≥ 4 (four preset banners)
    - `grep 'priority: 1\|priority: 2\|priority: 3\|priority: 4' App/HUD/BannerContent.swift` returns 4 matches (UI-SPEC priority order)
    - `grep 'JarvisEntitlementsVerified' App/AppDelegate.swift` returns ≥ 1 match
    - `grep 'presentEntitlementFailureAlert\|alertStyle = .critical' App/AppDelegate.swift` returns ≥ 2 matches
    - `grep 'EntitlementGateProbe' App/AppDelegate.swift` returns ≥ 2 matches (protocol declared + consumed — enables test injection)
    - `xcodebuild test -project Jarvis.xcodeproj -scheme Jarvis -destination 'platform=macOS' -derivedDataPath build -only-testing:JarvisAppTests/JarvisHUDPanelTests -only-testing:JarvisAppTests/HUDBannerCoordinatorTests -only-testing:JarvisAppTests/AppDelegateEntitlementTests` exits 0 with all tests passing (≥ 9 total: HUDPanel 3 + Coordinator 4 + AppDelegate 2)
  </acceptance_criteria>
  <done>HUD panel + banner panel + coordinator all compile with correct NSPanel flags; AppDelegate hard-blocks on entitlement failure (test-proven via mock probe); banner priority queue + dismiss-this-launch de-dup work.</done>
</task>

</tasks>

<threat_model>
## Trust Boundaries

| Boundary | Description |
|----------|-------------|
| Info.plist `JarvisEntitlementsVerified` key → AppDelegate | Build-time-written key is the contract; runtime hard-block enforces it |
| Menu-bar button click → main app action | Untrusted click event; left/right distinction determines HUD toggle vs menu |
| Banner action button → deep-link URL | URLs deep-linked to System Settings are hardcoded in BannerContent presets |

## STRIDE Threat Register

| Threat ID | Category | Component | Disposition | Mitigation Plan |
|-----------|----------|-----------|-------------|-----------------|
| T-03-01 | Denial of Service | Cold Release launch with missing `allow-jit` | mitigate | AppDelegate `applicationWillFinishLaunching` reads `JarvisEntitlementsVerified` Info.plist key; if false/missing, NSAlert `.critical` modal + `NSApp.terminate(_:)` (RESEARCH §Pattern 1). Test-proven via mock `EntitlementGateProbe`. |
| T-03-02 | Tampering | Static-item button click routing | accept | Left-click vs right-click inspection via `NSApp.currentEvent.type`; no untrusted data on the wire. Standard AppKit pattern. |
| T-03-03 | Information Disclosure | "Copy State Dump" menu item | mitigate | Plan 04 wires the state dump — will include API-key-present boolean but NEVER the key itself (follows OBS-02 replay-log nothing-masked-bytes rule for the replay path, but user-facing dumps are a different surface — secrets never land in the clipboard). Grep-verified in Plan 04 acceptance. |
| T-03-04 | Denial of Service | `WKWebView` in empty HUD panel crashes from missing `allow-jit` in Release | mitigate | Same mitigation as T-03-01. WKWebView initializes JavaScriptCore even when empty; `allow-jit` entitlement is day-one (Plan 01) + build-time grep (Plan 05) + runtime hard-block (this plan). |
| T-03-05 | Elevation of Privilege | Context menu `Show Dev Overlay` / `Copy State Dump` actions | accept | In P1 these are stubs; Plan 04 wires them to non-privileged paths. No privileged operation in P1 UI layer. |
| T-03-06 | Denial of Service | `HUDBannerPanel` stealing keyboard focus | mitigate | `canBecomeKey == false` + `canBecomeMain == false`; `.nonactivatingPanel` style mask + `.floating` level. Verified by `HUDBannerCoordinatorTests` / `JarvisHUDPanelTests`. |

No `high`-severity residual risk. The critical path — `JarvisEntitlementsVerified` hard-block — is test-proven with a mock probe, so the logic is verified independent of an actual signed archive.
</threat_model>

<verification>
**Per task:**
- Task 1: App target still compiles with new sources
- Task 2: `xcodebuild test ... -derivedDataPath build -only-testing:JarvisAppTests/MenuBarIconControllerTests` exits 0 with ≥3 tests
- Task 3: `xcodebuild test ... -derivedDataPath build -only-testing:JarvisAppTests/JarvisHUDPanelTests -only-testing:JarvisAppTests/HUDBannerCoordinatorTests -only-testing:JarvisAppTests/AppDelegateEntitlementTests` exits 0 with ≥9 tests

**Integration sanity:** Build Debug — app compiles, launches, menu-bar icon visible, left-click toggles empty HUD panel. (Manual smoke; automation is `xcodebuild build -derivedDataPath build` exits 0.)
</verification>

<success_criteria>
- Menu-bar `NSStatusItem` installs with the arc-reactor template PDF (or placeholder concentric circles); `isTemplate = true`
- Five HudState transitions animate via `CAAnimationFactory` with Reduce Motion fallbacks
- Left-click on menu-bar icon toggles `JarvisHUDPanel`; right-click shows `MenuBarContextMenu`
- `JarvisHUDPanel` has the full UI-SPEC Surface 7 style flags (borderless, nonactivating, statusBar level, canJoinAllSpaces, transparent WKWebView)
- `HUDBannerPanel` is a separate `.floating` panel; `HUDBannerCoordinator` orders banners by priority (keychain-empty=1, input-monitoring-denied=2, hotkey-bind-failed=3, ollama-url-rejected=4)
- `AppDelegate` hard-blocks on missing `JarvisEntitlementsVerified` with a critical NSAlert
- Reduce Motion / Reduce Transparency / Increase Contrast fallbacks all honored
</success_criteria>

<output>
After completion, create `.planning/phases/01-foundations/01-03-SUMMARY.md` documenting:
- Menu-bar state→animation mapping (paste the `transition(to:)` switch)
- HUD panel style flags (paste)
- Banner priority order + preset IDs
- AppDelegate hard-block flow (paste pseudocode: read Info.plist key → NSAlert → terminate)
- Test count per file + what each test covers
- Wiring open items for Plan 04: setupAction closure, devOverlayToggleAction, stateDumpAction, banner action button handlers (Open Setup, Rebind hotkey, Reveal config)
</output>
</content>
</invoke>