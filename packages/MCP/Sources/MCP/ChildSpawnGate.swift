// ChildSpawnGate.swift
//
// Single choke point through which EVERY child-process spawn in the JarvisMCP
// layer must pass. Enforces two invariants ahead of `Process.run()`:
//
//   1. FD_CLOEXEC sweep: walks parent FDs in [3, getdtablesize()) and ensures
//      every open FD carries FD_CLOEXEC before fork+exec.
//
//      Path-aware policy (developer-owned vs. system/anonymous):
//        - **Developer-owned** FDs (paths under our bundle, ~/Library/Logs/Jarvis,
//          or ~/Library/Application Support/Jarvis): fatalError in Debug so the
//          regression is loud at the open site. Retrofit + warning in Release.
//        - **System / anonymous** FDs (system frameworks like WebKit's Metal
//          libraries, lldb-inherited debugger pipes when running under Xcode's
//          ⌘R, Foundation internals, anonymous pipes/sockets): retrofit + log.
//          We don't own these open sites — they aren't actionable as Debug
//          fatalErrors and would block legitimate ⌘R runs.
//
//      The primary defense is `O_CLOEXEC` at FD-creation time; this sweep is
//      the belt-and-braces backstop recommended by CERT FIO22-C.
//
//   2. Minimal environment: callers MUST pass `ChildSpawnGate.minimalEnvironment`
//      to the spawned `Process` so no parent env (HOME, USER, ANTHROPIC_API_KEY,
//      …) leaks into the helper. The gate exposes the value as a constant; it
//      cannot enforce its use across our codebase from inside the actor — the
//      grep gate in 05-RESEARCH §verification covers that contract.
//
// Plan: 05-01 (MCP-08)

import Darwin
import Foundation

public actor ChildSpawnGate {
    /// Singleton — there is exactly one gate per process.
    public static let shared = ChildSpawnGate()

    /// The exact environment dictionary every spawned helper sees. Only `PATH`,
    /// scoped to system binaries. Anything richer must justify itself.
    public static let minimalEnvironment: [String: String] = ["PATH": "/usr/bin:/bin"]

    private let logger = MCPLogChannel.logger(label: "spawngate")

    /// Path prefixes the developer-instrumentation contract covers. An FD whose
    /// `F_GETPATH` is under one of these is OUR open site, so a missing
    /// `FD_CLOEXEC` is a regression we want to halt the build on.
    /// Computed once at first use — `Bundle.main.bundlePath` and `NSHomeDirectory`
    /// don't change for the process lifetime.
    private nonisolated static let developerOwnedPrefixes: [String] = {
        let home = NSHomeDirectory()
        return [
            Bundle.main.bundlePath + "/",
            home + "/Library/Logs/Jarvis/",
            home + "/Library/Application Support/Jarvis/",
        ]
    }()

    private init() {}

    /// Sweeps parent FDs and enforces FD_CLOEXEC. Call this on the actor BEFORE
    /// every `Process.run()` from the JarvisMCP layer.
    ///
    /// The sweep walks [3, getdtablesize()) — typically ~256 FDs on macOS, so
    /// a few microseconds per spawn. We skip closed FDs (`fcntl(F_GETFD)` < 0).
    public func prepare() throws {
        let fdMax = getdtablesize()
        for fd in 3..<fdMax {
            let flags = fcntl(fd, F_GETFD)
            guard flags >= 0 else { continue }  // FD not open
            if (flags & FD_CLOEXEC) == 0 {
                // Resolve path so we can both classify (developer-owned vs
                // system/anonymous) and name the offending open site in the
                // Debug fatalError message.
                var pathBuf = [CChar](repeating: 0, count: 4096)  // MAXPATHLEN
                let path = fcntl(fd, F_GETPATH, &pathBuf) >= 0 ? String(cString: pathBuf) : "<unknown>"
                let isOwned = Self.developerOwnedPrefixes.contains { path.hasPrefix($0) }

                if isOwned {
                    #if DEBUG
                    fatalError("FD \(fd) (\(path)) is not FD_CLOEXEC; origin must be instrumented to set O_CLOEXEC at open time")
                    #else
                    _ = fcntl(fd, F_SETFD, flags | FD_CLOEXEC)
                    logger.warning("developer-owned FD \(fd) (\(path)) was not FD_CLOEXEC; retrofitted")
                    #endif
                } else {
                    _ = fcntl(fd, F_SETFD, flags | FD_CLOEXEC)
                    logger.debug("system/anonymous FD \(fd) (\(path)) was not FD_CLOEXEC; retrofitted")
                }
            }
        }
    }
}
