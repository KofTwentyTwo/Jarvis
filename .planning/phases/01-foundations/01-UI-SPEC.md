---
phase: 1
slug: foundations
status: approved
shadcn_initialized: false
preset: n/a
created: 2026-04-22
reviewed_at: 2026-04-22
---

# Phase 1 — UI Design Contract

> Visual and interaction contract for Phase 1: Foundations. Native macOS surfaces only — SwiftUI wizard, AppKit menu-bar item, transparent NSPanel skeleton, NSAlert modals, HUD banner. No shadcn, no React, no R3F in this phase (those land in P3). Authored by gsd-ui-researcher, to be verified by gsd-ui-checker.

---

## Design System

| Property | Value |
|----------|-------|
| Tool | native (SwiftUI + AppKit) |
| Preset | n/a (no shadcn — pre-webview phase) |
| Component library | SwiftUI primitives + AppKit (`NSStatusItem`, `NSPanel`, `NSAlert`) |
| Icon library | SF Symbols (in-app UI chrome only) + one custom template vector asset (menu-bar arc-reactor silhouette) |
| Font | SF Pro (system) — `.body`, `.headline`, `.title2`, `.title` via `Font.system` |
| Appearance | Respects system light/dark automatically via `NSColor` semantics + `image.isTemplate = true`. No forced appearance. |
| Accessibility baseline | macOS system settings (Reduce Motion, Increase Contrast, Differentiate Without Color, Dynamic Type via `.body`/`.headline` tokens) honored in every surface. |

**Rationale for native-only:** Phase 1 predates the bus (P2) and the HUD webview (P3). No JSON protocol exists yet, so every user-facing surface in P1 must be native. The borderless NSPanel skeleton is created here but hosts a blank WKWebView until P3 — its chrome, geometry, and dismissal contract are specified here so P3 does not relitigate.

---

## Spacing Scale

Declared values. macOS 8pt grid aligns cleanly to multiples-of-4.

| Token | Value | Usage |
|-------|-------|-------|
| xs | 4pt | Tight inline gaps (icon ↔ label, keyboard-shortcut key-cap gutters) |
| sm | 8pt | Compact element spacing (form-row internal padding, button label↔icon) |
| md | 16pt | Default vertical rhythm between form fields, list rows, related controls |
| lg | 24pt | Section padding inside wizard panels, between stage content and footer |
| xl | 32pt | Major section breaks (between wizard stage header and body) |
| 2xl | 48pt | Wizard window outer content inset (left/right gutters) |
| 3xl | 64pt | Reserved — not used in P1 (flagged for P3 HUD use) |

**Exceptions:**
- **Menu-bar button hit area:** follows `NSStatusItem` system default (`length: variable`, ~22pt square). Do NOT inset the template image beyond the system-provided content rect.
- **NSAlert:** uses the OS-provided spacing — do not override. Alerts inherit Apple's standard insets.
- **Shortcut-recorder key-cap rendering:** internal key-cap padding is 6pt horizontal × 2pt vertical (non-standard, dictated by macOS system shortcut-field aesthetics). This is the single allowed non-multiple-of-4 exception, matching Apple's own System Settings shortcut UI.

---

## Typography

SF Pro via `Font.system`. Four roles, two weights.

| Role | Size | Weight | Line Height | Usage |
|------|------|--------|-------------|-------|
| Body | 13pt | regular (400) | 1.5 | Wizard prose, banner copy, NSAlert informative text, form labels |
| Label | 11pt | regular (400) | 1.4 | Secondary captions, inline warnings (e.g. "collides with Chrome/Slack/VSCode"), menu-bar VoiceOver-label-only strings |
| Heading | 17pt | semibold (600) | 1.25 | Wizard stage titles ("Connect to Claude", "Grant Permissions", "Bind Your Hotkey"), NSAlert message |
| Display | 22pt | semibold (600) | 1.2 | Wizard opening title on stage 1 header ("Welcome to Jarvis") |

**Weights declared:** `regular (400)` and `semibold (600)` only. No medium, no light, no bold. Two-weight discipline.

**System preferences honored:**
- Dynamic Type: not applicable on macOS; use `.body`/`.headline`/`.title2`/`.title3` tokens so System Settings → Accessibility → Display → Text Size scales correctly.
- Increase Contrast (System Settings → Accessibility → Display → Increase Contrast): relies on `NSColor` semantic tokens (see Color), which auto-adjust. No custom contrast logic required.

**Monospace usage:** deferred. P1 has no surfaces that render code, JSON, or logs. DevOverlay (P4) will introduce `SF Mono`.

---

## Color

Primary strategy: **NSColor semantic tokens** so macOS theming, Accent Color, and Increase Contrast all Just Work. Custom brand tokens are reserved for exactly two jobs: (1) the menu-bar arc-reactor silhouette (monochrome template — auto-inverts, no token), and (2) the HUD banner accent glow that previews the P3 HUD brand.

### Semantic tokens (macOS system)

| Role | Token | Usage |
|------|-------|-------|
| Dominant (60%) | `NSColor.windowBackgroundColor` | Wizard window chrome, Setup re-entry window background |
| Secondary (30%) | `NSColor.controlBackgroundColor` | Form-field backgrounds inside wizard (SecureField, shortcut-recorder capture area) |
| Separator | `NSColor.separatorColor` | Wizard footer/stage-header divider, banner top/bottom rule |
| Text primary | `NSColor.labelColor` | All body + heading text |
| Text secondary | `NSColor.secondaryLabelColor` | Inline warnings, hint text, explainer subheads |
| Accent (10%) | `NSColor.controlAccentColor` | Wizard primary CTA ("Continue", "Verify & Continue", "Save Hotkey"), focus rings, progress indicator |
| Destructive | `NSColor.systemRed` | Inline errors ("Key rejected — check the prefix"), NSAlert destructive button tint (when applicable) |
| Warning | `NSColor.systemOrange` | Hotkey collision warning ("Cmd+Shift+J collides with Chrome/Slack/VSCode") |
| Success | `NSColor.systemGreen` | API key validation checkmark after `models/list` probe succeeds |

### Custom brand tokens

| Role | Value | Usage |
|------|-------|-------|
| Arc-reactor glow (light mode) | `#1E88E5` at 85% opacity | **HUD banner leading edge accent stripe only.** Not used in menu-bar icon (which is pure template monochrome per D-13). |
| Arc-reactor glow (dark mode) | `#64B5F6` at 90% opacity | Same stripe under dark appearance — higher luminance for contrast against dark banner background. |

**Accent (10%) reserved for — explicit list:**
1. Wizard primary CTA button ("Verify & Continue", "Continue", "Save Hotkey")
2. Wizard stage-progress indicator (active dot of three)
3. Focus ring on the currently-focused SwiftUI field (SwiftUI default — do not override)
4. API key validation success checkmark (uses `systemGreen`, NOT accent — keeps accent reserved for interactive affordances)
5. HUD banner's "Open System Settings" link (styled as a `NSColor.linkColor` hyperlink, inherits Accent Color under macOS)

**Accent explicitly NOT used for:**
- Menu-bar icon (must stay template monochrome — D-13)
- Form-field chrome (uses `controlBackgroundColor` / `separatorColor`)
- NSAlert buttons (Apple owns alert chrome)
- Banner dismiss-X button (`secondaryLabelColor`)

**Increase Contrast behavior:** `NSColor.separatorColor` and `NSColor.controlAccentColor` both auto-thicken/auto-darken under Increase Contrast. The arc-reactor glow custom token must fall back to `NSColor.controlAccentColor` when `NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast == true` — asserted by UI test.

**Differentiate Without Color:** inline warnings (hotkey collision) carry an `exclamationmark.triangle.fill` SF Symbol next to the text so color is not the only carrier. Errors carry `xmark.octagon.fill`. Success carries `checkmark.circle.fill`.

---

## Copywriting Contract

Every user-facing string in Phase 1. Voice: calm, respectful, informed. Matches "quiet ambient presence" posture — no exclamation points, no marketing hype, no cuteness. Address the user in second person ("you", never "the user").

### Onboarding Wizard — Stage 1: API Key

| Element | Copy |
|---------|------|
| Window title | Setup — Jarvis |
| Stage progress indicator | 1 of 3: Connect to Claude |
| Display heading (first launch only) | Welcome to Jarvis |
| Heading (return-from-Setup) | Connect to Claude |
| Body | Jarvis uses Anthropic's Claude API for its reasoning. Paste your API key — it's stored in your macOS Keychain and never written to disk in plaintext. |
| SecureField label | Anthropic API key |
| SecureField placeholder | sk-ant-... |
| Helper link label | Get an API key from console.anthropic.com |
| Helper link URL | https://console.anthropic.com/settings/keys |
| Primary CTA (idle) | Verify & Continue |
| Primary CTA (validating) | Checking… |
| Primary CTA (valid) | Continue |
| Inline success | Key verified. |
| Inline error — malformed | That doesn't look like an Anthropic key. Expected prefix `sk-ant-`. |
| Inline error — 401 | Anthropic rejected that key. Double-check it hasn't been rotated or revoked. |
| Inline error — network | Couldn't reach Anthropic. Check your internet connection and try again. |
| Inline error — generic | Something went wrong verifying that key. Details in the system log. |
| Secondary action | Skip for now (disabled on first launch; enabled when re-entered from Setup…) |

### Onboarding Wizard — Stage 2: Permissions (TCC Priming)

Only **Input Monitoring** actually prompts the OS in P1 (D-08). Microphone, Camera, Automation are explainer-only.

| Element | Copy |
|---------|------|
| Stage progress indicator | 2 of 3: Grant Permissions |
| Heading | Grant Permissions |
| Body | Jarvis needs a few system permissions to do its job. Only one is needed right now; the others will ask when the matching feature is added. |
| Input Monitoring row — title | Input Monitoring (needed now) |
| Input Monitoring row — body | Lets Jarvis see a global hotkey press even when another app is focused. Without this, Jarvis only responds when its window is frontmost. |
| Input Monitoring row — CTA idle | Grant Access |
| Input Monitoring row — CTA granted | Granted ✓ |
| Input Monitoring row — CTA denied | Denied — Open System Settings |
| Input Monitoring row — denied helper | Jarvis will run in a reduced mode. You can change this any time in System Settings → Privacy & Security → Input Monitoring. |
| Microphone row — title | Microphone (later) |
| Microphone row — body | Will be requested when the voice loop is turned on. Jarvis will not listen until then. |
| Microphone row — CTA | Learn more → (links to the Voice section of a README or future docs page) |
| Camera row — title | Camera (later) |
| Camera row — body | Will be requested when the vision features are turned on. Jarvis will not watch until then. |
| Camera row — CTA | Learn more → |
| Automation row — title | Automation (later) |
| Automation row — body | Will be requested per-app, the first time Jarvis is asked to automate that app. You'll approve each app individually. |
| Automation row — CTA | Learn more → |
| Primary CTA | Continue |
| Skip CTA | Skip — I'll grant this later |

### Onboarding Wizard — Stage 3: Hotkey Binding

| Element | Copy |
|---------|------|
| Stage progress indicator | 3 of 3: Bind Your Hotkey |
| Heading | Bind Your Hotkey |
| Body | Pick a keyboard shortcut to summon Jarvis from anywhere. You can change this any time from the menu bar. |
| Recorder label | Global shortcut |
| Recorder placeholder | Click to record |
| Recorder state — recording | Press keys… |
| Recorder state — recorded | {rendered key-caps} · Clear |
| Collision warning — Cmd+Shift+J | `Cmd+Shift+J` is used by Chrome, Slack, and VS Code. It will work, but those apps won't see the shortcut while Jarvis is bound to it. |
| Collision warning — Option+Space | `Option+Space` is used by Alfred and Raycast. It will work, but those apps won't see the shortcut while Jarvis is bound to it. |
| Collision warning — generic | `{shortcut}` is already used by `{app name}`. It will work, but that app won't see the shortcut while Jarvis is bound to it. |
| Inline error — modifier-only | A shortcut needs at least one regular key. Try adding a letter or number. |
| Inline error — reserved | macOS reserves `{shortcut}`. Pick a different combination. |
| Primary CTA (no shortcut) | Skip for now |
| Primary CTA (shortcut bound) | Save Hotkey |
| Secondary hint | You can also click the menu-bar icon to open Jarvis. |

### Wizard Footer (all stages)

| Element | Copy |
|---------|------|
| Back button | ← Back |
| Back button (stage 1) | (hidden) |

### Menu-Bar Context Menu

| Element | Copy |
|---------|------|
| Setup… | Setup… |
| Setup… keyboard equivalent | (none — discoverable from menu only) |
| Settings… (placeholder, P1-scope stub) | Settings… (disabled, tooltip: "Coming soon") |
| DevOverlay toggle | Show Dev Overlay |
| DevOverlay toggle (active) | Hide Dev Overlay |
| State dump | Copy State Dump |
| State dump (after click) | State dump copied to clipboard. |
| Quit | Quit Jarvis |
| Quit keyboard equivalent | ⌘Q |

### HUD Banner (degraded-mode)

Banner appears in the transparent NSPanel (see Surface 5 below). One banner at a time; queued if multiple conditions.

| Condition | Title | Body | Action (if any) |
|-----------|-------|------|-----------------|
| Input Monitoring denied | Limited hotkey mode | Jarvis can't see global key presses. The hotkey will only work when Jarvis is frontmost. | **Open System Settings** (deep link: `x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent`) · Dismiss |
| Keychain empty (no API key) | No API key configured | Jarvis can't reach Claude until you set up an API key. | **Open Setup** · Dismiss |
| Hotkey bind failed | Hotkey unavailable | Couldn't register your hotkey — another app may have claimed it. Click the menu-bar icon to summon Jarvis. | **Rebind** · Dismiss |
| ollama.base_url rejected | Ollama config rejected | The configured Ollama URL isn't local. Only `127.0.0.1` and `localhost` are allowed. Check `config.json`. | **Reveal config** (opens Finder to app-support dir) · Dismiss |

All banner copy: one short sentence of diagnosis, one short sentence of consequence or path forward. No stack traces, no error codes, no technical jargon not already in the user's vocabulary.

### NSAlert Modals (hard-blockers — app cannot proceed)

All use `NSAlert.Style.critical`.

| Trigger | Title | Message | Primary button | Secondary button |
|---------|-------|---------|----------------|------------------|
| Missing `allow-jit` entitlement | Jarvis can't start | This build is missing a required system entitlement (JIT). The HUD will crash on launch. Reinstall Jarvis or rebuild from source with the correct entitlements. | Quit | Show Details (opens `~/Library/Logs/Jarvis/system.log` in Console.app) |
| Missing `speech-recognition-assets` entitlement | Jarvis can't start | This build is missing a required speech entitlement. Voice features would crash. Reinstall Jarvis or rebuild from source. | Quit | Show Details |
| Entitlement-grep post-build failure at launch | Jarvis can't start | A build verification check failed at launch. The app has been stopped to prevent a crash. | Quit | Show Details |
| `BUS_PROTOCOL_VERSION` mismatch *(P2-owned copy; listed here for continuity)* | Jarvis can't start | The Swift and JavaScript sides of Jarvis are out of sync. Rebuild both. | Quit | Show Details |

### Destructive Action Confirmations

Phase 1 has exactly one potentially-destructive action: **rotating/overwriting an existing Anthropic API key** from Setup re-entry.

| Action | Confirmation copy | Primary button | Secondary button |
|--------|-------------------|----------------|------------------|
| Replace existing API key | Replace your stored API key? The current key will be deleted from Keychain and can't be recovered by Jarvis. | Replace Key | Cancel |

No other destructive actions in P1. (Removing a hotkey binding is not destructive — it just leaves Jarvis unbound.)

---

## Surface Specifications

Seven UI surfaces in P1 scope. Each specifies: layout, component structure, state model, interaction, animation, and accessibility.

---

### Surface 1 — Onboarding Wizard

**Implementation:** Pure SwiftUI window rendered by the app target. AppKit involvement limited to `NSApplication.shared.run` and the window-behavior flags.

**Layout:**
- Window size: **fixed 560 × 440 pt.** Not resizable. Centered on primary screen on first show; position not persisted (wizard is transient).
- Window style: standard macOS title bar (`[.titled, .closable]` — NO miniaturizable, NO resizable). Title: "Setup — Jarvis".
- Internal layout: three stacked regions, top-to-bottom:
  - **Header** (64pt tall): stage-progress indicator (three dots, active dot uses accent), centered.
  - **Body** (fills remaining space): stage content, inset 48pt left/right + 32pt top, 24pt bottom.
  - **Footer** (56pt tall): divider (`separatorColor`), then `[← Back]` left-aligned + `[Primary CTA]` right-aligned, 24pt from divider, 48pt gutters.

**Component structure:**
- `@main` app has a `WindowGroup` with `.windowStyle(.hiddenTitleBar)` *(no — use default: titled)*. Resolved: use default `WindowStyle`; custom title bar is P3 territory.
- Root SwiftUI view: `WizardView`, owns `@State var stage: WizardStage = .apiKey` and `@ObservedObject var state: WizardState` (API key status, TCC status, hotkey binding).
- `WizardHeaderView` renders three `Circle` dots + label.
- `WizardStageAPIKeyView`, `WizardStageTCCView`, `WizardStageHotkeyView` — one per stage, owns its form logic.
- `WizardFooterView` with `Back` + `Primary CTA` buttons. Primary CTA binds to per-stage `canContinue` + `onContinue()` closure.
- Hotkey binding uses `ShortcutRecorderView` (Surface 2).

**State model:**
- `idle` — initial render on a stage. Primary CTA enabled iff stage's `canAdvance()` is true (stage 1: non-empty key; stage 2: always true; stage 3: always true — shortcut is optional).
- `validating` (stage 1 only) — SecureField disabled, spinner beside CTA, CTA label → "Checking…". No Back button available during this state.
- `error` (stage 1 only) — inline error below SecureField. Primary CTA re-enabled to allow retry.
- `granted` (stage 2 Input Monitoring only) — checkmark replaces CTA.
- `denied` (stage 2 Input Monitoring only) — "Denied — Open System Settings" button styled as link-default (not destructive — we don't punish the user for denying).
- `recording` (stage 3 only) — shortcut-recorder accepts next keystroke.

**Interaction:**
- **Keyboard:** Tab/Shift+Tab moves focus in DOM order. Enter triggers primary CTA when it's enabled and focus is in a field that supports default-button behavior. Escape closes wizard **only** if stage 1 is NOT required (i.e., a key is already stored). Otherwise Escape is a no-op (wizard blocks usage). Close button (red traffic-light) behaves identically to Escape.
- **First-launch variant:** wizard is modal-like — `NSWindow.level = .modalPanel`, close button disabled at stage 1 until key stored OR user completes stages.
- **Setup re-entry:** close button enabled at every stage; Escape closes freely.
- **Mouse:** Primary CTA, Back, Skip buttons; TCC row buttons; shortcut-recorder click-to-record; helper link.

**Focus order per stage:**
- Stage 1: [SecureField → Helper link → Primary CTA] (Back hidden)
- Stage 2: [Input Monitoring CTA → Mic Learn More → Camera Learn More → Automation Learn More → Back → Skip → Primary CTA]
- Stage 3: [ShortcutRecorder → Clear → Back → Skip/Save CTA]

**Animation:**
- Stage transition: 200ms cross-fade on body region. Header progress-dot fills the next dot over 200ms (ease-in-out). **Reduce Motion fallback:** instant swap, no fade; dot fill is instant.
- CTA spinner (validating): standard SwiftUI `ProgressView(.circular)` — Reduce Motion does not disable SwiftUI's circular indicator (system decision), accepted.
- Error inline-message appearance: 150ms slide-down + fade. Reduce Motion: instant fade only.

**Accessibility:**
- VoiceOver labels:
  - Wizard window: "Jarvis Setup, step {N} of 3, {stage name}"
  - Stage-progress dots: "Step 1 of 3, Connect to Claude. Completed.", "Step 2 of 3, Grant Permissions. Current.", "Step 3 of 3, Bind Your Hotkey. Not started."
  - SecureField: label "Anthropic API key", help "stored in macOS Keychain"
  - Primary CTA: reads current label ("Verify and Continue", etc.)
  - Inline error: announced as alert (`.accessibilityAddTraits(.isSelected)` via SwiftUI `.alert(...)` — or explicit `AccessibilityNotification.announcement`).
- Full keyboard navigation — no mouse-only paths.
- Focus ring visible (SwiftUI default; do not suppress).
- `@AccessibilityFocused` is set to the first field on stage entry.

---

### Surface 2 — Shortcut-Recorder View

**Implementation decision (Claude's Discretion, D-11):** **Hand-rolled SwiftUI view, not an SPM dependency.** Rationale:
- Adding `sindresorhus/KeyboardShortcuts` adds a transitive dependency for one view used once.
- P1 discretion item (CONTEXT.md §Claude's Discretion) says "pick whichever minimizes dependency count given D-05." No workspace, no Pods; local SPM packages only — in-house avoids a cross-cutting dep.
- The recorder mechanics (capture `NSEvent` via `NSEvent.addLocalMonitorForEvents`, render key-caps, detect collisions) are ~150 LOC.
- `NSEvent.addGlobalMonitorForEvents` (for the actual runtime hotkey) is already committed (CLAUDE.md + RESEARCH-DELTAS). The recorder uses its local-monitor sibling scoped to our own window — same API family, no new dep.

**Location:** Embedded inside `WizardStageHotkeyView` (Surface 1). Also reusable from the future Settings pane (post-P1).

**Layout:**
- Recorder row: 480pt wide × 40pt tall, centered in the wizard body.
- Inside the row (horizontal): [Label "Global shortcut" — left, 140pt wide] · [Capture area — fills] · [Clear button — right, 60pt wide]
- Capture area: rounded rectangle, `NSColor.controlBackgroundColor` fill, 1pt border `NSColor.separatorColor`, 8pt corner radius. Focus ring on `isFocusable`.
- When shortcut is set: renders each modifier + key as individual "key-caps" with 6pt × 2pt interior padding, 4pt corner radius, 1pt border, background `NSColor.controlColor`. Separator "+" between caps, `secondaryLabelColor`.

**Component structure:**
- `ShortcutRecorderView` — SwiftUI `View`.
- `@State private var isRecording: Bool`.
- `@Binding var shortcut: KeyboardShortcut?` where `KeyboardShortcut` is our own `Codable` struct `{ keyCode: UInt16, modifiers: NSEvent.ModifierFlags }`.
- Local `NSEvent` monitor installed in `.onAppear` (for `isRecording == true`), removed in `.onDisappear`.
- `KeyCapView` — renders a single cap.
- `CollisionDetector` — static map of known collisions; consulted on bind. Surface as inline warning `Text` below the row.

**State model:**
- `empty` — placeholder text "Click to record" in capture area. Clear button hidden.
- `recording` — capture area highlighted with accent-color border (2pt). Placeholder text becomes "Press keys…". Clear button hidden. Escape aborts recording (returns to previous state).
- `bound` — key-caps render inside capture area. Clear button visible.
- `warning` — `bound` + inline collision warning text below row.
- `error` — `empty` or previous-bound + inline error below row (modifier-only, reserved).

**Interaction:**
- **Click capture area:** toggles `recording`. Subsequent keystroke captured as shortcut unless it's Escape (aborts) or modifier-only (error).
- **Clear button:** returns to `empty`. No confirmation — clearing is not destructive (not yet saved).
- **Escape during recording:** aborts recording without changing shortcut.
- **Tab during recording:** aborts recording and moves focus (system default Tab wins).

**Animation:**
- Capture area border transition: 100ms ease-in on focus, 100ms ease-out on blur. Reduce Motion: instant.
- Collision warning appearance: fade in over 150ms. Reduce Motion: instant.

**Accessibility:**
- VoiceOver label on capture area: "Global shortcut recorder. {current-state description}."
  - empty: "No shortcut set. Click to record."
  - recording: "Recording. Press the key combination you want to use, or press Escape to cancel."
  - bound: "Shortcut set to {human-readable: 'Command Shift J'}. Double-click to change, or use the Clear button to remove."
- Human-readable shortcut rendering (VoiceOver): modifiers in Apple canonical order (Control, Option, Shift, Command), each spelled out.
- Clear button: label "Clear shortcut".
- Inline warnings: `.accessibilityAddTraits(.isStaticText)` and announce via `AccessibilityNotification.announcement` on appearance.

---

### Surface 3 — Menu-Bar Icon

**Implementation:**
- `NSStatusItem` with `button.image` set to a custom template PDF (or HEIC vector-sourced) asset.
- **Asset format decision (Claude's Discretion):** **Single-resolution PDF vector**, asset-catalog-backed (`Icon-MenuBar-Template.pdf`, `Assets.xcassets/Icon-MenuBar-Template.imageset/Contents.json` with `"template-rendering-intent": "template"` + `"preserves-vector-representation": true`). Rationale: vector PDF scales cleanly to any menu-bar size macOS hands us (22pt default; Retina-scale auto; user zoom auto); HEIC requires multi-resolution export and loses stroke clarity on 2x scaling; SVG requires conversion tooling we don't need. PDF is Apple's canonical template format — used by every Apple-first-party menu-bar app.
- `image.isTemplate = true` is set in code after loading (defense-in-depth against asset-catalog misconfiguration).
- State-driven animation runs on `statusItem.button.layer` via Core Animation (not SwiftUI). Rationale: the button's `layer` is an `NSImageView` layer; Core Animation gives frame-accurate, sub-60fps-cost, and doesn't require maintaining a SwiftUI render graph for a 22pt indicator.

**Arc-reactor silhouette design target:**
- **Structural reference:** Iron Man arc-reactor — three concentric elements on a monochrome canvas:
  - **Outer ring:** 1pt stroke circle at diameter 18pt (leaves 2pt safe area in a 22pt canvas for the menu-bar baseline).
  - **Mid ring:** 0.75pt stroke circle at diameter 12pt.
  - **Inner core:** 0.5pt stroke circle at diameter 4pt, centered. Filled (black/template) at 100%.
  - **Six radial spokes** connecting mid to outer ring, 0.5pt stroke, evenly spaced at 60° intervals. First spoke at 0° (3 o'clock), following spokes at 60°, 120°, 180° (9 o'clock), 240°, 300°.
- **Canvas:** 22pt × 22pt artboard. Optical center (not geometric center) for the concentric arrangement — i.e., center the visual mass, which on a perfect radial symbol equals the geometric center.
- **Baseline:** bottom of outer ring sits 1pt above the 22pt canvas bottom edge (roughly aligns with the cap-height baseline of adjacent menu-bar text/icons in the menu bar). Top of outer ring sits 3pt below the canvas top (menu-bar items visually sit slightly below center).
- **Stroke consistency:** all strokes are uniform-width PDF paths, NOT filled shapes. Template rendering depends on paths being strokes or fills — avoid mixing anti-aliased filled regions with strokes unless the result is a solid silhouette.
- **Monochrome:** pure black on transparent. `image.isTemplate = true` will recolor to the current menu-bar foreground (white/near-white on light menu bar, dark on dark menu bar). Do NOT bake any color into the asset.
- **Readability test at 22pt:** the six spokes must remain individually distinguishable at 1x (Retina 2x renders at 44 physical pixels, easier). If spokes blur into a ring at 1x on a low-DPI display, reduce spoke stroke to 0.4pt or drop to four spokes.

**State model (D-14 mapping):**

| State | Animation |
|-------|-----------|
| `idle` | Static. Layer opacity 1.0, scale 1.0. |
| `listening` | Breathing pulse: scale oscillates 1.0 ↔ 1.04 at ~0.8 Hz (period 1.25s), sine ease. Opacity stays 1.0. |
| `thinking` | Inner ring rotates: the mid-ring's six-spoke layer rotates 360° over 1.5s, linear. Outer + inner-core layers stay static. |
| `speaking` | Outward shimmer: opacity wave from center outward, each of three rings pulses 1.0 → 0.65 → 1.0 in sequence with 150ms phase offset, whole cycle 900ms, ease-in-out. |
| `awaitingConfirmation` | Rhythmic glow: overall opacity oscillates 1.0 ↔ 0.55 at ~1 Hz (period 1s), ease-in-out — higher amplitude than `listening` (which only scales, not opacity, and at lower delta). Readable in peripheral vision without being alarming. No sound (D-15). |

**Transitions:**
- Any state → any state: 150ms crossfade. Technically: new animation begins at t=0 on a fresh CAAnimation layer; old animation's CAAnimation has `removedOnCompletion = false` and is explicitly removed at t=150ms after linearly fading its driving property back to base value.
- Silhouette itself never swaps (D-14). Only transforms/opacities on existing sublayers.

**Reduce Motion fallback:**
- `listening` → static with a 15% opacity subtle "pulse marker" dot overlaid at center-bottom (below the core), 8pt diameter, toggles on/off every 1.25s with 250ms fade. Still signals activity; no continuous motion.
- `thinking` → three small dots (each 2pt) beneath the silhouette, opacity cycles sequentially (dot 1 → dot 2 → dot 3) every 500ms. This reads as "working" without rotation.
- `speaking` → static; opacity pulses the entire icon 1.0 ↔ 0.8 at 0.8s period. No expanding shimmer.
- `awaitingConfirmation` → static at 100% opacity with a persistent 6pt accent-color dot at the top-right corner of the canvas (signals "waiting for you" visually without motion).
- Reduce Motion detected via `NSWorkspace.shared.accessibilityDisplayShouldReduceMotion`; observed via `NSWorkspace.shared.notificationCenter` for `NSWorkspace.accessibilityDisplayOptionsDidChangeNotification`.

**Click behavior (D-16):**
- Left-click (primary): toggles HUD summon/dismiss (same as bound hotkey). `NSStatusItem.button.action` wired to `toggleHUD:` — but only when event's `type == .leftMouseUp` AND modifiers don't include Control. For modifier-control or right-click path, see below.
- Right-click OR Control+click: shows the context menu. Implementation: attach `NSMenu` via `statusItem.menu`, but override — we want right-click to show menu while left-click does NOT. Pattern: leave `statusItem.menu` unset; in the button action, inspect `NSApp.currentEvent` — if `.rightMouseUp` or `.controlKey` modifier, `statusItem.button.performClick(nil)` + `statusItem.popUpMenu(menu)`.
- Drag, double-click: no handlers. Left-click toggles; no drag behavior in P1.

**Accessibility:**
- `statusItem.button.setAccessibilityLabel(_:)` updated on every state transition:
  - `idle` → "Jarvis, idle"
  - `listening` → "Jarvis, listening"
  - `thinking` → "Jarvis, thinking"
  - `speaking` → "Jarvis, speaking"
  - `awaitingConfirmation` → "Jarvis, waiting for your confirmation"
- `statusItem.button.setAccessibilityHelp("Click to summon or dismiss Jarvis. Right-click for more options.")`
- `statusItem.button.setAccessibilityRole(.button)`
- Context menu items: standard AppKit accessibility; no extra work.
- VoiceOver announces state change on transition via `NSAccessibility.post(element:notification:)` with `.announcementRequested`, BUT rate-limited — no announcement more than once per 3s to avoid a `thinking → speaking → thinking` churn spamming VoiceOver.

---

### Surface 4 — Menu-Bar Context Menu

**Implementation:** `NSMenu` attached via right-click / Control+click (see Surface 3). Standard `NSMenuItem`s.

**Items (in order):**
1. `Setup…` — action: open Setup wizard at first unresolved step.
2. `Settings…` — disabled stub (tooltip: "Coming soon"), placeholder for post-P1.
3. `---` separator
4. `Show Dev Overlay` / `Hide Dev Overlay` — action: toggles the DevOverlay. In P1, this menu item exists but the overlay itself is a P4 deliverable — clicking in P1 shows a stub banner: "Dev Overlay lands in Phase 4."
5. `Copy State Dump` — action: writes a JSON snapshot of current app state (API key present?, TCC grants, hotkey, active feature flags, log path) to clipboard; flashes an HUD banner for 2s: "State dump copied to clipboard."
6. `---` separator
7. `Quit Jarvis` — action: `NSApp.terminate(_:)`, keyboard equivalent ⌘Q.

**Interaction:**
- Menu opens on right-click or Control+click on the menu-bar icon.
- Escape closes menu without action.
- Arrow keys navigate items; Enter activates.
- `⌘Q` from anywhere quits (standard macOS — wired via app menu as well).

**Accessibility:**
- AppKit menu accessibility is automatic.
- Ensure `Show Dev Overlay` toggles its own `title` on state change (not just a checkmark) — VoiceOver reads the literal title.

---

### Surface 5 — HUD Banner

**Critical decision (Claude's Discretion):** **The banner uses its OWN floating NSPanel**, distinct from the main HUD panel (Surface 7). Rationale:

1. **Z-order independence:** the main HUD panel appears/disappears on summon. Banners (e.g., Input Monitoring denial) must persist across HUD visibility — they're app-state conditions, not conversation state. A banner attached to the HUD panel would disappear when the user dismisses the HUD, defeating the point.
2. **P3 non-interference:** the main HUD panel is reserved for R3F particle-ring content in P3. A SwiftUI overlay inside that panel would compete for rendering focus with the webview (SwiftUI layers compositing over WKWebView invite z-order and event-routing bugs). A separate panel has its own view hierarchy.
3. **Positioning freedom:** banner lives at a reliable screen position (top-trailing, below menu bar) that doesn't move when user moves the HUD. Strongly preferred for notification-class UI.

**Layout:**
- Banner panel: 360pt wide × variable height (min 72pt, max 160pt based on body length).
- Position: top-trailing corner of the currently-active display, 24pt inset from right edge, 8pt below the system menu-bar height.
- Saved position? No — always derived from current display. If user drags: P1 does NOT support banner dragging. (If requested later, persist per-display.)
- Level: `.floating` — above normal windows, below system alerts and menu.
- Chrome: no title bar, rounded-rect body (12pt corner radius), `NSColor.windowBackgroundColor` background with `NSVisualEffectView` material = `.hudWindow`, 1pt border `NSColor.separatorColor`.
- Leading edge accent stripe: 4pt wide, arc-reactor-glow color (see Color §Custom brand tokens), full banner height.

**Internal layout (horizontal):**
- [Accent stripe — 4pt] · [Content — fills] · [Dismiss × — 24pt × 24pt, top-trailing]
- Content region insets: 16pt left (past the stripe), 16pt right, 12pt top, 12pt bottom.
- Content region (vertical): [Title — headline font, `labelColor`] · 4pt gap · [Body — body font, `secondaryLabelColor`] · 12pt gap · [Action button — if present]

**Component structure:**
- `HUDBanner` — SwiftUI view inside a dedicated `NSPanel` subclass (`HUDBannerPanel`).
- `HUDBannerPanel` is borderless, non-activating (`.nonactivatingPanel`), floating, accepts clicks on controls only (window itself is not movable).
- `HUDBannerCoordinator` (`@MainActor final class`) owns the queue of pending banner conditions. Shows one at a time; next in queue shows on dismiss or on resolution-by-action.

**State model:**
- `hidden` — no banner on screen.
- `showing {BannerContent}` — banner visible with specified content.
- `dismissing` — 200ms fade-out before hiding.

**Per-condition lifecycle:**
- Banner appears when its underlying condition (Input Monitoring denied, Keychain empty, hotkey-bind failure, ollama URL rejected) is true.
- If user dismisses, condition is remembered as "dismissed this launch" — banner does NOT re-appear until next app launch OR until condition resolves and re-triggers (e.g., user grants then re-denies Input Monitoring).
- If user takes the action button (Open System Settings, Open Setup, etc.), banner stays until the condition clears (re-polled), then auto-dismisses.
- Multiple conditions simultaneously: highest-priority first (priority order: Keychain empty > Input Monitoring denied > hotkey-bind failure > ollama URL rejected), others queued.

**Interaction:**
- **Click action button:** invokes the specified action (URL deep-link for System Settings, opens Setup wizard, opens Finder, etc.).
- **Click dismiss ×:** dismisses current banner with 200ms fade. Next queued banner (if any) appears after 300ms pause.
- **Click elsewhere on banner:** no-op (not a drag handle in P1).
- **Keyboard:** banner is non-activating, so it doesn't take keyboard focus on appearance. User can focus it via VoiceOver cursor or by explicitly clicking. Tab inside banner cycles: [Action button → Dismiss]. Escape from within banner dismisses it.

**Animation:**
- Appearance: slide in from right edge (translateX from +40pt to 0) + fade from 0 to 1 over 250ms, ease-out. Reduce Motion: 250ms fade only, no translate.
- Dismissal: fade 1 to 0 over 200ms, ease-in. Reduce Motion: same.
- Queue gap: 300ms between dismissal complete and next appearance.

**Accessibility:**
- Banner panel has role "notification" (macOS 26 system doesn't formally expose this, but we can use `NSAccessibility.Role.group` with a `.accessibilityLabel("Jarvis notification")`).
- On appearance, announce: `AccessibilityNotification.announcement("{Title}. {Body}. {Action label or 'Press Escape or click dismiss to close'}")`.
- Action button: `NSColor.controlAccentColor` tint, full label.
- Dismiss ×: accessibility label "Dismiss notification".
- Increase Contrast: border thickens automatically (`NSColor.separatorColor` is system-managed). Accent stripe color falls back to `NSColor.controlAccentColor`.

---

### Surface 6 — NSAlert Modals (Hard-Blockers)

**Implementation:** Standard `NSAlert` with `.critical` style. No customization beyond copy.

**Trigger path:** Checked at `AppDelegate.applicationWillFinishLaunching(_:)`:
1. Parse running binary's embedded entitlements via `codesign -d --entitlements - <path>` OR at build time via a post-build script that writes the entitlement status into the Info.plist as a boolean key (`JarvisEntitlementsVerified`). At runtime, read that key; if false or missing, raise NSAlert.
2. Before `NSApp.run()`, ensure all blocking checks passed. If any failed, `NSApp.terminate(_:)` after user clicks Quit.

**Scaffold-time verification harness mechanic (Claude's Discretion):**
- Entitlement load-bearing probe (STATE.md scaffold-time verification) runs as a **shell script under `scripts/verify-entitlements.sh`** that:
  1. Takes a Release-archived `.app` bundle path.
  2. Uses `codesign -d --entitlements -` to extract entitlements.
  3. Greps for `com.apple.security.cs.allow-jit` and `com.apple.developer.speech-recognition-assets`.
  4. Exits non-zero on missing.
- The "confirms `SFSpeechErrorCode.assetUnavailable` fires without the speech entitlement" side of the probe runs as a separate **one-shot XCTest target** (`JarvisEntitlementProbeTests`) that is excluded from the default test plan — invoked manually or by a CI job against a specifically-prepared build variant with the entitlement stripped. Rationale: this test MUST run on a Release archive, not a Debug build — XCTest against a Debug app won't reproduce the Release-only crash path.
- Both the shell script and the one-shot XCTest belong to P1's deliverables and must run green at least once before P1 is declared complete.

**Copywriting:** See Copywriting Contract — "NSAlert Modals (hard-blockers)".

**Interaction:**
- Primary button: "Quit" — calls `NSApp.terminate(_:)` after alert dismisses.
- Secondary button: "Show Details" — opens `~/Library/Logs/Jarvis/system.log` in Console.app via `NSWorkspace.shared.open(URL(fileURLWithPath: logPath))`. Alert re-shows after details inspection? No — closing Console does not redisplay; user must restart Jarvis to re-trigger. This is intentional: the alert is a warning, not a modal loop.

**Accessibility:**
- NSAlert handles accessibility natively. VoiceOver reads title, message, and button labels.
- Critical style carries a system alert sound that respects System Settings → Sound → Alert sound volume.

---

### Surface 7 — Borderless Transparent NSPanel (HUD Skeleton)

**Phase 1 scope:** The NSPanel exists. It hosts a blank WKWebView (which in P3 will load the R3F bundle). P1 does not render R3F content — at most, for developer-visibility, the WKWebView loads a local HTML stub that says "HUD loading — Phase 3" (optional; may also stay transparent). P1's responsibility is to get the panel's **geometry, chrome, positioning, and dismissal mechanics right** so P3 lands cleanly.

**Implementation:**
- Custom `NSPanel` subclass: `JarvisHUDPanel`.
- WKWebView fills content view, constrained edge-to-edge.
- Panel created at app launch, initially hidden (`orderOut(_:)`).
- Summoned by global hotkey OR by left-click on menu-bar icon.

**Layout and chrome:**
- Panel size: **720 × 720 pt** (square canvas for the future ring). Not resizable.
- Position: centered on the currently-active display (the display containing the mouse cursor at summon time). Not saved per-display in P1 — fresh center on each summon.
- Panel style flags:
  - `styleMask = [.borderless, .nonactivatingPanel]`
  - `level = .statusBar`
  - `isMovableByWindowBackground = true` (user can drag the whole panel to reposition)
  - `collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]` — appears on all Spaces including full-screen apps, recognized as transient UI by macOS 26 Tahoe's window manager.
  - `hasShadow = false` (the ring itself handles visual prominence in P3; no native shadow)
  - `backgroundColor = .clear`
  - `isOpaque = false`
  - `titleVisibility = .hidden`
  - `hidesOnDeactivate = false` (so the panel stays visible when user focuses another app — required for ambient presence posture)
- WKWebView:
  - `isOpaque = false`
  - `backgroundColor = .clear` (NSColor), `underPageBackgroundColor = .clear`
  - `setValue(false, forKey: "drawsBackground")` (private key — needed in practice to force transparent backing on macOS 26 Tahoe even with isOpaque=false)
  - Configuration: default `WKWebViewConfiguration`. No JS bridge yet (that's P2). No content loaded in P1 unless we ship the "HUD loading — Phase 3" stub.
  - Fills panel: constrained `top = bottom = leading = trailing = 0` with respect to the content view.

**State model:**
- `hidden` — panel is `orderOut(_:)`-ed, not on any screen.
- `summoned` — panel is `orderFrontRegardless()`-ed, visible on the active display.
- Transition via `summon()` and `dismiss()` methods on `JarvisHUDPanel`.

**Interaction:**
- **Summon triggers:** bound global hotkey (if set) OR left-click on menu-bar icon. Re-triggering the same summon-gesture while summoned: dismisses. (Symmetric toggle.)
- **Dismissal triggers:**
  - Re-press of bound global hotkey → dismiss.
  - Left-click on menu-bar icon → dismiss.
  - **Escape key** while panel is focused → dismiss. P1 requirement: even without a focused field, pressing Escape while the panel is keyWindow dismisses. Implementation: override `cancelOperation(_:)` on the panel OR install a local `NSEvent` monitor for `.keyDown` with `keyCode == 53` while panel is keyWindow.
  - **Click-outside:** P1 behavior → **no dismissal on click-outside.** Rationale: `.nonactivatingPanel` means the panel doesn't steal focus, so "outside" clicks go to whatever app has focus; trying to observe them requires Accessibility APIs we don't have. User has three explicit dismiss affordances; click-outside dismissal is a later refinement if desired.
  - **⌘W** while keyWindow → dismiss (standard macOS expectation for a document-style window).

**Animation:**
- Summon: fade in over 180ms with scale 0.96 → 1.0 (ease-out). The scale gives a subtle "materialize" feel aligned with Iron Man's holographic-appear aesthetic. Reduce Motion: fade only, 180ms.
- Dismiss: fade out over 140ms with scale 1.0 → 0.98 (ease-in). Reduce Motion: fade only, 140ms.
- These animations apply to the content layer, not the panel's window-level animator (which on macOS is finicky with transparent windows). Use `contentView.animator()` or explicit `CABasicAnimation` on the content view's layer.

**Accessibility:**
- Panel accessibility label: "Jarvis HUD". Role: `.window` (AppKit default for `NSPanel`).
- In P1 the panel is mostly empty — VoiceOver cursor can enter it but finds only the transparent webview. Announce on summon: `AccessibilityNotification.announcement("Jarvis opened")`.
- Announce on dismiss: `AccessibilityNotification.announcement("Jarvis dismissed")`.
- Focus on summon: not auto-focused — leaves focus on the previously-focused app (ambient-presence posture). VoiceOver users can Tab into the panel if needed.
- Reduce Transparency (`NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency == true`): fall back to `NSColor.windowBackgroundColor` at 95% opacity instead of full clear. P1 must honor this — critical for users who find transparent panels hard to perceive.
- Increase Contrast: add a 1pt `NSColor.separatorColor` border around the content view when active. (Arguably undesirable under the "transparent floating HUD" aesthetic, but accessibility wins over aesthetic per macOS HIG.)

---

## Registry Safety

| Registry | Blocks Used | Safety Gate |
|----------|-------------|-------------|
| n/a | n/a | n/a — no component registry used in Phase 1 (no React, no shadcn, no third-party UI SPM beyond stdlib) |

Third-party SPM dependencies in P1: **none.** All UI is SwiftUI + AppKit stdlib. The only external packages in P1 are `apple/swift-log 1.5.3+` (logging, non-UI) and whatever Config/Shell packages require for non-UI plumbing. No external UI-layer code enters the app — the shortcut recorder is hand-rolled (see Surface 2 decision), eliminating `sindresorhus/KeyboardShortcuts` as a consideration.

---

## Cross-Surface Interaction Summary

| Event | Source | Target surface(s) | Behavior |
|-------|--------|---------------------|----------|
| Bound hotkey pressed | Global `NSEvent` monitor | Surface 7 | Toggle HUD panel summon/dismiss |
| Menu-bar left-click | Surface 3 | Surface 7 | Toggle HUD panel summon/dismiss |
| Menu-bar right/Ctrl-click | Surface 3 | Surface 4 | Show context menu |
| Input Monitoring TCC denied | `IOHIDRequestAccess` probe | Surface 5 | Enqueue banner: "Limited hotkey mode" |
| API key stored in Keychain | Surface 1 stage 1 | Surface 5 | Resolve & dismiss "No API key configured" banner (if present) |
| "Setup…" menu item | Surface 4 | Surface 1 | Open wizard at first unresolved step |
| Wizard completed | Surface 1 | Surface 7 | No direct open — user must summon via hotkey or menu-bar click |
| Entitlement grep failure at launch | `applicationWillFinishLaunching` | Surface 6 | Show blocking NSAlert, terminate on Quit |
| Escape on HUD panel | Panel key-event | Surface 7 | Dismiss panel |
| Escape on banner | Banner key-event (when focused) | Surface 5 | Dismiss current banner, show next queued |
| Escape on wizard | Wizard key-event | Surface 1 | Close wizard if non-blocking; no-op if stage 1 first-launch |

---

## Asset Inventory (for planning)

Files the planner must create:

| Asset | Path | Format | Owner |
|-------|------|--------|-------|
| Menu-bar icon (template) | `App/Assets.xcassets/Icon-MenuBar-Template.imageset/` | PDF vector (1x slot), template-rendering-intent=template, preserves-vector-representation=true | Designer / hand-authored SVG → PDF export via Inkscape or Illustrator. Designed to spec in Surface 3. |
| App icon | `App/Assets.xcassets/AppIcon.appiconset/` | PNG standard multi-resolution | Separate asset — NOT the template icon. Required by macOS. May defer full design to post-P1 via a simple placeholder (filled blue circle with white "J" — SF Pro Semibold), with explicit ticket for final art. |
| Accent color (optional override) | `App/Assets.xcassets/AccentColor.colorset/` | NSColor with light/dark variants | P1 does NOT override accent color — defers to system Accent Color. User-chosen Accent Color via System Settings applies throughout. |
| Arc-reactor glow color | Swift constant `BrandColor.arcReactorGlow` | Code-defined, light/dark variants (see Color §Custom brand tokens) | Hand-coded in `App/Theme/BrandColors.swift`. |

---

## Checker Sign-Off

- [x] Dimension 1 Copywriting: PASS
- [x] Dimension 2 Visuals: PASS
- [x] Dimension 3 Color: PASS
- [x] Dimension 4 Typography: PASS
- [x] Dimension 5 Spacing: PASS
- [x] Dimension 6 Registry Safety: PASS

**Approval:** approved by gsd-ui-checker on 2026-04-22 (no FLAGs, no revisions required)

---

## Open Items for Planner

Not decisions — hand-offs. The planner should turn each of these into a concrete plan or task:

1. **Arc-reactor silhouette asset production** — commission or hand-author a 22pt × 22pt PDF vector matching the structural spec in Surface 3. Ship a placeholder (simple concentric-circle silhouette) if final art isn't ready by P1 scaffold — the animation contract works on any compliant concentric silhouette.
2. **App icon (AppIcon.appiconset)** — placeholder is acceptable for P1; flag a ticket for real art post-P1.
3. **ShortcutRecorder implementation** — hand-rolled per Surface 2 decision. Target ~150 LOC.
4. **HUD banner panel (HUDBannerPanel)** — net-new NSPanel subclass; write an autolayout-based SwiftUI hosting view.
5. **JarvisHUDPanel** — NSPanel subclass with the specified style mask, collection behavior, and transparency configuration. Include Reduce Transparency fallback.
6. **AppDelegate entitlement-grep check** — on `applicationWillFinishLaunching`, verify the build-time-written `JarvisEntitlementsVerified` Info.plist boolean; on failure, show NSAlert from Surface 6.
7. **`scripts/verify-entitlements.sh`** — shell script per Surface 6 scaffold-time verification harness mechanic.
8. **`JarvisEntitlementProbeTests`** — one-shot XCTest target for the SFSpeechErrorCode.assetUnavailable probe. Excluded from default test plan; invoked explicitly.
9. **Accessibility audit pass** — at plan completion, walk every surface with VoiceOver, Reduce Motion, Reduce Transparency, and Increase Contrast all enabled. Each surface must render intelligibly and be operable in each mode.
10. **Animation utility** — a small helper for `CABasicAnimation`-driven transitions on the menu-bar button layer (Surface 3). Must consult `accessibilityDisplayShouldReduceMotion` and emit fallback animations.

---

*Phase 1 UI-SPEC authored: 2026-04-22*
*Status: draft — pending gsd-ui-checker sign-off.*
