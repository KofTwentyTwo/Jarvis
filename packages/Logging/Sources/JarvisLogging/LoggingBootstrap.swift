import Foundation
import Logging   // swift-log

public enum JarvisLogHandlerFactory {
    /// The subsystem string baked into OSLogHandler — matches CLAUDE.md §os.Logger identity.
    public static let subsystem = "com.kingsrook.jarvis"

    /// Factory consumed by swift-log's LoggingSystem.bootstrap.
    public static func make(label: String) -> LogHandler {
        let file = FileLogHandler(
            label: label,
            directory: LogPaths.channelDirectory,
            dateProvider: SystemDateProvider()
        )
        let os = OSLogHandler(subsystem: subsystem, category: label, label: label)
        return MultiplexLogHandler([file, os])
    }

    /// Call exactly ONCE at `AppDelegate.applicationWillFinishLaunching`.
    /// Per S-8: anti-pattern to call from package init or test setUp.
    public static func bootstrap() {
        LoggingSystem.bootstrap(Self.make)
    }
}
