import Foundation

/// Content for a single HUD banner appearance. `id` is the dedup/priority key;
/// `priority` orders pre-empting of the currently-visible banner (lower = higher).
/// Preset banners are below as static members per UI-SPEC Surface 5 copywriting
/// table + priority order.
public struct BannerContent: Sendable, Equatable, Identifiable {
    public let id: String
    public let priority: Int
    public let title: String
    public let body: String
    public let action: Action?
    /// Round 4 — when true, the dismiss X is hidden and `dismissCurrent()`
    /// is a no-op. Reserved for critical subsystem failures where letting
    /// the user dismiss the warning would silently restore the lying-Jarvis
    /// failure mode the round was created to fix.
    public let nonDismissible: Bool

    public struct Action: Sendable, Equatable {
        public let label: String
        public let url: URL?
        public init(label: String, url: URL?) {
            self.label = label
            self.url = url
        }
    }

    public init(
        id: String,
        priority: Int,
        title: String,
        body: String,
        action: Action?,
        nonDismissible: Bool = false
    ) {
        self.id = id
        self.priority = priority
        self.title = title
        self.body = body
        self.action = action
        self.nonDismissible = nonDismissible
    }
}

/// Preset banners per UI-SPEC Surface 5 copywriting table + priority order.
public extension BannerContent {
    /// Highest priority — no API key in Keychain. Blocks Anthropic provider.
    static let keychainEmpty = BannerContent(
        id: "keychain-empty",
        priority: 1,
        title: "No API key configured",
        body: "Jarvis can't reach Claude until you set up an API key.",
        action: .init(label: "Open Setup", url: nil)
    )

    /// Input Monitoring TCC denied — global hotkey degrades to local-only.
    ///
    /// SHELL-06 / #88: non-dismissible. The user can't click this away on
    /// a denial because letting them silently restore the "global hotkey
    /// silently no-ops" failure mode is the defect this banner exists to
    /// prevent. The banner is cleared programmatically by AppDelegate's
    /// `reprobeInputMonitoring()` on app foreground after the user grants
    /// access in System Settings.
    static let inputMonitoringDenied = BannerContent(
        id: "input-monitoring-denied",
        priority: 2,
        title: "Limited hotkey mode",
        body: "Jarvis can't see global key presses. The hotkey will only work when Jarvis is frontmost.",
        action: .init(
            label: "Open System Settings",
            url: URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")
        ),
        nonDismissible: true
    )

    /// Hotkey registration failed — another app claimed the shortcut.
    static let hotkeyBindFailed = BannerContent(
        id: "hotkey-bind-failed",
        priority: 3,
        title: "Hotkey unavailable",
        body: "Couldn't register your hotkey — another app may have claimed it. Click the menu-bar icon to summon Jarvis.",
        action: .init(label: "Rebind", url: nil)
    )

    /// Ollama base_url rejected (not 127.0.0.1/localhost/::1) per AGENT-05.
    static let ollamaURLRejected = BannerContent(
        id: "ollama-url-rejected",
        priority: 4,
        title: "Ollama config rejected",
        body: "The configured Ollama URL isn't local. Only 127.0.0.1 and localhost are allowed. Check config.json.",
        action: .init(label: "Reveal config", url: nil)
    )

    /// Plan 07-06 / VISION-01: Camera TCC denied — presence + frame-attach
    /// degrade gracefully. The banner deep-links to System Settings.
    static let cameraDenied = BannerContent(
        id: "camera-denied",
        priority: 3,
        title: "Camera access denied",
        body: "Jarvis can't see whether you're at the desk or attach a camera frame to a turn. Grant Camera access in System Settings.",
        action: .init(
            label: "Open System Settings",
            url: URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera")
        )
    )

    /// Plan 07-06 / VISION-01: mid-session camera revocation. The capture
    /// session was terminated by another app or the user toggled access off.
    static let cameraRevoked = BannerContent(
        id: "camera-revoked",
        priority: 3,
        title: "Camera disconnected",
        body: "The camera session ended unexpectedly. Presence detection paused; frame-attach unavailable until the camera comes back.",
        action: nil
    )

    /// Round 2 boot-health failure. Per-subsystem dedup id so each failing
    /// subsystem enqueues at most one banner per launch. Lower priority
    /// than the keychain/hotkey banners (those block specific features
    /// the user already asked for); higher priority than ollama-rejected
    /// so a probe-failure shadows an environment-config issue.
    ///
    /// Round 4 — kept for backwards compat / non-critical fallbacks. The
    /// `bootHealthCritical` and `bootHealthLoud` presets below cover the
    /// new severity-driven routing.
    static func bootHealthFailed(subsystem: String, reason: String) -> BannerContent {
        BannerContent(
            id: "boot-health-failed-\(subsystem)",
            priority: 3,
            title: "Subsystem failed boot probe",
            body: "\(subsystem.capitalized): \(reason). Open Status… in the menu bar for details.",
            action: nil
        )
    }

    /// Round 4 — critical subsystem failure (memory off, no API key, no
    /// MCP tools, webview never armed). Pre-empts every other banner
    /// (priority 1) and is non-dismissible: the user cannot click it
    /// away. The agent's system-prompt preamble (Slice 3) names the same
    /// subsystem so the model can't lie about the affected capability.
    static func bootHealthCritical(subsystem: String, reason: String) -> BannerContent {
        BannerContent(
            id: "boot-health-critical-\(subsystem)",
            priority: 1,
            title: "\(subsystem.capitalized): critical failure",
            body: "\(reason). Open Status… in the menu bar for details. Until this is fixed, Jarvis will warn the model not to rely on \(subsystem).",
            action: nil,
            nonDismissible: true
        )
    }

    /// Round 4 — loud (but not blocking) subsystem failure. Dismissible.
    /// Lower priority than critical so a critical banner overshadows it.
    static func bootHealthLoud(subsystem: String, reason: String) -> BannerContent {
        BannerContent(
            id: "boot-health-loud-\(subsystem)",
            priority: 3,
            title: "\(subsystem.capitalized): degraded",
            body: "\(reason). Open Status… in the menu bar for details.",
            action: nil
        )
    }
}
