import SwiftUI

@main
struct JarvisApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // LSUIElement=YES keeps us out of the Dock; we don't declare a
        // WindowGroup here — the AppDelegate manages NSPanels + NSWindows
        // directly, including the real Settings panel
        // (`SettingsWindowController` invoked via the menu-bar Settings…
        // item). The SwiftUI `Settings` scene below exists only to satisfy
        // the `App` protocol's Scene requirement; with LSUIElement=YES the
        // auto-generated app-menu Settings… item is never user-visible, so
        // an EmptyView body is the correct no-op.
        Settings { EmptyView() }
    }
}
