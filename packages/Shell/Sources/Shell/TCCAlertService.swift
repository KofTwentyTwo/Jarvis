import AppKit

/// Builds the UI-SPEC Surface 6 "Jarvis can't start" hard-blocker NSAlert. Used
/// by AppDelegate when entitlement verification fails or config is malformed
/// (per D-19 / S-6 — silent fallback on safety failures is forbidden).
@MainActor
public enum TCCAlertService {
    /// Critical-style NSAlert with Quit / Show Details buttons. Show Details
    /// opens the system log so the user has something to send back.
    public static func presentHardBlock(title: String, informativeText: String) {
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = title
        alert.informativeText = informativeText
        alert.addButton(withTitle: "Quit")
        alert.addButton(withTitle: "Show Details")
        let response = alert.runModal()
        if response == .alertSecondButtonReturn {
            openSystemLog()
        }
    }

    public static func openSystemLog() {
        let logURL = URL(
            fileURLWithPath: (NSHomeDirectory() as NSString)
                .appendingPathComponent("Library/Logs/Jarvis/system.log")
        )
        NSWorkspace.shared.open(logURL)
    }
}
