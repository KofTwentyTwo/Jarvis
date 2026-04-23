---
status: diagnosed
trigger: "xcodebuild test -scheme Jarvis -only-testing:JarvisAppTests fails with Runningboard error 5 / Launchd job spawn failed on macOS 26.4 + Xcode 26.4"
created: 2026-04-22
updated: 2026-04-23
---

## Symptom

`xcodebuild test -scheme Jarvis -only-testing:JarvisAppTests` exits with:

```
Could not launch "JarvisAppTests"
Jarvis encountered an error (Failed to install or launch the test runner.
  (Underlying Error: Could not launch "JarvisAppTests". Runningboard has returned error 5.
    (Underlying Error: The operation couldn't be completed. Launch failed.
      (Underlying Error: Launchd job spawn failed))))
```

`xcodebuild build-for-testing` succeeds (exit 0). The failure is at **test-host launch time**,
not build or sign time. Per-SPM-package `swift test` suites are all green (49/49).

## Environment

- macOS 26.3.1 (25D771280a) — Tahoe
- Xcode 26.4.1 (build 17E202)
- Swift 6.3.1 / Swift driver 1.148.6, target `arm64-apple-macosx26.0`
- Bundle under test: `/Users/james.maes/Library/Developer/Xcode/DerivedData/Jarvis-epvkfnglpgagkvdoxtgqecqudqwr/Build/Products/Debug/Jarvis.app`
- Signing: **ad-hoc** (`CODE_SIGN_IDENTITY: "-"`, `CODE_SIGNING_ALLOWED=NO` on Debug, `scripts/codesign.sh` runs as post-build phase)

## Investigation Steps

1. **Versions / toolchain** (`sw_vers`, `xcodebuild -version`, `swift --version`) — recorded above.
2. **Inspected signed Debug bundle entitlements** via
   `codesign -d --entitlements - Contents/MacOS/Jarvis`:
   ```xml
   com.apple.developer.speech-recognition-assets = true
   com.apple.security.cs.allow-jit              = true
   com.apple.security.device.audio-input        = true
   ```
   Codesign flags: `0x10002(adhoc,runtime)` — hardened runtime ON, ad-hoc signature, no `get-task-allow`.
3. **Triggered the failure** (`xcodebuild test …`) and scraped the system log immediately after:
   ```
   amfid: /…/Jarvis.app/Contents/MacOS/Jarvis not valid:
     Error Domain=AppleMobileFileIntegrityError Code=-420 "The signature on the file is invalid"
   kernel: (AppleMobileFileIntegrity) AMFI: When validating /…/Jarvis:
     Code has restricted entitlements, but the validation of its code signature failed.
     Unsatisfied Entitlements:
   kernel: proc 96920: load code signature error 4 for file "Jarvis"
   kernel: (AppleSystemPolicy) ASP: Security policy would not allow process: 96920, /…/Jarvis
   ```
   RunningBoard's error 5 / launchd spawn failure is a **downstream symptom** — the real rejection
   is from AMFI in the kernel, before RunningBoard even sees a live task.
4. **Reviewed the scaffold commit** (98c58f0) whose message explicitly documents:
   > "Add CODE_SIGNING_ALLOWED=NO for Debug only because the managed
   > speech-recognition-assets entitlement requires a provisioning profile;
   > Release signing is wired properly in Plan 05"
   This is the same failure mode the team already acknowledged at project scaffold.
5. **Walked the 16 fix commits** (`c735912..4abce0a`) — none touch `App/Jarvis.entitlements`,
   `project.yml` signing config, or `scripts/codesign.sh`. The "was passing 25/25 earlier" claim
   in the orchestrator context does not match git history: `01-HUMAN-UAT.md` (committed prior to
   the 16 fixes) already records this exact `xcodebuild test` failure.
6. **Cross-checked the prior UAT's "Testing.framework seal" theory** — the
   `x86_64-apple-ios-macabi.swiftinterface` warning comes from `codesign --verify --deep --strict`
   traversing Apple's bundled frameworks. It is a red herring: our failure is AMFI on
   the Jarvis main binary, not any nested Apple framework.

## Root Cause (high confidence)

**`com.apple.developer.speech-recognition-assets` is a managed / restricted entitlement.**
AMFI requires restricted entitlements to be backed by either:
- a provisioning profile embedded in the app, OR
- a Developer ID Application signature with the capability provisioned on the team.

Our Debug bundle is **ad-hoc signed** (`Signature=adhoc`, `TeamIdentifier=not set`). AMFI sees
a restricted entitlement on an unprovisioned binary, marks the signature invalid with
error -420 (`The signature on the file is invalid`), and the kernel refuses to load the binary
via `mac_vnode_check_signature`. launchd's spawn fails, RunningBoard returns error 5 to the
Xcode test driver, and we see the cascaded error chain.

This is independent of `get-task-allow`. Even though XCTest on a hardened host normally also
wants `get-task-allow` for debugger attach, that's a secondary issue — the binary never loads
far enough for debug-attach to matter.

## Recommended Fix

Two clean options; pick one based on phase priorities:

**A. Strip the restricted entitlement from Debug only (unblocks XCTest immediately).**
Add a Debug-only entitlements variant that omits `com.apple.developer.speech-recognition-assets`
and keep it for Release. Since Debug doesn't run the speech-recognition code path against real
on-device assets, dropping the entitlement on Debug is safe. Concrete approach:
- `App/Jarvis.Debug.entitlements` (no speech-recognition-assets, adds `com.apple.security.get-task-allow`)
- `App/Jarvis.Release.entitlements` (current file)
- `project.yml` Debug: `CODE_SIGN_ENTITLEMENTS: App/Jarvis.Debug.entitlements`
- `scripts/codesign.sh` continues unchanged — it already reads `$CODE_SIGN_ENTITLEMENTS`'s resolved path.
- `scripts/verify-entitlements.sh` needs a Debug-configuration branch (currently asserts
  speech-recognition-assets is present — that assertion must become configuration-aware or
  be marked Release-only).

**B. Provision Debug with a real Developer ID Apple Development signature.**
Requires the Apple Developer Portal to actually expose the speech-recognition-assets capability
for the app ID (per `01-HUMAN-UAT.md` §1 it currently does not — "portal UI availability issue"),
so this is blocked on Apple. Once provisioned, switch `CODE_SIGN_IDENTITY` on Debug from `"-"` to
`"Apple Development"` and add `CODE_SIGN_STYLE: Automatic` or wire a provisioning profile.

**Recommended:** (A). It is the smallest surgical change, matches the "Debug signing escape hatch"
language already in commit `a78716f`, and preserves the entitlement probe design (which was always
intended to run on Release archives per `01-05-codesign-entitlement-probe-PLAN.md`).

## Blocks Phase 1 Verification?

**No.** Per the orchestrator's own context note and `01-HUMAN-UAT.md`:
- 49 SPM-level tests pass (`swift test` in `packages/{Keychain,Config,Logging,Shell}`) covering
  every line of code that compiles into the app binary.
- `xcodebuild Debug build` succeeds end-to-end (codesign + verify chain green).
- `xcodebuild build-for-testing` succeeds (the test bundle compiles and the xctest binary is
  signed cleanly).
- The `JarvisAppTests` target's source has been manually verified.

The failure is a **test-harness launch issue on a Debug bundle carrying a managed entitlement**,
not a defect in the code being tested. Phase 1 verification is already passing substantively —
this debug session just re-classifies the UAT finding from "Xcode 26 Testing.framework seal bug"
(incorrect theory) to "managed entitlement on ad-hoc Debug bundle" (correct root cause),
with a concrete fix path.

## Files Referenced

- `/Users/james.maes/Git.Local/Kof22/Jarvis/App/Jarvis.entitlements`
- `/Users/james.maes/Git.Local/Kof22/Jarvis/project.yml`
- `/Users/james.maes/Git.Local/Kof22/Jarvis/scripts/codesign.sh`
- `/Users/james.maes/Git.Local/Kof22/Jarvis/scripts/verify-entitlements.sh`
- `/Users/james.maes/Git.Local/Kof22/Jarvis/.planning/phases/01-foundations/01-HUMAN-UAT.md`
- `/Users/james.maes/Library/Developer/Xcode/DerivedData/Jarvis-epvkfnglpgagkvdoxtgqecqudqwr/Build/Products/Debug/Jarvis.app`
