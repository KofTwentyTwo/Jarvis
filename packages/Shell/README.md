# Shell

OS-touch primitives: global hotkeys, Input Monitoring TCC handling, launch-at-login, the SwiftUI shortcut recorder.

## Key public types

| Type | Purpose |
|------|---------|
| `HotkeyBinder` | Wraps `NSEvent.addGlobalMonitorForEvents` (preferred over Carbon `RegisterEventHotKey`) |
| `KeyboardShortcut` | Typed shortcut model (modifiers + keyCode) |
| `InputMonitoringProbe` | Calls `IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)` to detect silent-no-op denial |
| `HIDAccessProbe` (protocol) | Test seam |
| `TCCAlertService` | HUD banner + System Settings deep-link on Input Monitoring denial |
| `LaunchAtLoginController` | Wraps `SMAppService.mainApp` |
| `ShortcutRecorder` (SwiftUI) | First-launch shortcut binder |
| `CollisionDetector` | Detects shortcuts that collide with Chrome/Slack/VSCode/Alfred/Raycast |

## Depends on

`Config`, `Logging`. External: `swift-log`.

## Used by

`App/AppDelegate`, `App/Wizard/` (first-launch shortcut binding flow).

## Key invariants / contracts

- **`NSEvent.addGlobalMonitorForEvents` over Carbon `RegisterEventHotKey`.** Fewer TCC surfaces; no full-process key-read risk.
- **Global monitor silently no-ops on Input Monitoring denial.** `InputMonitoringProbe` detects this and surfaces a banner; degraded mode falls back to local-monitor-only.
- **Hotkey ships unset.** First launch routes through `ShortcutRecorder`. Cmd+Shift+J / Option+Space collide with common apps; `CollisionDetector` warns.
- **`HIDAccessProbe` test seam protocol.** Production = `RealHIDAccessProbe`; tests = `MockHIDAccessProbe`.

## Tests

XCTest + swift-testing. Hotkey binding fixtures, Input Monitoring denial paths (`InputMonitoringDenialTests`), shortcut collision detection.

## Notable files

- `Sources/Shell/HotkeyBinder.swift` — global hotkey wrapper
- `Sources/Shell/InputMonitoringProbe.swift` — TCC denial probe
- `Sources/Shell/TCCAlertService.swift` — banner + deep-link
- `Sources/Shell/ShortcutRecorder/` — SwiftUI shortcut binder
- `Sources/Shell/LaunchAtLoginController.swift` — `SMAppService` wrapper
