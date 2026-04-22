import SwiftUI

@main
struct JarvisApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // LSUIElement=YES keeps us out of the Dock; we don't declare a
        // WindowGroup here — the AppDelegate manages NSPanels + NSWindows
        // directly. The Settings… menu item opens a "coming soon" stub per
        // UI-SPEC Surface 4.
        Settings {
            Text("Settings — coming soon.")
                .padding()
                .frame(width: 300, height: 120)
        }
    }
}
