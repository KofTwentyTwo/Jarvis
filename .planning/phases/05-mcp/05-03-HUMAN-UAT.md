---
phase: 05-mcp
plan: 03
type: human-action
blocking: false
gates: [Release archive notarization for mcp-applescript helper]
downstream_phases_unblocked_without_this:
  - "Phase 5 Wave 4 (05-04 sanitize + MCPToolDispatcher) — operates on Debug builds; no Release notarization required"
  - "Phase 5 Wave 5 (05-05 confirmation broker + presenter wiring) — same"
  - "Phase 6 (Voice) — uses Debug builds for development; Release archive packaging is Phase 8 territory"
  - "Phase 7 (Memory + Vision) — same"
  - "Phase 8 (Hardening) — this is where Release archive notarization first becomes a hard gate; that's the phase that should re-trigger this UAT"
---

# 05-03 HUMAN-UAT — App ID capability registration for mcp-applescript

## What the human needs to do

Before a **Release archive** of `Jarvis.app` can be notarized with a bundled `mcp-applescript.app` carrying `com.apple.security.automation.apple-events`, the App ID for that helper must be registered at developer.apple.com with the matching capability enabled.

### Steps

1. Sign in at https://developer.apple.com/account/ with the team that owns Developer Team ID `7UC2HETAN9` (the value pinned at `project.yml` Release config and on the helper's Release config).
2. Navigate to **Certificates, Identifiers & Profiles → Identifiers**.
3. Either:
   - **Register a new App ID** with bundle ID `com.koftwentytwo.jarvis.mcp-applescript`, OR
   - **Edit the existing App ID** if one was created previously.
4. In the App ID's capabilities section, enable **"App Sandbox"** is NOT required (the helper does NOT sandbox), but enable:
   - **Apple Events Sandbox Exception (Automation)** — this is the developer.apple.com surface that backs the `com.apple.security.automation.apple-events` runtime entitlement. Without it, AppleEvent error -1743 (`errAEEventNotPermitted`) returns on first execution with NO TCC prompt.
5. Save.
6. (For the same human session if Release archive is the next goal:) Make sure a **Developer ID Application** certificate exists in the team's keychain — this is the same gating constraint that BLOCKED Phase 1 Task 4's speech-recognition-assets capability live verification.

### Verification command (after registration + Release build)

```bash
# After running:  xcodebuild -project Jarvis.xcodeproj -scheme Jarvis -configuration Release archive
# the archived .app should contain a bundled and notarization-ready helper.
codesign -d --entitlements - --xml \
  /path/to/Jarvis.xcarchive/Products/Applications/Jarvis.app/Contents/Helpers/mcp-applescript.app \
  | grep -c 'com.apple.security.automation.apple-events'
# expect: 1
```

## Why this is a human action

The developer.apple.com Identifiers UI is not scriptable; capability registration must be done by the human team-admin signed into the Apple Developer account. This is the same pattern as Phase 1 Task 4's speech-recognition-assets capability registration — both require human action at developer.apple.com that is NOT automatable.

## What works WITHOUT this UAT being completed

The autonomous parts of Plan 05-03 land cleanly without this human action:

- ✅ `swift test --package-path mcp-servers/mcp-applescript` — 4/4 pass
- ✅ `swift build --package-path mcp-servers/mcp-applescript -c release` — exit 0
- ✅ `xcodebuild -project Jarvis.xcodeproj -scheme Jarvis -configuration Debug build` — exit 0
- ✅ Debug ad-hoc-signed `Jarvis.app/Contents/Helpers/mcp-applescript.app` runs and the post-codesign verifier reports "helper 'mcp-applescript' entitlements OK"
- ✅ `scripts/test-verify-entitlements.sh` — PASS=6 FAIL=0
- ✅ Phase 5 Waves 4 and 5 (05-04, 05-05) operate on Debug builds and do not need Release notarization

What DOESN'T work until this UAT is completed:

- ❌ `xcodebuild archive -configuration Release` will produce an archive whose `mcp-applescript.app` cannot be notarized — Apple's notary service rejects bundles whose entitlements are not backed by registered App ID capabilities.
- ❌ Live execution of any AppleScript from inside the helper at runtime under TCC — without the developer.apple.com capability AND a Developer ID Application identity in the keychain, AppleEvent error -1743 returns from `NSAppleScript.executeAndReturnError(_:)` with NO user-facing TCC prompt. This is the silent-permission-gap footgun (T-05-03-02 / Pitfall #6).

## Where this gate first becomes blocking

**Phase 8 (Hardening).** That phase is where Release archive notarization first becomes a hard gate for end-user delivery. When you reach the Phase 8 plan that builds the notarized archive, re-trigger this UAT.

Until then, Debug builds are sufficient for Plans 05-04, 05-05, and all of Phase 6 / 7.

## Self-check before claiming done

After completing the developer.apple.com registration:

- [ ] Bundle ID `com.koftwentytwo.jarvis.mcp-applescript` listed under Identifiers → App IDs.
- [ ] "Apple Events Sandbox Exception (Automation)" capability shows as enabled in that App ID's capability list.
- [ ] A Release-config `xcodebuild archive` produces an archive whose `Contents/Helpers/mcp-applescript.app` carries the apple-events entitlement (verified via `codesign -d --entitlements -`).
- [ ] (When the orchestrator wires up `run_applescript` in Plan 05-05) first runtime invocation produces a System Settings → Privacy & Security → Automation prompt for `mcp-applescript`, NOT an instant -1743 failure.
