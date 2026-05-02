import AppKit
import IOKit.hid

/// Abstracts `IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)` so tests can
/// inject a deterministic grant/deny result without touching real TCC state.
///
/// Two surfaces:
/// - `requestListenEventAccess()` — may prompt the user (calls IOHIDRequestAccess)
/// - `isListenEventAccessGranted()` — query-only, never prompts (calls IOHIDCheckAccess)
///
/// The query-only path is what the wizard uses on relaunch to detect a grant
/// the user made in System Settings between sessions, without re-prompting.
public protocol HIDAccessProbe: Sendable {
    func requestListenEventAccess() -> Bool
    func isListenEventAccessGranted() -> Bool
}

/// Production probe. Calls `IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)`
/// per the CLAUDE.md D-07 hotkey hygiene note: Input Monitoring is the TCC
/// surface gated behind `NSEvent.addGlobalMonitorForEvents`, and the silent
/// no-op on denial is specifically what SHELL-06 prevents.
public struct SystemHIDAccessProbe: HIDAccessProbe {
    public init() {}
    public func requestListenEventAccess() -> Bool {
        IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
    }
    /// IOHIDCheckAccess returns the cached TCC decision without prompting.
    /// `kIOHIDAccessTypeGranted` == 0; anything else (denied / unknown) is
    /// not granted.
    public func isListenEventAccessGranted() -> Bool {
        IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted
    }
}

/// Probes Input Monitoring and routes denial to the supplied banner sink so
/// the caller (AppDelegate) doesn't need to know the banner content.
///
/// SHELL-06 / D-12 hard invariant: denial MUST surface a banner. Silent
/// no-op on denial is forbidden — the global monitor will silently no-op at
/// the OS layer, and that's the defect SHELL-06 prevents.
@MainActor
public final class InputMonitoringProbe {
    /// Sink interface the probe calls on denial. Abstracted so the Shell
    /// package doesn't need to `import` HUDBannerCoordinator directly —
    /// App wires a concrete sink that enqueues on the coordinator.
    public protocol BannerSink: Sendable {
        func enqueueInputMonitoringDenied()
    }

    private let probe: any HIDAccessProbe

    public init(probe: any HIDAccessProbe = SystemHIDAccessProbe()) {
        self.probe = probe
    }

    /// Returns true if granted. On denial, invokes
    /// `sink?.enqueueInputMonitoringDenied()` and returns false.
    public func check(sink: (any BannerSink)?) -> Bool {
        let granted = probe.requestListenEventAccess()
        if !granted {
            sink?.enqueueInputMonitoringDenied()
        }
        return granted
    }
}
