// LoggingBootstrap.swift
//
// Single entry point for `swift-log` `LoggingSystem.bootstrap`. Builds
// the three-way MultiplexLogHandler that every Jarvis logger funnels
// through:
//
//   1. FileLogHandler  — rotating disk persistence with redaction.
//   2. OSLogHandler    — Console.app + system log streaming.
//   3. BroadcastLogHandler — in-process fan-out to DevOverlay et al.
//
// The third handler was added 2026-05-12 (dev-overlay-end-to-end Slice 3)
// so the DevOverlay can tail every log line from every module live. It is
// additive — removing it leaves persistence + os logging intact.

import Foundation
import Logging   // swift-log

public enum JarvisLogHandlerFactory {
    /// The subsystem string baked into OSLogHandler — matches CLAUDE.md §os.Logger identity.
    public static let subsystem = "com.koftwentytwo.jarvis"

    /// Factory consumed by swift-log's LoggingSystem.bootstrap.
    public static func make(label: String) -> LogHandler {
        let file = FileLogHandler(
            label: label,
            directory: LogPaths.channelDirectory,
            dateProvider: SystemDateProvider()
        )
        let os = OSLogHandler(subsystem: subsystem, category: label, label: label)
        let broadcast = BroadcastLogHandler(label: label)
        return MultiplexLogHandler([file, os, broadcast])
    }

    /// Call exactly ONCE at `AppDelegate.applicationWillFinishLaunching`.
    /// Per S-8: anti-pattern to call from package init or test setUp.
    public static func bootstrap() {
        LoggingSystem.bootstrap(Self.make)
    }
}
