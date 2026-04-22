import ServiceManagement
import AppKit

public enum LaunchAtLoginError: Error, Sendable {
    case notFound
    case requiresApproval
    case registerFailed(Error)
}

/// Wraps `SMAppService.mainApp`. Scaffolded in Phase 1; no user-facing toggle
/// in P1 (Settings panel surfaces this in a later phase). The deprecated
/// pre-macOS-13 SMLoginItem... API is deliberately NOT used — SMAppService
/// is the only supported path from macOS 13 onward (RESEARCH Q9).
///
/// `@MainActor` per S-2 — SMAppService calls are documented main-thread-only
/// for UI-presenting effects.
@MainActor
public final class LaunchAtLoginController {
    public init() {}

    public var isEnabled: Bool {
        if #available(macOS 13.0, *) {
            return SMAppService.mainApp.status == .enabled
        }
        return false
    }

    public var requiresApproval: Bool {
        if #available(macOS 13.0, *) {
            return SMAppService.mainApp.status == .requiresApproval
        }
        return false
    }

    public func enable() throws {
        guard #available(macOS 13.0, *) else { throw LaunchAtLoginError.notFound }
        do {
            try SMAppService.mainApp.register()
        } catch {
            throw LaunchAtLoginError.registerFailed(error)
        }
    }

    public func disable() throws {
        guard #available(macOS 13.0, *) else { return }
        do {
            try SMAppService.mainApp.unregister()
        } catch {
            throw LaunchAtLoginError.registerFailed(error)
        }
    }

    /// Deep-link to System Settings → General → Login Items.
    public func openSystemSettingsLoginItems() {
        let url = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension")!
        NSWorkspace.shared.open(url)
    }
}
