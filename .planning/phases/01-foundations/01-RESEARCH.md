# Phase 1: Foundations — Research

**Researched:** 2026-04-22
**Domain:** macOS native host scaffolding — Xcode project, entitlements, codesign layout, Keychain, structured logging, config substrate, first-launch wizard, menu-bar icon animation, scaffold-time verification harness
**Confidence:** HIGH on every settled decision; MEDIUM on the `speech-recognition-assets` load-bearing claim (explicitly flagged for scaffold-time verification — this is a known RESEARCH-DELTAS carry-over, not a new risk); MEDIUM on the single `SpeechAnalyzer` init-failure probe path (Apple docs ambiguous on whether init throws synchronously).

---

## Summary for Planner

One bullet per major decision, in the order the planner will need them:

1. **SPM packages** — `packages/Config`, `packages/Logging`, `packages/Shell`, plus a tiny `packages/Keychain` wrapper. Swift 6 strict concurrency on every package (D-04). **No workspace, no CocoaPods.**
2. **Keychain** — use `Security.framework` directly (~60 LOC). `KeychainAccess` SPM is well-maintained but low-maintenance-activity and would add an SPM dep for one use site. D-05 (minimize SPM deps) tips the balance. Swift 6 strict concurrency is a second reason — raw `SecItem*` calls are trivially `Sendable`.
3. **swift-log wiring** — `LoggingSystem.bootstrap(JarvisLogHandlerFactory.make)`. Factory returns a `MultiplexLogHandler` composing (a) `FileLogHandler` (hand-rolled, ~80 LOC — daily-rotate + retain-7, no community SPM pulled in) and (b) `OSLogHandler` wrapping `os.Logger(subsystem: "com.kingsrook.jarvis", category: <label>)`. The four channels are just four `Logger(label:)` call sites — not a custom enum.
4. **`redact()`** — single function in `packages/Logging/Sources/Logging/Redact.swift`. Implemented as a single precompiled `NSRegularExpression` with 5 alternation branches (Anthropic `sk-ant-*`, OpenAI `sk-*`, `Authorization: Bearer …`, `AKIA*`, `ghp_*`). Hooks in via a message-transforming wrapper on `FileLogHandler` only — the `os.Logger` handler already benefits from Apple's own redaction of `%{private}@` fields and we use `%{public}` sparingly.
5. **Codesign script** — `scripts/codesign.sh` is a short bash script invoked as an Xcode "Run Script" phase at position **after** "Copy Bundle Resources" and **after** "Embed Helpers" (if any). Walks `Contents/Helpers/**/*.app` deepest-first with `find … -depth`, signs each with its own `.entitlements`, then signs the main `.app` last. **Never `--deep`. Never "Code Sign On Copy".** Uses `${OTHER_CODE_SIGN_FLAGS}` = `--options=runtime --timestamp` on every sign call. A second script `scripts/verify-entitlements.sh` runs right after and greps required entitlements out of each signed bundle; non-zero exit fails the build.
6. **SpeechAnalyzer load-bearing probe** — a one-shot XCTest target (`JarvisEntitlementProbeTests`, excluded from the default test plan) plus the shell script above. The XCTest instantiates `SpeechTranscriber(locale: Locale(identifier: "en-US"), preset: .progressiveLiveTranscription)` and attempts `AssetInventory.status(forModules: [transcriber])` — if the entitlement is absent, this throws `SFSpeechErrorCode.assetUnavailable` (or the macOS 26 equivalent code 10 / `Cannot use modules with unallocated locales`). Probe is **gated on a build flag** `JARVIS_ENTITLEMENT_PROBE=1` so it only runs on explicit CI invocation or a locally-prepared stripped-entitlement archive. **This is the P1 scaffold-time verification (STATE.md row).**
7. **`LaunchSnapshot` / `PerTurnSnapshot`** — two `Sendable` structs, `Codable`. Config pipeline parses `config.json` once at launch; `LaunchSnapshot` is frozen (`let`), `PerTurnSnapshot` is published via an actor. `submit()` re-reads `PerTurnSnapshot`. Mutating a launch key at runtime is detected by diffing on file-watch and surfaces an NSAlert: "Change requires restart." Malformed config → NSAlert hard-block (D-19).
8. **config.json schema versioning** — embedded `"schemaVersion": <int>` key at the top level. Decode `{ schemaVersion: Int }` first, dispatch to one of N `Migration` functions (`v1 → v2`, `v2 → v3`, etc.), then decode the final current-version struct. P1 ships at `schemaVersion: 1` with zero migrations. Adding a migration later is ~15 LOC and a compile-time test.
9. **Menu-bar icon animation** — `statusItem.button?.wantsLayer = true`; set `layer.anchorPoint = CGPoint(x: 0.5, y: 0.5)`; adjust `layer.frame` defensively to preserve position (anchorPoint change moves the layer unless you re-anchor). Use a child `CALayer` carrying the PDF template image as contents so `wantsLayer` on the button doesn't replace the template-rendered drawing. Crossfade between animations uses `CATransition(type: .fade)` on the child layer; all five states (idle / listening / thinking / speaking / awaitingConfirmation) add/remove named animations on the same `CALayer`. Known gotcha: `layer.contents = nsImage` does NOT render as template — solved by letting AppKit draw the image into the button (the default path) and layering animations on top (modify `transform` / `opacity` only, not `contents`).
10. **Shortcut recorder** — hand-rolled SwiftUI, ~150 LOC (matches UI-SPEC Surface 2 decision). Pattern mirrors `sindresorhus/KeyboardShortcuts` internal shape: an `NSViewRepresentable` wrapping a custom `NSView` whose `becomeFirstResponder` returns true, installs `NSEvent.addLocalMonitorForEvents([.keyDown, .flagsChanged])`, captures `keyCode: UInt16` + `modifierFlags & .deviceIndependentFlagsMask`, rejects modifier-only & Shift-only, Escape exits recording.
11. **Global hotkey at runtime** — `NSEvent.addGlobalMonitorForEvents(matching: .keyDown)` for the summon hotkey; `NSEvent.addLocalMonitorForEvents` as the degraded-mode fallback. Probe Input Monitoring via `IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)` at app launch + on first hotkey registration; denial → HUD banner per UI-SPEC Surface 5.
12. **Launch-at-login** — `SMAppService.mainApp.register()` / `.unregister()` (macOS 13+; current on macOS 26). Opt-in from wizard (unchecked by default). Handle the four status codes: `.enabled` (success), `.requiresApproval` (show System Settings deep link), `.notRegistered` (not yet registered), `.notFound` (error — log to system channel). `SMLoginItemSetEnabled` is deprecated; do not use.
13. **Entitlements file** — `Jarvis.entitlements` pinned with `com.apple.security.cs.allow-jit`, `com.apple.developer.speech-recognition-assets`, `com.apple.security.device.audio-input` (pre-pinned for P6); **no** `com.apple.security.cs.allow-unsigned-executable-memory` (MLX doesn't need it per R2-S4), **no** `com.apple.security.automation.apple-events` (that moves to `Contents/Helpers/mcp-applescript.app/Contents/Resources/mcp-applescript.entitlements` in P5). Info.plist pins `NSSpeechRecognitionAssetsUsageDescription`, `LSUIElement=YES`.
14. **Validation architecture (Nyquist)** — each of the 17 P1 requirements maps to ≥2 test angles (happy + adversarial). Scaffold-time probes (entitlement grep + SpeechAnalyzer init) are the sharpest; every other req gets an XCTest unit + one shell/CI hook.
15. **Scripts inventory (P1 deliverables)** — `scripts/codesign.sh`, `scripts/verify-entitlements.sh`, `scripts/build-webview.sh` (stub; real build lands in P3), `scripts/prime-tcc.sh` (stub for Input Monitoring probe; becomes meaningful in P6 when Mic/Camera arrive). `check-plist-parity.sh`, `verify-models.sh`, `verify-fixtures.sh`, `check-bus-protocol-version.sh` are **non-P1** (P2/P6/P8 scope) — include placeholder empty scripts only if the planner wants a single-source-of-truth inventory; otherwise defer.

---

## User Constraints (from CONTEXT.md)

### Locked Decisions (from D-01 through D-20 — reproduced verbatim for the planner)

**SPM Package Layout**

- **D-01:** Local SPM packages under `packages/` split per subsystem. Initial packages (add only as phases land, do NOT pre-create empty ones): `Config`, `Logging`, `Shell`. Later phases add `Bus` (P2), `LLM` (P4), `MCP` (P5), `Voice` (P6), `Memory` (P7).
- **D-02:** App target is **lifecycle + wiring only**. If a file is not mounting a window, starting an actor, or routing a delegate callback, it belongs in a package.
- **D-03:** Each package defines its own `testTarget` in its `Package.swift`. Per-package isolation. Framework (XCTest vs swift-testing) at package author's discretion.
- **D-04:** Every package opts into Swift 6 strict concurrency from day one (`.swiftLanguageMode(.v6)`). Data-race errors are compile-time failures.
- **D-05:** Xcode project shape is `.xcodeproj` + local SPM packages — **no Xcode workspace, no CocoaPods.**

**First-launch Onboarding**

- **D-06:** First-launch is a blocking wizard rendered in a native SwiftUI window. Three sequential stages: API key → TCC priming → hotkey binding.
- **D-07:** Stage order is API key → TCC → hotkey.
- **D-08:** TCC priming in Phase 1 only fires **Input Monitoring**. Microphone/Camera/Automation are explainer-only pages.
- **D-09:** Wizard is re-openable from the menu-bar "Setup…" item. Stateless — re-reads current state on each open.
- **D-10:** API key entry via native SwiftUI `SecureField`. Validated by live Anthropic `models/list` probe before advancing. Lands in Keychain at `com.kingsrook.jarvis.anthropic`.
- **D-11:** Hotkey binding via shortcut-recorder view (planner picks hand-rolled vs SPM). Ships unset.
- **D-12:** Input Monitoring denial transitions to local-monitor-only degraded mode + persistent HUD banner with System Settings deep link.

**Menu-bar Icon State Design**

- **D-13:** Base icon is a custom template image (PDF vector) with `image.isTemplate = true`.
- **D-14:** State distinguished by subtle animation on a constant silhouette — NOT icon swaps. idle / listening (0.8 Hz breath) / thinking (1.5 s rotate) / speaking (shimmer) / awaitingConfirmation (1 Hz glow). Crossfade transitions ~150 ms.
- **D-15:** `awaitingConfirmation` is attention-grabbing but not alarming. No sound.
- **D-16:** Left-click toggles HUD summon/dismiss. Right-click / Ctrl+click shows context menu.

**Observability Surface**

- **D-17:** `apple/swift-log 1.5.3+` wires TWO handlers simultaneously: (a) file handler to `~/Library/Logs/Jarvis/{channel}.log` and (b) `os.Logger` with `subsystem = "com.kingsrook.jarvis"`, `category = {channel}`.
- **D-18:** File log rotation: daily at local midnight, retain last 7 days. Each channel rotates independently.
- **D-19:** First-launch failure severity tiers: NSAlert modal (missing `allow-jit`, missing `speech-recognition-assets`, entitlement-grep failure) → HUD banner (Input Monitoring denial, Keychain empty, hotkey-bind failure, `ollama.base_url` rejected) → structured log only.
- **D-20:** `redact()` covers **exactly** OBS-06 spec minimum: API keys (Anthropic `sk-ant-*`, OpenAI `sk-*`), `Authorization: Bearer <token>`, `AKIA*`, `ghp_*`. Nothing more.

### Claude's Discretion (resolved in this research — copied from CONTEXT.md verbatim)

The following items were discretionary at CONTEXT time; this research resolves each:

- **Asset format for menu-bar template icon** — resolved in UI-SPEC: single-resolution PDF vector.
- **Shortcut-recorder implementation approach** — resolved in UI-SPEC + this research: hand-rolled SwiftUI, ~150 LOC.
- **Animation easing curves / frame rates** — resolved in UI-SPEC Surface 3.
- **SwiftUI vs AppKit split within wizard** — SwiftUI forms + AppKit window hosting (resolved in UI-SPEC Surface 1).
- **Directory layout under `packages/`** — flat (one directory per package name, matching their module name). See Architecture Patterns §Recommended Project Structure below.
- **Scaffold-time verification harness mechanic** — resolved in this research: shell script (`verify-entitlements.sh`) + one-shot XCTest (`JarvisEntitlementProbeTests`) — see §Question 4.
- **File-handler implementation for log rotation** — resolved in this research: hand-rolled ~80 LOC. No community SPM backend (Puppy, swift-log-file, etc.) — see §Question 3.
- **config.json schema versioning approach** — resolved in this research: embedded `schemaVersion` integer + explicit migration functions — see §Question 6.

### Deferred Ideas (OUT OF SCOPE)

- config.json schema detail beyond the Launch/PerTurn split — researcher resolves mechanical minimum (Question 5) but anything beyond that is planner scope.
- Specific codesign script language/location — this research resolves as `scripts/codesign.sh` (bash, POSIX).
- DevOverlay UI — P4 deliverable, not P1.
- Ambient corner mode / "always-there" minimized ring — v1.x deferred.
- Settings UI beyond wizard + Quit — later phase.
- Telemetry / crash reporting service — not in v1 scope.

---

## Phase Requirements

| ID | Description | Research Support |
|----|-------------|------------------|
| SHELL-01 | Menu-bar item always present | UI-SPEC Surface 3 (implementation); §Question 7 (animation mechanics) |
| SHELL-02 | Global hotkey via first-launch shortcut-recorder UI; ships unset | §Question 8 (shortcut recorder); §Question 11 (NSEvent runtime monitors — Summary bullet 11) |
| SHELL-03 | Borderless transparent always-on-top NSPanel; LSUIElement=YES; launch-at-login opt-in | UI-SPEC Surface 7; §Question 9 (SMAppService) |
| SHELL-04 | Hardened Runtime + `allow-jit` day one | Standard Stack §Entitlements; Pitfalls §1 |
| SHELL-05 | `speech-recognition-assets` entitlement + `NSSpeechRecognitionAssetsUsageDescription` | §Question 4 (probe mechanic); Standard Stack §Entitlements |
| SHELL-06 | Input Monitoring TCC denial surfaces HUD banner + System Settings deep link; fallback to local-monitor-only | Summary bullet 11; UI-SPEC Surface 5 |
| AGENT-05 | `ollama.base_url` constrained at config load to 127.0.0.1/localhost only | §Question 5 (Launch/PerTurn snapshots) — must be in LaunchSnapshot with URL-host validator |
| MCP-05 | `Contents/Helpers/` directory layout scaffolded (empty but structurally correct) | §Question 2 (codesign script); Standard Stack §Bundle Layout |
| MCP-06 | Codesign deepest-first; no `--deep`; no "Code Sign On Copy"; post-build entitlement-grep phase | §Question 2 |
| OBS-05 | Feature flags substrate toggleable without rebuild; live in ONE snapshot | §Question 5 — placed in `PerTurnSnapshot` (non-security); feature flags are risk-ops not security-ops |
| OBS-06 | Structured logs via swift-log 1.5.3+; four channels; single `redact()` | §Question 3; Summary bullet 4 |
| SEC-01 | Anthropic API key Keychain round-trip via native SwiftUI SecureField | §Question 1 (Security.framework); UI-SPEC Surface 1 stage 1 |
| SEC-02 | Hardened Runtime + `allow-jit` (same as SHELL-04 from security framing) | Standard Stack §Entitlements |
| SEC-03 | `speech-recognition-assets` entitlement (same as SHELL-05 from security framing); capability on App ID too | §Question 4; §Open Questions — App ID capability enable step is a human action, not a code change |
| SEC-04 | Incremental TCC prompting (P1 only prompts Input Monitoring per D-08) | UI-SPEC Surface 1 stage 2 |
| SEC-05 | LaunchSnapshot vs PerTurnSnapshot config split; feature flags in one-not-both | §Question 5 |
| SEC-08 | No AppleScript skip-allowlist exists | Standard Stack §Forbidden knobs — guarded by unit test in `packages/Config` that fails if `applescript.skipAllowlist` key is present anywhere |

---

## Architectural Responsibility Map

| Capability | Primary Tier | Secondary Tier | Rationale |
|------------|-------------|----------------|-----------|
| Menu-bar item + icon state animation | AppKit host (app target) | — | `NSStatusItem` is native-only; SwiftUI has no first-class equivalent that preserves template rendering on macOS 26. |
| Onboarding wizard UI | SwiftUI (app target) | — | Pure form UI; SwiftUI `SecureField` + `Form` is cleaner than AppKit. Hosted inside an AppKit `NSWindow` via `NSHostingController`. |
| Global hotkey runtime | AppKit host (app target) | Shell package | `NSEvent.addGlobalMonitorForEvents` is AppKit API; registration/unregistration logic sits in `packages/Shell` as a testable service. |
| HUD panel skeleton | AppKit (app target) | WKWebView (app target) | `NSPanel` subclass + `WKWebView` content view; no content logic in P1 (P3 lands R3F). |
| Structured logging (production logging surface) | `packages/Logging` | os.Logger (system) + file (disk) | Package owns `LogHandler` conformance; the two concrete backends are implementation detail of the package. |
| Config load + snapshot split | `packages/Config` | Disk (`~/Library/Application Support/Jarvis/config.json`) | Pure parse/validate logic; no UI. App target injects snapshots into dependent actors. |
| Keychain I/O | `packages/Keychain` (new, ~60 LOC) | System (`Security.framework`) | Thin wrapper that exposes `set(String, forKey: String) throws` / `get(forKey:)` / `delete(forKey:)`. |
| Codesign script execution | Build-time (Xcode Run Script phase) | — | Not a runtime component — runs at build. |
| Entitlement verification at runtime | App target (`AppDelegate.applicationWillFinishLaunching`) | — | Reads Info.plist `JarvisEntitlementsVerified` boolean written at build time; NSAlert hard-block if false. |

---

## Answers to the 10 Planner Questions

### Question 1 — Keychain API choice

**Recommendation: `Security.framework` raw (via a thin `packages/Keychain` wrapper).**

| Criterion | `Security.framework` raw | `KeychainAccess` SPM |
|-----------|-------------------------|---------------------|
| LOC to wrap | ~60 LOC for set/get/delete | `import KeychainAccess` + 3 call sites |
| SPM dep count | 0 | +1 (with no transitive deps) |
| Swift 6 strict concurrency | Trivially `Sendable` (raw `SecItem*` is C) | `KeychainAccess` is actively maintained but its last release activity is older than 6 months; strict-concurrency audit status unclear |
| Error ergonomics | `OSStatus` → own error enum (~15 LOC translation) | Typed errors built-in |
| Testability | Inject protocol + in-memory fake | Same; lib provides no test double itself |
| Alignment with D-05 | ✓ Minimize SPM deps | ✗ Adds a dep for one use site |
| Keyed values we need in P1 | ONE — the Anthropic API key | ONE — the Anthropic API key |

Decision: **raw.** The wrapper lives in `packages/Keychain/Sources/Keychain/Keychain.swift`:

```swift
// ~60 LOC, illustrative
import Foundation
import Security

public struct KeychainItem: Sendable {
    public let service: String
    public let account: String
    public init(service: String, account: String) {
        self.service = service
        self.account = account
    }
}

public enum KeychainError: Error, Sendable {
    case itemNotFound
    case duplicateItem
    case unexpectedStatus(OSStatus)
}

public protocol KeychainStore: Sendable {
    func set(_ value: String, for item: KeychainItem) throws
    func get(_ item: KeychainItem) throws -> String
    func delete(_ item: KeychainItem) throws
}

public struct SystemKeychainStore: KeychainStore {
    public init() {}

    public func set(_ value: String, for item: KeychainItem) throws {
        let data = Data(value.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: item.service,
            kSecAttrAccount as String: item.account,
        ]
        // Try update first, then add; idempotent overwrite.
        let attrs: [String: Any] = [kSecValueData as String: data]
        let updateStatus = SecItemUpdate(query as CFDictionary, attrs as CFDictionary)
        if updateStatus == errSecSuccess { return }
        if updateStatus != errSecItemNotFound {
            throw KeychainError.unexpectedStatus(updateStatus)
        }
        var addQuery = query
        addQuery[kSecValueData as String] = data
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw KeychainError.unexpectedStatus(addStatus)
        }
    }

    public func get(_ item: KeychainItem) throws -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: item.service,
            kSecAttrAccount as String: item.account,
            kSecReturnData as String: kCFBooleanTrue as Any,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data, let s = String(data: data, encoding: .utf8) else {
                throw KeychainError.unexpectedStatus(status)
            }
            return s
        case errSecItemNotFound:
            throw KeychainError.itemNotFound
        default:
            throw KeychainError.unexpectedStatus(status)
        }
    }

    public func delete(_ item: KeychainItem) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: item.service,
            kSecAttrAccount as String: item.account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unexpectedStatus(status)
        }
    }
}
```

Use site (app target, during wizard stage 1): `try keychain.set(apiKey, for: .anthropic)` where `.anthropic = KeychainItem(service: "com.kingsrook.jarvis", account: "anthropic")`.

**Fetch-per-request pattern** (Pitfalls §Security): `AnthropicProvider` does NOT cache the key. `URLSession.dataTask` reads it via `store.get(.anthropic)` on each `stream()` call. Slight overhead; correct TCC posture.

**Sources (consulted):** [Apple Security framework — SecItemAdd / SecItemCopyMatching docs](https://developer.apple.com/documentation/security/keychain_services/keychain_items); [`kishikawakatsumi/KeychainAccess` README — for comparison only, not used](https://github.com/kishikawakatsumi/KeychainAccess).

---

### Question 2 — Codesign script mechanics for `Contents/Helpers/`

**Approach:** bash script `scripts/codesign.sh` invoked from an Xcode "Run Script" phase, **after** all Copy / Embed phases but **before** any "Notarize" step. A companion `scripts/verify-entitlements.sh` runs immediately after and is a second Run Script phase.

**Build-setting preconditions** (set these in the Xcode target, not the script):
- `CODE_SIGN_STYLE = Manual`
- `CODE_SIGN_IDENTITY = Developer ID Application` (or `Apple Development` for Debug)
- `OTHER_CODE_SIGN_FLAGS = --options=runtime --timestamp` (Hardened Runtime + secure timestamp on every sign call)
- For each helper target later (P5): **"Code Sign On Copy" MUST be unchecked** in the "Embed Frameworks / Embed App Extensions" phase. This is enforced by a lint: `scripts/verify-codesign-settings.sh` greps the pbxproj for `CodeSignOnCopy = YES` near any `Contents/Helpers/` reference and fails the build.

**`scripts/codesign.sh` shape (bash, POSIX-ish):**

```bash
#!/bin/bash
set -euo pipefail

# Expected env (from Xcode): $BUILT_PRODUCTS_DIR, $WRAPPER_NAME (app bundle name),
# $EXPANDED_CODE_SIGN_IDENTITY, $OTHER_CODE_SIGN_FLAGS (--options=runtime --timestamp).

APP="${BUILT_PRODUCTS_DIR}/${WRAPPER_NAME}"
HELPERS_DIR="${APP}/Contents/Helpers"
IDENTITY="${EXPANDED_CODE_SIGN_IDENTITY}"
FLAGS="${OTHER_CODE_SIGN_FLAGS}"

# 1. Sign each nested helper .app deepest-first.
# `find -depth` visits children before their parents -> natural deepest-first walk.
if [ -d "$HELPERS_DIR" ]; then
  while IFS= read -r HELPER; do
    # Each helper carries its OWN .entitlements file sibling to its Info.plist.
    ENT="$(dirname "$HELPER")/../Resources/$(basename "$HELPER" .app).entitlements"
    if [ ! -f "$ENT" ]; then
      echo "error: missing entitlements for $HELPER (expected $ENT)" >&2
      exit 1
    fi
    echo "codesign (helper): $HELPER"
    /usr/bin/codesign --force --sign "$IDENTITY" $FLAGS \
      --entitlements "$ENT" \
      "$HELPER"
  done < <(find "$HELPERS_DIR" -depth -name "*.app" -type d)
fi

# 2. Sign the main app LAST, with its OWN entitlements.
MAIN_ENT="${SRCROOT}/App/Jarvis.entitlements"
echo "codesign (main): $APP"
/usr/bin/codesign --force --sign "$IDENTITY" $FLAGS \
  --entitlements "$MAIN_ENT" \
  "$APP"

# 3. Forbid --deep anywhere in build phases. Caught structurally by verify-entitlements.sh.
```

**`scripts/verify-entitlements.sh` shape:**

```bash
#!/bin/bash
set -euo pipefail

APP="${BUILT_PRODUCTS_DIR}/${WRAPPER_NAME}"

# Required entitlements on the MAIN app.
MAIN_REQUIRED=(
  "com.apple.security.cs.allow-jit"
  "com.apple.developer.speech-recognition-assets"
  "com.apple.security.device.audio-input"
)
# FORBIDDEN entitlements on the MAIN app (moved to helper in P5).
MAIN_FORBIDDEN=(
  "com.apple.security.automation.apple-events"
  "com.apple.security.cs.allow-unsigned-executable-memory"
)

EXTRACTED="$(/usr/bin/codesign -d --entitlements - "$APP" 2>&1 || true)"

for key in "${MAIN_REQUIRED[@]}"; do
  if ! echo "$EXTRACTED" | /usr/bin/grep -q "<key>$key</key>"; then
    echo "error: main app missing required entitlement: $key" >&2
    exit 1
  fi
done

for key in "${MAIN_FORBIDDEN[@]}"; do
  if echo "$EXTRACTED" | /usr/bin/grep -q "<key>$key</key>"; then
    echo "error: main app carries forbidden entitlement: $key" >&2
    exit 1
  fi
done

# Required NSSpeechRecognitionAssetsUsageDescription in Info.plist.
if ! /usr/bin/plutil -extract NSSpeechRecognitionAssetsUsageDescription raw \
     "$APP/Contents/Info.plist" >/dev/null 2>&1; then
  echo "error: NSSpeechRecognitionAssetsUsageDescription missing from Info.plist" >&2
  exit 1
fi

# If any helpers exist: verify their per-helper entitlements.
HELPERS_DIR="$APP/Contents/Helpers"
if [ -d "$HELPERS_DIR" ]; then
  while IFS= read -r HELPER; do
    HELPER_NAME="$(basename "$HELPER" .app)"
    HELPER_ENTS="$(/usr/bin/codesign -d --entitlements - "$HELPER" 2>&1 || true)"
    # Only mcp-applescript.app may carry automation.apple-events.
    if [ "$HELPER_NAME" = "mcp-applescript" ]; then
      if ! echo "$HELPER_ENTS" | /usr/bin/grep -q "com.apple.security.automation.apple-events"; then
        echo "error: mcp-applescript missing automation.apple-events entitlement" >&2
        exit 1
      fi
    else
      if echo "$HELPER_ENTS" | /usr/bin/grep -q "com.apple.security.automation.apple-events"; then
        echo "error: helper $HELPER_NAME has automation.apple-events — only mcp-applescript may have it" >&2
        exit 1
      fi
    fi
  done < <(find "$HELPERS_DIR" -depth -name "*.app" -type d)
fi

# Write the runtime-consumed "verified" flag into Info.plist (for AppDelegate hard-block check).
/usr/bin/plutil -replace JarvisEntitlementsVerified -bool YES "$APP/Contents/Info.plist"

echo "✓ entitlement verification passed"
```

**Why `find -depth`:** POSIX-specified to visit children before parents. For P1 there are no helpers yet, so the loop is empty — the script still runs, verifies main-app entitlements, sets `JarvisEntitlementsVerified`. When P5 adds `mcp-time.app`, `mcp-clipboard.app`, `mcp-applescript.app`, they're signed before the main `.app`.

**Why NOT `--deep`:** it recursively re-signs with the parent identity **and** strips per-helper entitlements (Pitfall §7). `codesign(1)` manual literally says "it doesn't work well in practice." Our script walks the tree manually so each helper gets its own `.entitlements`.

**Why post-build grep:** the build can silently drop an entitlement key via an errant pbxproj edit; catching at build time rather than at first-run is cheaper than debugging a Release-only `SFSpeechErrorCode.assetUnavailable` crash on a fresh machine.

**Sources:** [`codesign(1)` manual page (Keith's xcode-man-pages mirror)](https://keith.github.io/xcode-man-pages/codesign.1.html); [Apple Technical Note TN2206 "macOS Code Signing In Depth"](https://developer.apple.com/library/archive/technotes/tn2206/_index.html); [rsms's macOS distribution gist (deepest-first walk pattern)](https://gist.github.com/rsms/929c9c2fec231f0cf843a1a746a416f5).

---

### Question 3 — swift-log multi-handler composition

**Shape:**

1. Four `Logger` call sites: `Logger(label: "agent")`, `Logger(label: "tools")`, `Logger(label: "ui")`, `Logger(label: "system")`. The label is propagated into handlers — no custom enum needed.
2. `LoggingSystem.bootstrap(JarvisLogHandlerFactory.make)`. The factory is called once per unique label and returns a `MultiplexLogHandler([FileLogHandler(...), OSLogHandler(...)])`.
3. `MultiplexLogHandler` is the swift-log-provided fan-out primitive (ships in `Logging` itself — no extra dep). It calls each child's `log(...)` in turn.

**Illustrative factory:**

```swift
// packages/Logging/Sources/Logging/Bootstrap.swift
import Logging
import os

public enum JarvisLogChannel: String, Sendable, CaseIterable {
    case agent, tools, ui, system
}

public enum JarvisLogHandlerFactory {
    public static func make(label: String) -> LogHandler {
        let file = FileLogHandler(
            label: label,
            directory: LogPaths.channelDirectory,  // ~/Library/Logs/Jarvis/
            dateProvider: SystemDateProvider()
        )
        let os = OSLogHandler(
            subsystem: "com.kingsrook.jarvis",
            category: label,
            label: label
        )
        return MultiplexLogHandler([file, os])
    }

    public static func bootstrap() {
        // Call exactly once at app launch. LoggingSystem is a process-global
        // singleton; bootstrap() must not be called twice.
        LoggingSystem.bootstrap(JarvisLogHandlerFactory.make)
    }
}
```

Then at `@main` / `AppDelegate.applicationWillFinishLaunching`:

```swift
JarvisLogHandlerFactory.bootstrap()
let agentLog = Logger(label: JarvisLogChannel.agent.rawValue)
```

**File rotation: hand-rolled.** The swift-log ecosystem has three community backends — `sushichop/Puppy`, `crspybits/swift-log-file`, `Ponyboy47/swift-log-file`. Evaluation:

| Option | Size | Activity | Swift 6 concurrency | Matches D-18 (daily midnight + retain 7) | Verdict |
|--------|------|----------|---------------------|----------------------------------------|---------|
| Puppy | ~2K LOC | Actively maintained | Unclear | Size-based + date-based (but date-based is "rotate every N days") | Over-featured; adds dep |
| swift-log-file (crspybits) | ~500 LOC | Light activity | Not audited | Size-based only | Doesn't meet D-18 |
| swift-log-file (Ponyboy47) | ~600 LOC | Last touched pre-2024 | Not audited | Date-based at midnight | Stale |
| **Hand-rolled** | ~80 LOC | Our own | Trivial `Sendable` | Exact match | **Pick this.** |

The D-18 rotation policy is simple enough that pulling a 500-2000 LOC SPM dep is worse than the 80-LOC implementation. Hand-rolled lives in `packages/Logging/Sources/Logging/FileLogHandler.swift`:

```swift
// packages/Logging/Sources/Logging/FileLogHandler.swift — illustrative
import Foundation
import Logging

struct FileLogHandler: LogHandler {
    let label: String
    let directory: URL
    let dateProvider: any DateProvider

    var logLevel: Logger.Level = .info
    var metadata: Logger.Metadata = [:]
    var metadataProvider: Logger.MetadataProvider?

    private let writer: FileRotatingWriter  // serial queue, FS I/O, midnight roll

    init(label: String, directory: URL, dateProvider: any DateProvider) {
        self.label = label
        self.directory = directory
        self.dateProvider = dateProvider
        self.writer = FileRotatingWriter(
            directory: directory,
            baseName: label,
            retentionDays: 7,
            dateProvider: dateProvider
        )
    }

    func log(level: Logger.Level, message: Logger.Message,
             metadata: Logger.Metadata?, source: String,
             file: String, function: String, line: UInt) {
        let merged = mergeMetadata(explicit: metadata)
        let raw = "\(dateProvider.now().iso8601) \(level.rawValue.uppercased()) [\(label)] \(message) \(merged.formatted)"
        let redacted = Redact.apply(raw)  // SINGLE redact() call site
        writer.append(redacted + "\n")
    }

    subscript(metadataKey key: String) -> Logger.Metadata.Value? {
        get { metadata[key] }
        set { metadata[key] = newValue }
    }
}

final class FileRotatingWriter: @unchecked Sendable {
    // Serial DispatchQueue for all writes.
    // On each append: compute today's date string via dateProvider.
    // If today != lastOpenedDate: close current FD, open new file "{baseName}.{today}.log",
    //   then GCi expired files (> 7 days old) from directory.
    // append(_:) writes to FD.
    // No DispatchSource timer needed — the midnight boundary is detected lazily on first
    // post-midnight write. Zero-write days just delay the rotation, which is fine.
    // ...
}
```

**Why lazy rotation over a `DispatchSource.makeTimerSource` at midnight:** a timer thread leaks work if the process is idle all night; lazy rotation is a one-comparison cost at each write. Fine for spiky days since we accept unbounded disk footprint (D-18).

**`redact()` hook placement:** inside `FileLogHandler.log` (one call site, before `writer.append`). **NOT** inside `OSLogHandler.log` — because `os.Logger` already redacts `%{private}@` at the system layer, and double-redaction just rewrites a string os.Logger would already hide. This means `os.Logger` sees raw strings; anyone reading Console.app will see the raw key if we ever log one raw. Discipline: **never pass a raw secret as a `Logger.Message`**; always call `redact()` upstream if the source is untrusted. The file-handler redact is defense-in-depth against a mistake in that discipline.

**`redact()` implementation shape — single-pass regex, 5 alternation branches:**

```swift
// packages/Logging/Sources/Logging/Redact.swift
import Foundation

public enum Redact {
    // Compiled once.
    private static let pattern: NSRegularExpression = {
        // Ordered by likely specificity to reduce backtracking:
        // 1. Anthropic sk-ant-<48+ chars>
        // 2. Authorization: Bearer <token>      (case-insensitive on "Authorization")
        // 3. OpenAI sk-<48+ chars>              (must not collide with sk-ant-*)
        // 4. AKIA<16 uppercase alphanumerics>
        // 5. ghp_<36 alphanumerics>
        let raw = #"(sk-ant-[A-Za-z0-9_\-]{20,})|((?i:Authorization:\s*Bearer)\s+[A-Za-z0-9_\-\.=]+)|(\bsk-[A-Za-z0-9_\-]{20,})|(AKIA[0-9A-Z]{16})|(ghp_[A-Za-z0-9]{36})"#
        return try! NSRegularExpression(pattern: raw)
    }()

    public static func apply(_ s: String) -> String {
        let ns = s as NSString
        return pattern.stringByReplacingMatches(
            in: s, range: NSRange(location: 0, length: ns.length),
            withTemplate: "<redacted>"
        )
    }
}
```

Unit tests for `redact()` are REQ-linked to OBS-06: one positive test per pattern, one negative test (plain text unchanged), one test that confirms `sk-ant-…` is matched by branch 1 and NOT by branch 3 (ordering matters).

**Sources:** [apple/swift-log README & `ImplementingALogHandler.md`](https://github.com/apple/swift-log); [swift-log `MultiplexLogHandler` API](https://apple.github.io/swift-log/docs/current/Logging/Structs/MultiplexLogHandler.html); [swift-log metadata providers proposal 0001](https://github.com/apple/swift-log/blob/main/proposals/0001-metadata-providers.md).

---

### Question 4 — Scaffold-time entitlement verification harness

**Decision: shell (`verify-entitlements.sh`) + one-shot XCTest (`JarvisEntitlementProbeTests`) per UI-SPEC Surface 6. This research validates the split.**

**Why both:**
- The **shell script** verifies static build output — that the entitlement was actually embedded in the signed binary. Catches the "I forgot to add the key to Jarvis.entitlements" failure mode at build time. Fast. Always runs. No runtime dependency.
- The **XCTest probe** verifies the dynamic claim — that without the entitlement, `SpeechTranscriber` (or `SpeechAnalyzer`) actually produces `SFSpeechErrorCode.assetUnavailable`. This is the RESEARCH-DELTAS scaffold-time verification. Runs once manually on a specifically-prepared stripped-entitlement Release archive; if it passes (i.e. the error fires), the load-bearing claim is confirmed.

**Probe mechanic — the tricky part.** Apple's `SpeechAnalyzer` docs are beta-era and don't fully document entitlement-gated init behavior. Three observed patterns from community sources as of April 2026:

1. `SpeechTranscriber(locale:preset:)` init does **not** throw synchronously on missing entitlement in all observed reports.
2. `AssetInventory.status(forModules: [transcriber])` — the asset probe — is where the error surface shows up. Without the entitlement, it fails. Reported error codes: `SFSpeechErrorCode.assetUnavailable` in the original AUDIT-R2-S5 claim; newer macOS 26 beta reports (`Code=10 "Cannot use modules with unallocated locales [en_US (fixed en_US)]"`) suggest the exact code may vary.
3. Fresh machines also see `assetUnavailable` legitimately — because the asset genuinely isn't downloaded yet. The probe must distinguish "no entitlement" from "asset not yet downloaded."

**Probe strategy:**

```swift
// packages/Shell/Tests/ShellTests/JarvisEntitlementProbeTests.swift
// GATED on build flag JARVIS_ENTITLEMENT_PROBE=1 via #if.
// Excluded from default test plan. Invoked only by:
//   xcodebuild test -scheme Jarvis -testPlan EntitlementProbe ...
// ...on a Release archive specifically prepared with the entitlement STRIPPED.
#if JARVIS_ENTITLEMENT_PROBE

import XCTest
import Speech

final class JarvisEntitlementProbeTests: XCTestCase {

    /// Negative test: with the entitlement ABSENT, we expect an
    /// AssetInventory / SpeechAnalyzer failure signaling lack of entitlement-
    /// gated asset access.
    func test_missingEntitlement_producesAssetUnavailableOrLocaleAllocation() async throws {
        let locale = Locale(identifier: "en-US")
        let transcriber = SpeechTranscriber(
            locale: locale,
            preset: .progressiveLiveTranscription
        )

        // Per Apple's API shape (beta): status(forModules:) reports whether the
        // speech-recognition asset is downloadable/installed. Without the
        // entitlement, allocation fails.
        do {
            let status = try await AssetInventory.status(forModules: [transcriber])
            // Expected failure path on stripped entitlement:
            //   a. .unsupported / .unavailable
            //   b. OR throws with SFSpeechErrorCode.assetUnavailable
            //   c. OR throws SFSpeechError Code=10
            XCTFail("expected failure without entitlement; got status=\(status)")
        } catch let e as NSError
            where e.domain == "SFSpeechErrorDomain"
            && (e.code == 1   /* assetUnavailable historically */
                || e.code == 10 /* macOS 26 beta: "unallocated locales" */) {
            // Load-bearing claim CONFIRMED: without entitlement, operation fails.
            return
        }

        XCTFail("entitlement appears not to be load-bearing; review RESEARCH-DELTAS claim")
    }
}

#endif
```

**And the positive counterpart** (in a separate plan — `EntitlementProbePositive`) runs on a **properly-entitled** Release archive and asserts the probe does NOT fail — confirming the entitlement is sufficient.

**Why not a pure Debug XCTest:** `allow-jit` and `speech-recognition-assets` are **Release-only** failure surfaces. Debug builds have the dev machine's persistent TCC + cached trust that masks the failure. Both probes must run against a Release archive.

**Shipping-gate integration:** the probe is listed in STATE.md's "Scaffold-Time Verifications" row and ticked off **only after a human runs the stripped-entitlement archive probe and sees it fail** (confirming load-bearing) AND runs the entitled archive probe and sees it succeed (confirming sufficient).

**Why `AssetInventory.status(forModules:)` and not a direct transcribe call:** a transcribe call would require feeding it audio, which is slow and flaky. `AssetInventory.status` is the lightweight probe that fails fastest on the entitlement surface. Per WWDC25 session 277 ("Bring advanced speech-to-text to your app with SpeechAnalyzer"), this is the intended capability-probe API.

**Sources:** [Apple SpeechAnalyzer documentation](https://developer.apple.com/documentation/speech/speechanalyzer); [Apple SpeechTranscriber documentation](https://developer.apple.com/documentation/speech/speechtranscriber); [Apple WWDC 2025 session 277 — Bring advanced speech-to-text with SpeechAnalyzer](https://developer.apple.com/videos/play/wwdc2025/277/); [iOS 26 SpeechAnalyzer Guide — Anton Gubarenko](https://antongubarenko.substack.com/p/ios-26-speechanalyzer-guide); [Apple Developer Forums thread 790108 (SpeechAnalyzer WWDC discussion)](https://developer.apple.com/forums/thread/790108); [RESEARCH-DELTAS §SpeechAnalyzer entitlement — load-bearing but externally unverified](.planning/research/RESEARCH-DELTAS.md).

---

### Question 5 — `LaunchSnapshot` / `PerTurnSnapshot` ergonomics

**Concrete Swift shape:**

```swift
// packages/Config/Sources/Config/Snapshots.swift

public struct LaunchSnapshot: Sendable, Codable, Equatable {
    public let schemaVersion: Int            // always 1 in P1
    // --- Security-sensitive keys. Change requires restart. ---
    public let ollama: OllamaConfig           // ollama.base_url host validated 127.0.0.1/localhost
    public let applescript: AppleScriptPolicy // no skip-allowlist; confirmation always required
    public let toolBlocklist: [String]        // tool names refused at orchestrator boundary
    public let confirmationPolicy: ConfirmationPolicy
    // --- Logging (launch-time; not security-sensitive, but handler config
    //     is set at bootstrap and re-reading would require re-bootstrap). ---
    public let logging: LoggingLaunchConfig
}

public struct PerTurnSnapshot: Sendable, Codable, Equatable {
    public let schemaVersion: Int            // mirror launch for consistency checks
    // --- Non-security keys; applies at next submit(). ---
    public let provider: ProviderSelection    // .anthropic / .ollama
    public let tts: TTSConfig                 // tier, voice, flags
    public let stt: STTConfig                 // whisperKitFallback, etc.
    public let featureFlags: FeatureFlags     // OBS-05 LIVES HERE (see decision below)
}

public struct OllamaConfig: Sendable, Codable, Equatable {
    public let baseURL: URL       // VALIDATED at decode — AGENT-05
}

extension OllamaConfig {
    public init(from decoder: Decoder) throws {
        // ... custom decode that validates host ∈ {"127.0.0.1", "localhost", "::1"} ...
    }
}
```

**Where feature flags live (OBS-05 resolution):** `PerTurnSnapshot`. Rationale: feature flags are primarily for tools-in-development and rapid toggling during dev — "one of the two snapshots, not both" is the constraint; putting them in `LaunchSnapshot` would require a restart for every flag flip, which defeats the "without rebuild" NFR. Security-critical flags (e.g. "skip AppleScript confirmation") **do not exist as flags** (SEC-08 forbids a skip-allowlist at all).

**Config load pipeline:**

```swift
// packages/Config/Sources/Config/Loader.swift
public enum ConfigLoader {
    public static func loadSnapshots(from url: URL)
        throws -> (LaunchSnapshot, PerTurnSnapshot)
    {
        let data = try Data(contentsOf: url)
        // Peek schema version first.
        struct Peek: Decodable { let schemaVersion: Int }
        let peek = try JSONDecoder().decode(Peek.self, from: data)
        // Migrate to current version (P1: only v1 exists; pass-through).
        let currentData = try SchemaMigrator.migrate(data, from: peek.schemaVersion, to: 1)
        // Decode both snapshots from the SAME document.
        let decoder = JSONDecoder()
        let launch = try decoder.decode(LaunchSnapshot.self, from: currentData)
        let perTurn = try decoder.decode(PerTurnSnapshot.self, from: currentData)
        return (launch, perTurn)
    }
}
```

**Malformed-config behavior:** per D-19, **NSAlert hard-block**. We treat a user-edited-and-broken `config.json` as a must-stop-before-doing-harm state — the alternative ("fall back to defaults silently") masks an editing error and could, worst-case, downgrade a security key. The NSAlert wraps `ConfigError` with:
- Title: "Jarvis can't start"
- Message: "Your config file couldn't be read. \{underlying error, one line\}. Details in \~/Library/Logs/Jarvis/system.log."
- Buttons: "Quit", "Show Details" (opens system.log in Console.app).

On first launch where `config.json` does NOT exist yet: `ConfigLoader` writes a default config (embedded resource) and re-reads. Not an error.

**Restart-required enforcement:** a file watcher on `config.json` (`DispatchSource.makeFileSystemObjectSource`) fires on user edits. The new document is parsed to a pending `LaunchSnapshot`. Compare `pending.hashable` against `current.hashable` — if different, surface HUD banner "Config change requires restart" with "Restart Now" and "Dismiss" buttons. `PerTurnSnapshot` diffs apply silently at next `submit()`.

**`LaunchSnapshot` is a `let` everywhere** — after load, we store it via `AppDelegate.launchConfig` as a single non-optional constant. `PerTurnSnapshot` is wrapped in a `ConfigActor` and published via an `AsyncStream<PerTurnSnapshot>`. The agent orchestrator reads the latest on each `submit()` (not cached across turns).

**Sources:** [Apple `JSONDecoder` documentation](https://developer.apple.com/documentation/foundation/jsondecoder); [VersionedCodable pattern — joro.dev](https://joro.dev/posts/versioned-codable/); [Krzysztof Zabłocki — versioning Codable models](https://www.merowing.info/adding-support-for-versioning-and-migration-to-your-codable-models-/).

---

### Question 6 — `config.json` schema versioning

**Recommendation: embedded `schemaVersion: Int` + explicit migration functions.**

**Single-file shape** (recommended):

```json
{
  "schemaVersion": 1,
  "ollama": {
    "baseURL": "http://127.0.0.1:11434"
  },
  "applescript": {
    "confirmationRequired": true
  },
  "provider": "anthropic",
  "tts": { "tier": "tier1" },
  "stt": { "whisperKitFallback": false },
  "featureFlags": {
    "orpheusTTSEnabled": false,
    "whisperKitSTTEnabled": false
  },
  "toolBlocklist": [],
  "confirmationPolicy": { "timeoutSeconds": 60 },
  "logging": { "fileLevel": "info", "osLogLevel": "info" }
}
```

**Migration surface:**

```swift
// packages/Config/Sources/Config/SchemaMigrator.swift
enum SchemaMigrator {
    static let currentVersion = 1

    static func migrate(_ data: Data, from: Int, to: Int) throws -> Data {
        guard from <= to else { throw ConfigError.futureSchema(version: from) }
        var current = data
        var v = from
        while v < to {
            current = try migrateStep(current, fromVersion: v)
            v += 1
        }
        return current
    }

    private static func migrateStep(_ data: Data, fromVersion v: Int) throws -> Data {
        switch v {
        // P1 ships at v1; no migrations yet. First real migration lives here when v2 lands.
        // Example (illustrative, not shipped):
        // case 1: return try v1ToV2(data)
        default:
            throw ConfigError.unknownSchemaVersion(v)
        }
    }
}
```

**Why embedded-key over path-based:** path-based ("keep a directory with `config.v1.json`, `config.v2.json`") makes the user's file location unstable across versions, which leaks into backup tools, documentation, the "Show in Finder" action on the HUD banner, etc. Embedded-key is a one-integer hit in the same file and matches standard industry practice (SwiftData VersionedSchema, Django migrations, Rails schema_migrations).

**Why explicit migration functions over a registry:** with a single user, a single machine, and a forward-only upgrade path, an N-function step-migration is simpler than a registry abstraction. Migration functions stay small (usually 5-20 LOC each) and each one gets a fixture test.

**Sources:** [VersionedCodable — Joro Rothwell](https://github.com/jrothwell/VersionedCodable); [onmyway133 — Migrating Codable](https://dev.to/onmyway133/migrating-codable-object-7e3).

---

### Question 7 — Menu-bar icon animation approach

**Core pattern — validated against UI-SPEC Surface 3:**

```swift
// App/MenuBar/MenuBarIconController.swift — illustrative
import AppKit

@MainActor
final class MenuBarIconController {
    let statusItem: NSStatusItem
    private var currentState: HudState = .idle
    private let imageLayer: CALayer  // holds the PDF template image

    init(statusItem: NSStatusItem) {
        self.statusItem = statusItem
        self.imageLayer = CALayer()
        configureButtonLayer()
    }

    private func configureButtonLayer() {
        guard let button = statusItem.button else { return }
        button.wantsLayer = true
        // Preserve template image rendering by NOT setting layer.contents = image.
        // Instead, let AppKit draw the image into the button's layer backing store
        // via button.image = NSImage(named: "Icon-MenuBar-Template") with isTemplate=true.
        // Then animate the BUTTON's layer transform / opacity.
        button.image = NSImage(named: "Icon-MenuBar-Template")
        button.image?.isTemplate = true
        // Center anchor so rotation / scale happens around center.
        guard let layer = button.layer else { return }
        layer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        // Re-center the frame because changing anchorPoint moves the layer.
        layer.frame = button.bounds
    }

    func transition(to newState: HudState) {
        guard newState != currentState else { return }
        guard let button = statusItem.button, let layer = button.layer else { return }
        // 150 ms crossfade: attach a CATransition(fade) before swapping animations.
        let fade = CATransition()
        fade.type = .fade
        fade.duration = 0.15
        layer.add(fade, forKey: "crossfade")
        // Remove prior per-state animations.
        layer.removeAnimation(forKey: "state.breath")
        layer.removeAnimation(forKey: "state.rotate")
        layer.removeAnimation(forKey: "state.shimmer")
        layer.removeAnimation(forKey: "state.glow")
        // Apply new-state animation.
        switch newState {
        case .idle:
            break  // no animation
        case .listening:
            layer.add(makeBreath(), forKey: "state.breath")
        case .thinking:
            layer.add(makeRotate(), forKey: "state.rotate")
        case .speaking:
            layer.add(makeShimmer(), forKey: "state.shimmer")
        case .awaitingConfirmation:
            layer.add(makeGlow(), forKey: "state.glow")
        }
        currentState = newState
        // Accessibility announcement (rate-limited upstream).
        button.setAccessibilityLabel(newState.voiceOverLabel)
    }

    private func makeBreath() -> CABasicAnimation {
        let a = CABasicAnimation(keyPath: "transform.scale")
        a.fromValue = 1.0
        a.toValue = 1.04
        a.duration = 0.625  // half-period for ping-pong
        a.autoreverses = true
        a.repeatCount = .infinity
        a.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        return a
    }

    private func makeRotate() -> CABasicAnimation {
        let a = CABasicAnimation(keyPath: "transform.rotation.z")
        a.fromValue = 0
        a.toValue = 2 * CGFloat.pi
        a.duration = 1.5
        a.repeatCount = .infinity
        a.timingFunction = CAMediaTimingFunction(name: .linear)
        return a
    }

    private func makeShimmer() -> CAKeyframeAnimation {
        let a = CAKeyframeAnimation(keyPath: "opacity")
        a.values = [1.0, 0.65, 1.0]
        a.keyTimes = [0.0, 0.5, 1.0]
        a.duration = 0.9
        a.repeatCount = .infinity
        return a
    }

    private func makeGlow() -> CABasicAnimation {
        let a = CABasicAnimation(keyPath: "opacity")
        a.fromValue = 1.0
        a.toValue = 0.55
        a.duration = 0.5  // half-period for ping-pong
        a.autoreverses = true
        a.repeatCount = .infinity
        a.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        return a
    }
}
```

**Key gotchas documented in the community:**

1. **`wantsLayer = true` + template image**: setting `layer.contents = NSImage(...)` directly loses template rendering — the image renders as plain RGB. **Solution:** keep `button.image = NSImage(...)` with `isTemplate = true` and let AppKit draw it into the backing store; animate `transform` and `opacity` on the button's root layer instead of replacing `contents`. This preserves template-aware light/dark auto-inversion.
2. **Rotation from bottom-left corner**: the default `anchorPoint` is `(0, 0)`. After setting it to `(0.5, 0.5)`, the layer translates — so `layer.frame = button.bounds` must be re-applied afterward to keep visual position. Apple DevForums thread 88341 and onmyway133 both document this explicitly.
3. **Crossfade between state animations**: use `CATransition(type: .fade)` with `duration: 0.15` added to the same layer as the new state's animation. AppKit composites them.
4. **Reduce Motion** (UI-SPEC): `NSWorkspace.shared.accessibilityDisplayShouldReduceMotion` is checked inside `transition(to:)` — if true, use the fallback patterns from UI-SPEC Surface 3 (e.g. static icon with a subtle pulse dot) instead of the continuous animations above.
5. **Rate-limited VoiceOver announcement**: UI-SPEC specifies no more than once per 3 s; wrap the `setAccessibilityLabel` update with a throttle.

**Sources:** [Apple Developer Forums — animating NSStatusItem rotation (thread 88341)](https://developer.apple.com/forums/thread/88341); [onmyway133 — How to rotate NSStatusItem](https://onmyway133.com/posts/how-to-rotate-nsstatusitem/); [objc.io — Inside Code Signing / Animations issues (issue 12 and 17)](https://www.objc.io/issues/12-animations/animating-custom-layer-properties/).

---

### Question 8 — Shortcut-recorder hand-roll pattern

**Pattern (mirrors `sindresorhus/KeyboardShortcuts` internals):**

1. **`NSViewRepresentable`** wraps a custom `NSView` (call it `ShortcutRecorderHostView`) because SwiftUI's event capture is not rich enough for low-level `NSEvent` inspection — specifically, we need `modifierFlags` + `keyCode: UInt16` + `charactersIgnoringModifiers`, not the keyboard-shortcut layer SwiftUI exposes.
2. The custom `NSView` overrides `becomeFirstResponder` → returns `true` and installs a local event monitor via `NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged])`.
3. On `keyDown`: extract `modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)` and `keyCode = event.keyCode`. Validate:
   - `keyCode == kVK_Escape` (53) → exit recording, return `nil` (consume the event — don't let Escape dismiss the wizard).
   - Modifier-only (no regular key): inline error "A shortcut needs at least one regular key."
   - Shift-only (no other modifier + letter/number): same inline error per `KeyboardShortcuts` precedent ("The 'shift' key is not allowed without other modifiers or a function key, since it doesn't actually work.").
   - Otherwise: call binding's `shortcut = .init(keyCode: keyCode, modifiers: modifiers)`, exit recording.
4. On `flagsChanged`: update UI to reflect currently-held modifiers (so user sees "⌘⇧" before pressing the letter).
5. On `resignFirstResponder`: remove the local monitor. A stale monitor holding a reference to the recorder view leaks.

**Implementation skeleton:**

```swift
// packages/Shell/Sources/Shell/ShortcutRecorderView.swift
import SwiftUI
import AppKit
import Carbon.HIToolbox  // only for kVK_* constants — NOT for RegisterEventHotKey

public struct KeyboardShortcut: Codable, Sendable, Equatable {
    public let keyCode: UInt16
    public let modifiers: NSEvent.ModifierFlags.RawValue  // raw for Codable
}

public struct ShortcutRecorderView: NSViewRepresentable {
    @Binding var shortcut: KeyboardShortcut?
    @Binding var errorMessage: String?

    public func makeNSView(context: Context) -> ShortcutRecorderHostView {
        ShortcutRecorderHostView(coordinator: context.coordinator)
    }

    public func updateNSView(_ view: ShortcutRecorderHostView, context: Context) {
        view.shortcut = shortcut
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    public final class Coordinator {
        let parent: ShortcutRecorderView
        init(parent: ShortcutRecorderView) { self.parent = parent }

        func recorded(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) {
            parent.errorMessage = nil
            parent.shortcut = KeyboardShortcut(keyCode: keyCode, modifiers: modifiers.rawValue)
        }

        func rejected(_ reason: String) { parent.errorMessage = reason }
    }
}

final class ShortcutRecorderHostView: NSView {
    var shortcut: KeyboardShortcut?
    private let coordinator: ShortcutRecorderView.Coordinator
    private var isRecording = false
    private var monitor: Any?

    init(coordinator: ShortcutRecorderView.Coordinator) {
        self.coordinator = coordinator
        super.init(frame: .zero)
    }
    required init?(coder: NSCoder) { nil }

    override var acceptsFirstResponder: Bool { true }

    override func becomeFirstResponder() -> Bool {
        isRecording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) {
            [weak self] event in
            guard let self else { return event }
            if event.type == .keyDown {
                // Escape aborts recording.
                if event.keyCode == kVK_Escape {
                    _ = self.resignFirstResponder()
                    return nil  // swallow — don't let Escape close the wizard
                }
                let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
                // Reject modifier-only / shift-only (matches KeyboardShortcuts precedent).
                if mods.isEmpty {
                    self.coordinator.rejected("A shortcut needs at least one modifier.")
                    return nil
                }
                if mods == .shift {
                    self.coordinator.rejected("Shift alone isn't a valid modifier. Try Command, Option, or Control.")
                    return nil
                }
                self.coordinator.recorded(keyCode: event.keyCode, modifiers: mods)
                _ = self.resignFirstResponder()
                return nil
            }
            // flagsChanged — ignore for now; future UI could render live modifier state.
            return event
        }
        return super.becomeFirstResponder()
    }

    override func resignFirstResponder() -> Bool {
        isRecording = false
        if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
        return super.resignFirstResponder()
    }
}
```

**Collision detection** (for warnings per UI-SPEC stage 3 copy): static map of known collisions checked after `recorded(...)`:

```swift
static let knownCollisions: [(KeyCombo, apps: [String])] = [
    (.cmdShiftJ, ["Chrome", "Slack", "VS Code"]),
    (.optionSpace, ["Alfred", "Raycast"]),
]
```

**Sources:** [`sindresorhus/KeyboardShortcuts` — RecorderCocoa.swift source (internal patterns — we don't use the SPM but we borrow the shape)](https://github.com/sindresorhus/KeyboardShortcuts); [Handle Keyboard Presses Using SwiftUI in macOS — Swiftjective-C](https://swiftjectivec.com/Handling-Keyboard-Presses-in-SwiftUI-for-macOS/); [onmyway133 — How to handle keyDown in NSResponder](https://onmyway133.com/posts/how-to-handle-keydown-in-nsresponder/).

---

### Question 9 — Launch-at-login

**Recommendation: `SMAppService.mainApp.register()` via `ServiceManagement` framework (macOS 13+). On macOS 26 Tahoe, unchanged.**

`SMLoginItemSetEnabled` is deprecated (macOS 13+); do not use.

**Shape:**

```swift
// packages/Shell/Sources/Shell/LaunchAtLogin.swift
import ServiceManagement

public enum LaunchAtLoginError: Error, Sendable {
    case notFound       // SMAppServiceStatusNotFound — service not recognized; bundle ID mismatch?
    case requiresApproval  // user must approve in System Settings
    case registerFailed(Error)
}

public struct LaunchAtLogin: Sendable {
    public init() {}

    public var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    public var requiresApproval: Bool {
        SMAppService.mainApp.status == .requiresApproval
    }

    public func enable() throws {
        do {
            try SMAppService.mainApp.register()
        } catch {
            throw LaunchAtLoginError.registerFailed(error)
        }
        // Re-read status: .requiresApproval is a successful register
        // that's just waiting on user consent.
    }

    public func disable() throws {
        do {
            try SMAppService.mainApp.unregister()
        } catch {
            throw LaunchAtLoginError.registerFailed(error)
        }
    }

    public func openSystemSettingsLoginItems() {
        // Deep link to Login Items pane in System Settings (macOS 13+).
        let url = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension")!
        NSWorkspace.shared.open(url)
    }
}
```

**First-launch behavior per D-06:** opt-in, **unchecked by default**. The wizard currently does not expose launch-at-login (P1 scope is just API-key / TCC / hotkey per D-07). Launch-at-login goes in the **Settings… menu item** stub as "Coming soon" in P1 and a real toggle later. For P1 the capability is **scaffolded** (`LaunchAtLogin()` API exists in `packages/Shell`) but there is no user-facing toggle yet. This matches SHELL-05: "The app launches at login when opt-in is enabled and sits in background with `LSUIElement=YES` otherwise" — we ship with opt-in disabled; Settings UI comes post-P1.

**On `requiresApproval`**: after `register()`, if status is `.requiresApproval`, surface a HUD banner: "Launch at login needs approval — Open System Settings" linking via `openSystemSettingsLoginItems()`. (P1 doesn't need this path because the toggle doesn't exist yet, but `LaunchAtLogin` API has it ready for Settings.)

**Sources:** [Apple SMAppService mainApp](https://developer.apple.com/documentation/servicemanagement/smappservice/mainapp); [Apple SMAppService Status enum](https://developer.apple.com/documentation/servicemanagement/smappservice/status-swift.enum); [theevilbit — SMAppService Quick Notes](https://theevilbit.github.io/posts/smappservice/); [nilcoalescing — Add launch-at-login setting to a macOS app](https://nilcoalescing.com/blog/LaunchAtLoginSetting/).

---

### Question 10 — Validation architecture (Nyquist sampling for P1)

Nyquist principle applied to test coverage: **cover each requirement from ≥ 2 independent angles** (happy-path + one adversarial / boundary). The shell-script probes provide one angle, XCTests provide the other. Manual-only items are called out.

See full table under `## Validation Architecture` below.

---

## Standard Stack

### Core (new in P1)

| Library / API | Version | Purpose | Why standard |
|---------------|---------|---------|--------------|
| Xcode | 16 (Swift 6) | IDE, build, codesign | Matches macOS 26 target; Swift 6 strict concurrency (D-04) |
| macOS SDK | 26 Tahoe target; macOS 13+ deployment | Host OS | User's current machine; SpeechAnalyzer requires 26 |
| SwiftPM (local packages) | built-in | Dependency & modularization | D-05: no workspace, no CocoaPods |
| `apple/swift-log` | 1.5.3+ | Structured logs, four channels | STACK pinned; OBS-06 |
| `apple/swift-async-algorithms` | 1.0.0+ | Bounded `AsyncChannel(capacity:)` for P4+ | STACK pinned (scaffolded now, used from P4 onward — planner's call whether to include in P1 package deps or defer to P4) |
| `apple/swift-argument-parser` | 1.3.0+ | Future CLI scripts (e.g. eval runner) | Not needed in P1 — defer to P4/P8 |
| `Security.framework` | system | Keychain API key storage | Zero SPM deps; ~60 LOC wrapper |
| `AppKit` (`NSStatusItem`, `NSPanel`, `NSAlert`, `NSEvent`) | system | Menu bar, HUD panel, alerts, hotkey | Native-only APIs |
| `SwiftUI` | system | Wizard UI, shortcut recorder view | Declarative UI for forms |
| `ServiceManagement` (`SMAppService`) | system (macOS 13+) | Launch-at-login | Apple-replaced `SMLoginItemSetEnabled` |
| `Speech` framework (`SpeechTranscriber`, `AssetInventory`) | system (macOS 26) | Entitlement probe only in P1; real STT in P6 | Scaffold-time verification |
| `WKWebView` | system | HUD panel skeleton (P3 fills it) | Greenfield for React + R3F |
| `IOKit.hid` (`IOHIDRequestAccess`) | system | Input Monitoring probe | Detects TCC denial so banner can surface |
| `os.Logger` | system | `os.log` channel | Console.app / `log stream` integration |

### Deliberately NOT used in P1 (via D-05 / user constraints)

| Rejected | Why |
|----------|-----|
| `kishikawakatsumi/KeychainAccess` | SPM dep for one use site; raw `Security.framework` is ~60 LOC |
| `sushichop/Puppy`, `crspybits/swift-log-file`, `Ponyboy47/swift-log-file` | File rotation is ~80 LOC hand-rolled; D-18 spec is narrower than any of these packages provide |
| `sindresorhus/KeyboardShortcuts` | One use site; ~150 LOC hand-rolled per UI-SPEC Surface 2 |
| `soffes/HotKey` | Carbon-based; Input Monitoring TCC footprint larger than `NSEvent.addGlobalMonitorForEvents`; STACK D14 / R3-S4 |
| CocoaPods / Xcode workspace | D-05 / R1 H-B2 |

### Entitlements (`Jarvis.entitlements`) — day one

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
    <key>com.apple.security.cs.allow-jit</key>                   <true/>
    <key>com.apple.developer.speech-recognition-assets</key>     <true/>
    <key>com.apple.security.device.audio-input</key>             <true/>
</dict></plist>
```

**Explicitly NOT included in main app entitlements:**
- `com.apple.security.automation.apple-events` — moves to `mcp-applescript.entitlements` (P5).
- `com.apple.security.cs.allow-unsigned-executable-memory` — R2-S4: MLX doesn't need it; hardening regression with no evidence of need.

### Info.plist — day one

Required keys:
- `LSUIElement` → `YES` (no Dock icon).
- `NSSpeechRecognitionAssetsUsageDescription` → "Jarvis uses on-device speech recognition to listen to your voice commands. Audio never leaves your Mac."
- `NSMicrophoneUsageDescription` — pre-set for P6 (does NOT prompt in P1; macOS only prompts on first use of `AVAudioEngine` mic I/O).
- `NSCameraUsageDescription` — pre-set for P7 (same — doesn't prompt until first use).
- `NSAppleEventsUsageDescription` — pre-set for P5 `mcp-applescript`.
- `JarvisEntitlementsVerified` → `NO` (written by `verify-entitlements.sh` at build time; read by AppDelegate at launch).

### Bundle layout

```
Jarvis.app/
├── Contents/
│   ├── Info.plist                         # main app Info.plist
│   ├── MacOS/
│   │   └── Jarvis                         # main binary
│   ├── Resources/
│   │   ├── Assets.car                     # compiled asset catalog
│   │   ├── webview/                       # P3 bundle destination (empty in P1)
│   │   └── …
│   ├── Helpers/                           # MCP helpers (empty in P1; P5 populates)
│   │   ├── mcp-time.app/                  # (P5)
│   │   ├── mcp-clipboard.app/             # (P5)
│   │   └── mcp-applescript.app/           # (P5)
│   ├── Frameworks/                        # SPM-compiled frameworks
│   └── _CodeSignature/
```

Root repo layout:

```
<repo-root>/
├── CLAUDE.md
├── Jarvis.xcodeproj/                      # no workspace; D-05
├── App/
│   ├── Jarvis.entitlements
│   ├── Info.plist
│   ├── Assets.xcassets/
│   │   ├── Icon-MenuBar-Template.imageset/
│   │   │   ├── Icon-MenuBar-Template.pdf
│   │   │   └── Contents.json   # "template-rendering-intent": "template"
│   │   └── AppIcon.appiconset/
│   ├── JarvisApp.swift                    # @main, AppDelegate
│   ├── AppDelegate.swift                  # wiring, entitlement-grep hard-block
│   ├── MenuBar/
│   │   ├── MenuBarIconController.swift    # Core Animation state machine
│   │   └── MenuBarContextMenu.swift
│   ├── HUD/
│   │   ├── JarvisHUDPanel.swift           # borderless NSPanel skeleton
│   │   └── HUDBannerPanel.swift           # banner panel (Surface 5)
│   ├── Wizard/
│   │   ├── WizardView.swift               # SwiftUI root
│   │   ├── WizardStageAPIKeyView.swift
│   │   ├── WizardStageTCCView.swift
│   │   └── WizardStageHotkeyView.swift
│   └── Theme/
│       └── BrandColors.swift              # arcReactorGlow constants
├── packages/
│   ├── Config/        Package.swift, Sources/Config/, Tests/ConfigTests/
│   ├── Keychain/      Package.swift, Sources/Keychain/, Tests/KeychainTests/
│   ├── Logging/       Package.swift, Sources/Logging/, Tests/LoggingTests/
│   └── Shell/         Package.swift, Sources/Shell/, Tests/ShellTests/
├── scripts/
│   ├── codesign.sh
│   ├── verify-entitlements.sh
│   ├── verify-codesign-settings.sh   # lint for "Code Sign On Copy" on helper embeds
│   └── build-webview.sh              # stub; P3 fills in
└── .planning/
```

**Why `packages/Keychain` as a separate package** (and not just part of `Shell`): it's an independently testable security primitive, used by `packages/Config` to read the API key lazily. Splitting keeps the dependency graph acyclic: `Shell` depends on `Config`; `Config` depends on `Keychain`; `Keychain` depends on nothing but `Security.framework`.

---

## Architecture Patterns

### System Architecture Diagram — P1 Boundary

```
┌───────────────────────────────────────────────────────────────────────────┐
│                          Cold launch (Release build)                      │
└───────────────────────────┬───────────────────────────────────────────────┘
                            ▼
┌───────────────────────────────────────────────────────────────────────────┐
│   AppDelegate.applicationWillFinishLaunching:                             │
│     1. Logging.bootstrap() → swift-log MultiplexLogHandler installed      │
│     2. Read Info.plist JarvisEntitlementsVerified                         │
│        │                                                                  │
│        ├── false → NSAlert "Jarvis can't start" → NSApp.terminate         │
│        └── true  → continue                                               │
│     3. Config.loadSnapshots(from: ~/…/Jarvis/config.json)                 │
│        │                                                                  │
│        ├── malformed → NSAlert hard-block (D-19)                          │
│        ├── missing   → write default; re-load                             │
│        └── ok        → (launchSnapshot, perTurnSnapshot)                  │
│     4. Keychain.fetch(.anthropic)                                         │
│        └── missing → HUD banner "No API key configured"                   │
│     5. Install NSStatusItem + MenuBarIconController (state=.idle)         │
│     6. Install HUDPanel (orderOut; hidden until summoned)                 │
│     7. Install Hotkey: probe Input Monitoring via IOHIDRequestAccess      │
│        │                                                                  │
│        ├── granted   → addGlobalMonitorForEvents                          │
│        └── denied    → HUD banner + addLocalMonitorForEvents only         │
└───────────────────────────┬───────────────────────────────────────────────┘
                            │ (first launch OR Setup… menu item)
                            ▼
┌───────────────────────────────────────────────────────────────────────────┐
│   First-launch wizard (SwiftUI, modal until API key)                      │
│     Stage 1 (API key) → Keychain.set(.anthropic) + Anthropic models/list  │
│     Stage 2 (TCC)     → prompt Input Monitoring only (D-08); explainers   │
│                         for Mic / Camera / Automation                     │
│     Stage 3 (Hotkey)  → ShortcutRecorderView → config.hotkey written      │
└───────────────────────────┬───────────────────────────────────────────────┘
                            │
                            ▼
┌───────────────────────────────────────────────────────────────────────────┐
│   Steady-state idle:                                                      │
│     Menu bar icon visible; HUD panel hidden; hotkey armed.                │
│     Scrolling logs going to both ~/Library/Logs/Jarvis/ and os.Logger.    │
└───────────────────────────────────────────────────────────────────────────┘

Build-time phases (in order, same target):
  1. [Copy Bundle Resources]
  2. [Compile sources]
  3. [Link]
  4. [Run Script] scripts/codesign.sh          ← sign helpers deepest-first, main last
  5. [Run Script] scripts/verify-entitlements.sh ← grep + flip JarvisEntitlementsVerified=YES
  6. [Run Script] scripts/verify-codesign-settings.sh ← lint pbxproj for "Code Sign On Copy"
```

### Recommended Project Structure

See Standard Stack §Bundle layout above.

### Pattern 1 — AppDelegate entitlement hard-block

**What:** at `applicationWillFinishLaunching(_:)`, read `JarvisEntitlementsVerified` from `Info.plist`. If false/missing, show a `.critical` `NSAlert` (see UI-SPEC Surface 6 copy), terminate on Quit.

**When:** every cold launch. One-time cost, invisible on properly-built archives.

**Example:**

```swift
// App/AppDelegate.swift
import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        // 1. Bootstrap logs first so subsequent failures log.
        JarvisLogHandlerFactory.bootstrap()

        // 2. Entitlement hard-block.
        let verified = Bundle.main.object(forInfoDictionaryKey: "JarvisEntitlementsVerified") as? Bool ?? false
        if !verified {
            presentEntitlementFailureAlert()
            NSApp.terminate(nil)
            return
        }
        // 3. continue init…
    }

    private func presentEntitlementFailureAlert() {
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "Jarvis can't start"
        alert.informativeText = """
        A build verification check failed at launch. The app has been \
        stopped to prevent a crash.
        """
        alert.addButton(withTitle: "Quit")
        alert.addButton(withTitle: "Show Details")
        let response = alert.runModal()
        if response == .alertSecondButtonReturn {
            let log = URL(fileURLWithPath: (NSHomeDirectory() as NSString).appendingPathComponent("Library/Logs/Jarvis/system.log"))
            NSWorkspace.shared.open(log)
        }
    }
}
```

### Pattern 2 — Feature flags in `PerTurnSnapshot`

**What:** `FeatureFlags` struct is a `Codable` dictionary-backed key-value set. Readers call `flags.isEnabled("orpheusTTS")`.

**When to use:** risky or in-development tools, toggle per-dev-session. Examples for later phases: `orpheusTTSEnabled`, `whisperKitSTTEnabled`, `ollamaProvider`, `qwen3Opt-in` (permanently disabled per RESEARCH-DELTAS D3 but the flag mechanism exists).

**Why in PerTurnSnapshot not LaunchSnapshot:** non-security. Changing a feature flag at runtime applies at next `submit()` — matches the "toggleable without rebuild" NFR in OBS-05. Security-affecting flags do not exist (SEC-08).

### Anti-Patterns to Avoid

- **"Scaffold all eight packages now" — DON'T.** D-01: add packages as phases land. Creating empty `packages/Bus`, `packages/LLM`, etc. now invites mid-phase drift where the package exists but has no real product.
- **"Bootstrap `LoggingSystem` from package init" — DON'T.** `LoggingSystem.bootstrap(...)` is process-global. Exactly one call site, at `applicationWillFinishLaunching`. Package-level bootstrap is shared-mutable-state hell and breaks tests.
- **"Use the full Carbon hotkey registration" — DON'T.** `RegisterEventHotKey` drags the Input Monitoring TCC surface process-wide. `NSEvent.addGlobalMonitorForEvents` is narrower (R3-S4).
- **"Fall back to defaults silently on malformed config" — DON'T.** D-19: malformed config is a hard-block NSAlert. Silent fallback masks editing errors; worst case, a mistyped `ollama.base_url` gets replaced by the default (`127.0.0.1:11434`) and a user thinks their change was accepted.

---

## Don't Hand-Roll

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| Keychain item CRUD | "Custom encrypted file at `~/.../secrets.plist`" | `Security.framework` (`SecItemAdd` / `SecItemCopyMatching`) | OS-provided, hardware-backed on Apple Silicon, integrates with Touch ID/login keychain. |
| Launch-at-login | `launchd` plist drop into `~/Library/LaunchAgents/` | `SMAppService.mainApp.register()` | Apple-approved API; system manages the plist; visible to user in System Settings. |
| JSON decode | Custom parser | `JSONDecoder` + `Codable` | Standard library; hand-rolled parsers are error-prone edge-case magnets. |
| Global hotkey | Carbon `RegisterEventHotKey` + Carbon event taps | `NSEvent.addGlobalMonitorForEvents` + `addLocalMonitorForEvents` pair | Modern; smaller TCC footprint; AppKit-native. |
| Log rotation timer | `DispatchSource.makeTimerSource(queue:)` firing at midnight | Lazy rotation on first post-midnight write | No overhead on idle nights; no timer thread to manage. |
| Structured logging | Printf to stderr + custom file code | `apple/swift-log` + `MultiplexLogHandler` + `FileLogHandler` | Swift-log is the ecosystem standard; MultiplexLogHandler is built-in. |
| Entitlement verification | Runtime-only `SecStaticCodeCheckValidity` | Build-time grep on `codesign -d --entitlements -` | Earlier feedback; no runtime cost; integrates into build. |
| Schema migration | Ad-hoc "read-rewrite" | Explicit per-version migration functions with fixture tests | Forward-only; deterministic; auditable. |

---

## Common Pitfalls

These land in `PITFALLS.md` elsewhere; the P1-relevant subset, extracted:

### Pitfall 1 — `allow-jit` missing in Release archive

**What goes wrong:** Debug fine; Release cold-launch crashes in `JavaScriptCore::mprotect` before the wizard renders. Hides for the entire development cycle if you only test Debug.

**Why it happens:** Hardened Runtime on Apple Silicon kills any in-process JIT without the explicit entitlement.

**How to avoid:** day-one pin in `Jarvis.entitlements`; post-build grep in `verify-entitlements.sh`; runtime hard-block via `JarvisEntitlementsVerified` Info.plist key.

**Warning signs:** crash log cites `JavaScriptCore`, `mprotect`, `CS_KILL`. Debug-passed Release-archive-failed.

### Pitfall 2 — `speech-recognition-assets` entitlement missing

**What goes wrong:** first Release cold-launch on a fresh machine: `AssetInventory.status(...)` fails with `SFSpeechErrorCode.assetUnavailable` (or macOS 26 Code 10 variant); STT permanently broken, every voice query returns "I didn't catch that."

**Why it happens:** entitlement omitted from `Jarvis.entitlements` OR not enabled on App ID in Developer portal (Developer ID Application cert alone is insufficient).

**How to avoid:** pin in entitlements, pin `NSSpeechRecognitionAssetsUsageDescription` in Info.plist, enable capability on App ID in Developer portal (human step), run the Release-archive probe (Question 4) before phase completion.

**Warning signs:** STT silent in Release only; console shows `SFSpeechErrorCode.assetUnavailable` or `SFSpeechError Code=10 "Cannot use modules with unallocated locales"`.

### Pitfall 3 — `codesign --deep` or "Code Sign On Copy" on nested helpers

**What goes wrong:** outer bundle seal invalid OR per-helper entitlements stripped and replaced with parent's entitlements — so `mcp-applescript` silently loses `automation.apple-events` in P5; every AppleScript returns -1743.

**How to avoid:** `scripts/codesign.sh` walks helpers deepest-first without `--deep`. `verify-codesign-settings.sh` lints pbxproj for any `CodeSignOnCopy = YES` under a helper reference.

**Warning signs:** launch on dev works, Gatekeeper rejects on fresh machine; `codesign --verify --deep --strict` fails; AppleScript returns -1743 without TCC actually being denied.

### Pitfall 4 — Input Monitoring TCC silently denied → hotkey no-ops

**What goes wrong:** `NSEvent.addGlobalMonitorForEvents(.keyDown)` installs; user denies Input Monitoring; monitor becomes a no-op; user presses hotkey → nothing.

**How to avoid:** probe via `IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)` before/after first registration; denial → HUD banner + deep link + degraded mode using `addLocalMonitorForEvents` only.

**Warning signs:** hotkey works in Debug (persistent TCC), dead in Release on fresh install; no TCC prompt where expected; user reports "it just doesn't open."

### Pitfall 5 — Writing API key to a plaintext file

**What goes wrong:** API key persists in `UserDefaults` or `~/.../config.json`; disk backup → leaked key.

**How to avoid:** Keychain only (SEC-01); enforce by unit test on `Config` decode — `AnthropicAPIKey` is NOT a decodable field. SecureField → `keychain.set(.anthropic, …)` pipeline.

### Pitfall 6 — `webkit crashes` due to WKWebView loading content without allow-jit

**Same as Pitfall 1** but flagged separately because the P1 HUD panel hosts an empty WKWebView. P3 doesn't exist yet; even an empty WKWebView initializes JavaScriptCore.

---

## Runtime State Inventory

> P1 is greenfield. No rename/refactor/migration is happening. This section is intentionally omitted per the phase-researcher spec ("Omit entirely for greenfield phases").

---

## Environment Availability

| Dependency | Required By | Available | Version | Fallback |
|------------|------------|-----------|---------|----------|
| Xcode 16 (Swift 6) | All P1 build | Must be verified on user's machine before phase execution | 16.x expected | None — this is hard-blocker |
| macOS 26 Tahoe | Host OS for SpeechAnalyzer probe | User's current machine | macOS 26.x | Deployment target is macOS 13+; probe itself needs 26 |
| Apple Developer ID Application cert | Release archive signing | User's Apple Developer account | N/A | Not needed for Debug; required for the entitlement-stripped Release-archive probe |
| App ID with `speech-recognition-assets` capability enabled in Developer portal | Release archive, SpeechAnalyzer asset download | User action — enable capability on the App ID for `com.kingsrook.jarvis` in Apple Developer portal | N/A | Developer ID Application cert alone is **insufficient** (per CLAUDE.md and R2-S5). This is a one-time human step, not a code change |
| Xcode command-line tools (for `codesign`, `plutil`, `find`, `grep`) | `scripts/codesign.sh`, `scripts/verify-entitlements.sh` | Ships with Xcode | bundled | N/A |
| Anthropic API account (for wizard stage 1 validation) | `models/list` probe during wizard | User must have an API key | N/A | User can skip stage 1 (wizard detects missing key and allows skip on re-entry only; blocks on first launch per D-06) |

**Missing dependencies with no fallback:**
- App ID capability enablement is a **manual human step** in the Apple Developer portal. The planner must include a task that calls this out as an action the user takes outside the build. Omitting it means the Release archive passes the codesign step but the `speech-recognition-assets` entitlement silently isn't honored at runtime (since Apple validates against the App ID in their portal database, not just the cert).

---

## Validation Architecture

> `workflow.nyquist_validation = true` — this section is required.

### Test Framework

| Property | Value |
|----------|-------|
| Framework | XCTest (per D-03: package-author's discretion; we default to XCTest for consistency) |
| Config file | Each package's `Package.swift` declares a `testTarget` |
| Quick run command | `xcodebuild test -scheme <PackageName> -destination 'platform=macOS'` |
| Full suite command | `xcodebuild test -project Jarvis.xcodeproj -scheme JarvisTestsAll -destination 'platform=macOS'` |
| Release-archive probes | `xcodebuild archive -scheme Jarvis -configuration Release -archivePath build/Jarvis.xcarchive && scripts/verify-entitlements.sh build/Jarvis.xcarchive/Products/Applications/Jarvis.app` |

### Phase Requirements → Test Map

Each req gets ≥ 2 angles (happy + adversarial). "Shell" = verified by shell script; "XCT" = XCTest unit; "Probe" = one-shot XCTest on stripped-entitlement Release archive; "Manual" = human-executed on physical machine (flagged for why it can't be automated).

| Req ID | Behavior | Type | Automated command(s) | File exists? |
|--------|----------|------|---------------------|--------------|
| SHELL-01 | Menu-bar item visible on launch | XCT: `MenuBarIconControllerTests.test_statusItemInstalledOnLaunch` | `xcodebuild test -scheme Shell` | ❌ Wave 0 |
|  | Icon animates state transitions without flicker | Manual (visual inspection) — scaffold-time only | N/A | N/A |
| SHELL-02 | Hotkey ships unset | XCT: `HotkeyBindingTests.test_defaultHotkeyIsUnset` | `xcodebuild test -scheme Shell` | ❌ Wave 0 |
|  | Shortcut-recorder rejects modifier-only | XCT: `ShortcutRecorderTests.test_modifierOnlyRejected` | same | ❌ Wave 0 |
| SHELL-03 | LSUIElement=YES; NSPanel is borderless | Shell: `verify-entitlements.sh` greps Info.plist `LSUIElement` == YES | build-time | ❌ Wave 0 |
|  | Launch-at-login register/unregister idempotent | XCT: `LaunchAtLoginTests.test_registerUnregisterIdempotent` (gated on isolated test user — OR mock) | — | ❌ Wave 0 |
| SHELL-04 | `allow-jit` entitlement present | Shell: `verify-entitlements.sh` | build-time | ✅ (written in Q2) |
|  | WKWebView initializes without crash in Release | Manual (Release cold-launch on fresh machine; scaffold-time checkpoint) | N/A | N/A |
| SHELL-05 | `speech-recognition-assets` entitlement present + Info.plist key present | Shell: `verify-entitlements.sh` | build-time | ✅ |
|  | Entitlement is load-bearing (Release with entitlement stripped → AssetInventory fails) | Probe: `JarvisEntitlementProbeTests.test_missingEntitlement_producesAssetUnavailableOrLocaleAllocation` | Manual XCTest plan against stripped-entitlement Release archive | ❌ Wave 0 |
| SHELL-06 | Input Monitoring denial surfaces banner | XCT: `InputMonitoringDenialTests.test_bannerEnqueuedOnDenial` with a mock `HIDAccessProbe` | `xcodebuild test -scheme Shell` | ❌ Wave 0 |
|  | Local-monitor-only degraded mode works | XCT: same target, `test_localMonitorOnlyFallback` | same | ❌ Wave 0 |
| AGENT-05 | `ollama.base_url = http://evil.com/` rejected at decode | XCT: `LaunchSnapshotTests.test_ollamaBaseURLMustBeLocalhost` | `xcodebuild test -scheme Config` | ❌ Wave 0 |
|  | `http://127.0.0.1:11434` accepted | XCT: same target, happy path | same | ❌ Wave 0 |
| MCP-05 | `Contents/Helpers/` directory exists in built bundle | Shell: `verify-entitlements.sh` (add a dir-exists check) | build-time | Modify Q2 script |
|  | Directory is empty in P1 | Shell: same script counts entries | build-time | Same |
| MCP-06 | Post-build entitlement-grep phase fails on missing entitlement | Shell: fault-injection test — `test-fixtures/broken-entitlements.plist` → script exits non-zero | CI job `scripts/test-verify-entitlements.sh` | ❌ Wave 0 |
|  | No `--deep` flag anywhere in pbxproj | Shell: `scripts/verify-codesign-settings.sh` greps pbxproj | build-time | ❌ Wave 0 |
|  | No "Code Sign On Copy" under any Helpers embed | Shell: same script | build-time | Same |
| OBS-05 | Feature flag toggle applies at next submit | XCT: `PerTurnSnapshotTests.test_featureFlagAppliesNextSubmit` (with mock orchestrator) | `xcodebuild test -scheme Config` | ❌ Wave 0 |
|  | Feature flag in LaunchSnapshot fails decode | XCT: `LaunchSnapshotTests.test_featureFlagsNotInLaunchSnapshot` (attempts to decode with unknown key → error) | same | ❌ Wave 0 |
| OBS-06 | Four channels `Logger(label:)` each produce to both handlers | XCT: `LoggingTests.test_fourChannelsMultiplexToFileAndOSLog` (uses temp dir + mock os.Logger) | `xcodebuild test -scheme Logging` | ❌ Wave 0 |
|  | `redact()` masks all 5 patterns; doesn't touch non-matches | XCT: `RedactTests.test_allFivePatterns` + `test_plainTextUnchanged` | same | ❌ Wave 0 |
|  | File rotation at midnight retain 7 | XCT: `FileLogHandlerTests.test_rotatesAtDayBoundary` (inject a `TestDateProvider`) + `test_deletesBeyondSeven` | same | ❌ Wave 0 |
| SEC-01 | API key round-trips through Keychain | XCT: `KeychainTests.test_setGetDeleteRoundTrip` | `xcodebuild test -scheme Keychain` | ❌ Wave 0 |
|  | API key never written to `UserDefaults` or plaintext file | XCT: `ConfigTests.test_apiKeyNotInConfigJSON` (asserts decoded `LaunchSnapshot` has no API-key field) | `xcodebuild test -scheme Config` | ❌ Wave 0 |
| SEC-02 | Duplicate of SHELL-04 | See SHELL-04 | — | — |
| SEC-03 | Duplicate of SHELL-05 + App ID capability enabled | Manual step (planner task: document in STATE.md) | N/A | — |
| SEC-04 | P1 prompts only Input Monitoring; other TCC are explainers | XCT: `WizardTCCStageTests.test_onlyInputMonitoringTriggers` (with mocked TCC probe) | `xcodebuild test -scheme Shell` | ❌ Wave 0 |
| SEC-05 | Launch vs PerTurn split enforced | XCT: `ConfigSplitTests.test_securityKeysInLaunchOnly` + `test_nonSecurityKeysInPerTurnOnly` | `xcodebuild test -scheme Config` | ❌ Wave 0 |
| SEC-08 | `applescript.skipAllowlist` key does not exist in any schema | XCT: `ConfigTests.test_noSkipAllowlistKey` (introspects `LaunchSnapshot`/`PerTurnSnapshot` field lists via reflection) | `xcodebuild test -scheme Config` | ❌ Wave 0 |

### Sampling Rate

- **Per task commit:** run the affected package's tests only — `xcodebuild test -scheme <Package>` (< 10s for each P1 package).
- **Per wave merge:** run the full P1 test plan — `xcodebuild test -project Jarvis.xcodeproj -scheme JarvisTestsAll` (aggregate; ~30s expected at P1 scope).
- **Phase gate (before `/gsd-verify-phase 1`):** full suite green + scaffold-time probes (entitlement-grep Release + one-shot `JarvisEntitlementProbeTests` on stripped-entitlement archive) green.

### Wave 0 Gaps

Every test file listed above is a Wave 0 deliverable. None exist today. Also Wave 0:

- [ ] `packages/Config/Tests/ConfigTests/LaunchSnapshotTests.swift`
- [ ] `packages/Config/Tests/ConfigTests/PerTurnSnapshotTests.swift`
- [ ] `packages/Config/Tests/ConfigTests/ConfigSplitTests.swift`
- [ ] `packages/Keychain/Tests/KeychainTests/KeychainTests.swift`
- [ ] `packages/Logging/Tests/LoggingTests/RedactTests.swift`
- [ ] `packages/Logging/Tests/LoggingTests/FileLogHandlerTests.swift`
- [ ] `packages/Logging/Tests/LoggingTests/LoggingTests.swift` (bootstrap + multiplex)
- [ ] `packages/Shell/Tests/ShellTests/MenuBarIconControllerTests.swift`
- [ ] `packages/Shell/Tests/ShellTests/ShortcutRecorderTests.swift`
- [ ] `packages/Shell/Tests/ShellTests/HotkeyBindingTests.swift`
- [ ] `packages/Shell/Tests/ShellTests/InputMonitoringDenialTests.swift`
- [ ] `packages/Shell/Tests/ShellTests/LaunchAtLoginTests.swift`
- [ ] `packages/Shell/Tests/ShellTests/WizardTCCStageTests.swift`
- [ ] **One-shot probe plan:** `App/Tests/JarvisEntitlementProbeTests/JarvisEntitlementProbeTests.swift` — excluded from default test plan; invoked by a dedicated `EntitlementProbe` xcscheme
- [ ] `scripts/codesign.sh`, `scripts/verify-entitlements.sh`, `scripts/verify-codesign-settings.sh` — the script themselves AND a tiny self-test harness in `scripts/test-verify-entitlements.sh` that injects broken fixtures

---

## Security Domain

> `security_enforcement` is enabled by default (no explicit `false` in config.json).

### Applicable ASVS Categories

| ASVS Category | Applies | Standard Control |
|---------------|---------|-----------------|
| V2 Authentication | yes | macOS Keychain for the sole credential (Anthropic API key) — OS-level auth via login keychain. No passwords. |
| V3 Session Management | no | Single-user, local-only; no sessions. |
| V4 Access Control | yes | TCC + entitlements + `Contents/Helpers/` per-helper identity separation (mostly P5; P1 scaffolds the layout) |
| V5 Input Validation | yes | `OllamaConfig.init(from:)` validates `baseURL` host ∈ `{127.0.0.1, localhost, ::1}` at decode (AGENT-05). Malformed config → NSAlert hard-block. |
| V6 Cryptography | yes | Delegated to Keychain (OS-level). Never hand-roll. |
| V7 Errors & Logging | yes | `redact()` covers API keys + Authorization headers + AWS + GitHub tokens (OBS-06 / D-20). File handler applies redact before write. |
| V8 Data Protection | yes | Secrets in Keychain only; config in `~/Library/Application Support/Jarvis/` (user-scoped). |
| V9 Communications | yes (scaffolded) | HTTPS enforced by URLSession defaults; Ollama base URL constrained to localhost (AGENT-05). Anthropic API calls happen in P4. |
| V14 Configuration | yes | Launch/PerTurn split (SEC-05); malformed config hard-blocks; no skip-allowlist (SEC-08). |

### Known Threat Patterns for this stack

| Pattern | STRIDE | Standard Mitigation |
|---------|--------|---------------------|
| API key exfil via JS heap in WKWebView | Information Disclosure | Native SwiftUI `SecureField` only; key never flows to webview (SEC-01) |
| Plaintext API key in `config.json` | Information Disclosure | Keychain-only path; unit test asserts key is NOT a `LaunchSnapshot` field |
| Release-only crash from missing `allow-jit` | Denial of Service | Day-one entitlement + build-time grep + runtime `JarvisEntitlementsVerified` hard-block |
| Silent STT failure from missing `speech-recognition-assets` | Denial of Service | Day-one entitlement + Info.plist key + Developer portal App ID capability + scaffold-time probe |
| Malicious same-user process rewrites `config.json` | Tampering | Launch-snapshot boundary — security keys require restart; AGENT-05 constrains Ollama URL; SEC-08 forbids skip-allowlist |
| Input Monitoring silent denial | Denial of Service | Probe + HUD banner + degraded mode |
| Log file leaks API key due to unredacted write | Information Disclosure | `redact()` at file-handler boundary; OBS-06 pattern set |
| Helper bundle entitlements stripped by Code-Sign-On-Copy | Elevation of Privilege (the main app gains AppleScript entitlement it shouldn't have; or the helper loses it and fails silently) | Forbid `--deep`; forbid Code-Sign-On-Copy; post-build grep |

---

## Assumptions Log

| # | Claim | Section | Risk if Wrong |
|---|-------|---------|---------------|
| A1 | `AssetInventory.status(forModules:)` is the lightweight entitlement probe that fails fastest without requiring an asset download | Q4 SpeechAnalyzer probe | If false, the probe may take longer (could require actual audio feed) or might not fire without network access. Fallback: seed the probe with a 100 ms silence `AVAudioBuffer` and call `SpeechAnalyzer.start(inputSequence:)` — the approach originally suggested by PITFALLS §12. |
| A2 | Without `speech-recognition-assets` entitlement, `SFSpeechErrorCode.assetUnavailable` (code 1) OR `SFSpeechError Code=10` ("Cannot use modules with unallocated locales") fires | Q4; RESEARCH-DELTAS | If false (e.g. the claim is entirely speculative and no error fires), the probe needs a different detection mechanism — perhaps `AssetInventory.status` returns `.unavailable` without throwing. The XCTest must catch all three conditions (throw / `.unavailable` / `.unsupported`) and consider any of them "confirmed." Already documented in the probe code. |
| A3 | `MultiplexLogHandler` from `apple/swift-log` 1.5.3+ exists and fans out synchronously to multiple handlers on every `log(...)` call | Q3 | HIGH-confidence — confirmed via Context7 swift-log docs and the library's public API. Not really an assumption. |
| A4 | The Xcode "Code Sign On Copy" flag corresponds to `CodeSignOnCopy = YES` in the pbxproj file under `PBXBuildFile` entries | Q2 | This is the documented mapping. Low risk of being wrong — has been stable since Xcode 11. If wrong, the `verify-codesign-settings.sh` regex needs updating. |
| A5 | `SMAppService.mainApp.register()` on macOS 26 Tahoe behaves identically to macOS 13+ | Q9 | MEDIUM-confidence — no macOS-26-specific issues have surfaced in searched sources. If Tahoe changed the semantics (e.g. added a new status code), `LaunchAtLogin` would need a small update; not a P1 blocker. |
| A6 | `LSUIElement=YES` is honored even when the app has an NSPanel visible on screen (i.e., the panel doesn't somehow force a Dock entry) | Bundle layout | HIGH-confidence — `LSUIElement=YES` is respected by all window types including `NSPanel`. |
| A7 | `Security.framework` calls are safe from a Swift 6 strict-concurrency perspective (no data-race diagnostics) | Q1 | HIGH-confidence — C-based `SecItem*` calls are `@unchecked Sendable` from the Swift 6 language mode's perspective when wrapped in a `struct`. If the compiler complains, wrap `SystemKeychainStore` as `struct … : @unchecked Sendable`. |

---

## Open Questions / Pitfalls

1. **`speech-recognition-assets` load-bearing claim** — RESEARCH-DELTAS explicitly flags this as externally unverified. The scaffold-time probe (Q4) is load-bearing. If the probe shows the entitlement is NOT load-bearing (STT works without it), we can:
   - (a) remove the entitlement from `Jarvis.entitlements` (but keep the Info.plist key, which is independently documented);
   - (b) document the finding in STATE.md and RESEARCH-DELTAS.
   Either way, **including the entitlement is cheap**; omitting it risks a Release-only first-use STT break. Keep the entitlement; let the probe result refine the story.

2. **Developer portal App ID capability** — enabling `speech-recognition-assets` capability on the `com.kingsrook.jarvis` App ID is a **manual step** in [developer.apple.com](https://developer.apple.com/). The planner must include a task for this — it's not a code change. If the cert includes the capability but the App ID doesn't, Apple's runtime entitlement validation will silently reject the entitlement at launch on a fresh Mac (reason: entitlements the App ID doesn't authorize aren't effective even if they're in the signed binary).

3. **macOS 26 beta behavior of SpeechAnalyzer** — reports (Apple Developer Forums thread 790108; `macOS Tahoe 26.4.1` Forums; dotnet/macios Speech wiki) mention ongoing init issues on early macOS 26 betas — "unallocated locales" errors, simulator empty `supportedLocales`, `_GenericObjCError` from `start(inputSequence:)`. These appear beta-era; the user's current macOS 26 build should be post-beta. The probe code is conservative — it catches any of the three error conditions as confirmation.

4. **`os.Logger` redaction discipline** — the `redact()` hook lives only in `FileLogHandler` (Q3). That means a raw-secret passed as a `Logger.Message` to any `Logger(label:)` call WILL show up in Console.app / `log stream`. Discipline is: callers call `redact()` themselves when the input is untrusted (e.g. HTTP header dump, tool-result content). The file-handler redact is defense-in-depth. The planner should add a lint rule or code-review checklist item: "log statements with variables must call `redact(...)` or explicitly mark the variable as non-secret."

5. **Wizard modal behavior on Spaces + fullscreen apps** — the first-launch wizard is modal (`NSWindow.level = .modalPanel`). If the user launches Jarvis for the first time while a fullscreen app (e.g. Xcode in fullscreen) is frontmost, does the wizard surface correctly? UI-SPEC Surface 1 says `[.titled, .closable]` without special Space behavior. Likely fine (modal panel shows up on the active Space), but worth a one-line manual verification on the scaffold-time checklist.

6. **`DispatchSource.makeFileSystemObjectSource` for config-file watching** — a file watcher on `config.json` fires on user edits (Q5 restart-required enforcement). On macOS, the source fires on `.write | .rename | .delete`. If user deletes the file (via `rm`), we should treat it as "missing → write defaults" not "config disappeared." Handle each event type.

7. **`statusItem.button?.layer` may be nil during animation installation on the very first launch** — if we call `transition(to:)` before the button fully materializes (e.g. synchronously during `applicationDidFinishLaunching`), the layer may not yet exist. Mitigation: `MenuBarIconController.configureButtonLayer()` must be called after a `DispatchQueue.main.async` to let AppKit finish layout, OR we trigger the first state animation only after the first `.idle` state is explicitly set post-launch.

8. **The `verify-entitlements.sh` writes `JarvisEntitlementsVerified` into a signed bundle** — writing to `Info.plist` via `plutil -replace` AFTER codesign invalidates the signature. Correct order is: (a) `plutil -replace JarvisEntitlementsVerified -bool NO` at build time in a pre-codesign phase; (b) run `scripts/codesign.sh`; (c) run `scripts/verify-entitlements.sh` which **only reads**, never writes; (d) for the "YES" flip, actually do it in a **pre-codesign phase** after the grep passes. **Correction to Q2 snippet:** move the `plutil -replace JarvisEntitlementsVerified -bool YES` into a pre-codesign phase so it's part of the signed content. Update the planner's build-phase order accordingly:
   1. Compile / Link
   2. Run Script: `scripts/verify-entitlements.sh --pre-codesign` (reads Entitlements file + Info.plist on disk; if OK, writes `JarvisEntitlementsVerified=YES` to the not-yet-signed Info.plist)
   3. Run Script: `scripts/codesign.sh`
   4. Run Script: `scripts/verify-entitlements.sh --post-codesign` (reads signed entitlements via `codesign -d`; final assurance)
   This is a one-line correction to the Q2 script that the planner needs to apply.

---

## State of the Art

| Old Approach | Current Approach | When Changed | Impact |
|--------------|------------------|--------------|--------|
| `SMLoginItemSetEnabled` for launch-at-login | `SMAppService.mainApp.register()` | macOS 13 Ventura | Use the new API; old is deprecated |
| Carbon `RegisterEventHotKey` for global hotkey | `NSEvent.addGlobalMonitorForEvents` | macOS 10.10+ for the API; R3-S4 prefers it over Carbon for TCC surface | Smaller TCC footprint |
| `WKWebView` Debug testing only | Release-archive smoke test day one | macOS 12+ Hardened Runtime enforcement | Or you learn `allow-jit` the hard way |
| Hand-written JSON-RPC for MCP | Official `modelcontextprotocol/swift-sdk` v0.12.0 | 2026 Q1 | P5 scope; noted for P1 `Contents/Helpers/` layout prep |

**Deprecated / outdated:**
- `SMLoginItemSetEnabled` — deprecated macOS 13+; replaced by `SMAppService`.
- `HotKey` SPM — functional but narrower use cases; `NSEvent` pair preferred.
- Xcode workspace for this project shape — D-05 locks `.xcodeproj` + local SPM.

---

## Sources

### Primary (HIGH confidence)

- [Context7: /apple/swift-log — `MultiplexLogHandler`, `LoggingSystem.bootstrap`, metadata providers](https://github.com/apple/swift-log) — consulted 2026-04-22
- [Apple Developer: `SMAppService.mainApp`](https://developer.apple.com/documentation/servicemanagement/smappservice/mainapp) — consulted 2026-04-22
- [Apple Developer: `SpeechAnalyzer`](https://developer.apple.com/documentation/speech/speechanalyzer) — consulted 2026-04-22
- [Apple Developer: `SpeechTranscriber`](https://developer.apple.com/documentation/speech/speechtranscriber) — consulted 2026-04-22
- [Apple Developer: `SpeechTranscriber.supportedLocales`](https://developer.apple.com/documentation/speech/speechtranscriber/supportedlocales) — consulted 2026-04-22
- [Apple Developer: Security framework — keychain services](https://developer.apple.com/documentation/security/keychain_services) — training knowledge + search
- [`codesign(1)` manual page — Keith's xcode-man-pages mirror](https://keith.github.io/xcode-man-pages/codesign.1.html) — consulted 2026-04-22
- [Apple Technical Note TN2206 — macOS Code Signing In Depth](https://developer.apple.com/library/archive/technotes/tn2206/_index.html) — consulted 2026-04-22
- [Apple Developer: WWDC 2025 session 277 — SpeechAnalyzer](https://developer.apple.com/videos/play/wwdc2025/277/) — referenced in search
- [Apple Developer: SMAppService.Status.requiresApproval](https://developer.apple.com/documentation/servicemanagement/smappservice/status-swift.enum/requiresapproval) — consulted 2026-04-22

### Secondary (MEDIUM confidence)

- [iOS 26 SpeechAnalyzer Guide — Anton Gubarenko (Substack)](https://antongubarenko.substack.com/p/ios-26-speechanalyzer-guide) — consulted 2026-04-22; practitioner guide, beta-era but current
- [otaviocc/Stenographer (GitHub)](https://github.com/otaviocc/Stenographer) — referenced as a practical SpeechAnalyzer example; confirmed as reference in RESEARCH-DELTAS
- [`sindresorhus/KeyboardShortcuts` — RecorderCocoa.swift patterns](https://github.com/sindresorhus/KeyboardShortcuts/blob/main/Sources/KeyboardShortcuts/RecorderCocoa.swift) — consulted 2026-04-22 for internal shortcut-recorder patterns (NOT used as SPM)
- [onmyway133 — How to rotate NSStatusItem](https://onmyway133.com/posts/how-to-rotate-nsstatusitem/) — consulted 2026-04-22
- [Apple Developer Forums thread 88341 — animating NSStatusItem](https://developer.apple.com/forums/thread/88341) — consulted 2026-04-22
- [rsms — macOS distribution, codesigning notes](https://gist.github.com/rsms/929c9c2fec231f0cf843a1a746a416f5) — consulted 2026-04-22
- [theevilbit — SMAppService Quick Notes](https://theevilbit.github.io/posts/smappservice/) — consulted 2026-04-22
- [VersionedCodable pattern — joro.dev](https://joro.dev/posts/versioned-codable/) — consulted 2026-04-22
- [Krzysztof Zabłocki — versioning Codable](https://www.merowing.info/adding-support-for-versioning-and-migration-to-your-codable-models-/) — consulted 2026-04-22
- [Apple Developer Forums thread 790108 — SpeechAnalyzer WWDC discussion](https://developer.apple.com/forums/thread/790108) — consulted 2026-04-22

### Tertiary (LOW confidence, flagged for validation)

- [MacRumors thread: `macOS Tahoe 26.4.1`](https://forums.macrumors.com/threads/macos-tahoe-26-4-1-bug-fixes-changes-and-more.2480698/) — referenced for community reports of SpeechAnalyzer behavior on specific macOS 26 builds; not authoritative
- [dotnet/macios Speech wiki](https://github.com/dotnet/macios/wiki/Speech-macOS-xcode26.0-b1) — referenced for API surface sanity-check; reflects .NET bindings, not Swift-native, but useful for cross-checking public API shape

---

## Metadata

**Confidence breakdown:**

- Standard stack: HIGH — versions pinned in RESEARCH-DELTAS and confirmed current 2026-04
- Architecture (Pattern 1, 2, anti-patterns): HIGH — all decisions traceable to CONTEXT.md Decisions (D-01..D-20) and UI-SPEC
- Entitlements & codesign: HIGH — TN2206 + deepest-first walk is industry-standard
- Keychain choice: HIGH — raw API is widely used; 60 LOC is small
- swift-log wiring: HIGH — Context7 confirms `MultiplexLogHandler` + metadata providers
- File rotation: HIGH — hand-rolled is D-18 exact fit
- SpeechAnalyzer probe: **MEDIUM** — Apple docs don't fully spec entitlement-gated init; probe catches multiple error conditions as fallback; RESEARCH-DELTAS carry-over
- Shortcut-recorder hand-roll: HIGH — mirrors `sindresorhus/KeyboardShortcuts` internals
- Menu-bar icon animation: HIGH — DevForums thread + onmyway133 document the gotchas
- SMAppService: HIGH — established API, 13+ years deployed
- Config schema versioning: HIGH — established Codable pattern

**Research date:** 2026-04-22
**Valid until:** 2026-07-22 (90 days; Apple's macOS 26 Tahoe API surface may stabilize further; Swift 6 strict-concurrency diagnostics may change — re-check at any minor Xcode rev).
