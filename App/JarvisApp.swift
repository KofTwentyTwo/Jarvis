import SwiftUI

@main
struct JarvisApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    var body: some Scene {
        // Placeholder Settings scene so @main has a body; real windows land in Plan 03.
        Settings { EmptyView() }
    }
}
