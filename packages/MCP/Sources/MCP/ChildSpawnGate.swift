// ChildSpawnGate.swift
//
// Single choke point through which EVERY child-process spawn in the JarvisMCP
// layer must pass. Enforces two invariants ahead of `Process.run()`:
//
//   1. FD_CLOEXEC sweep: walks parent FDs in [3, getdtablesize()) and either
//      fatalErrors (Debug — the FD owner must be instrumented) or retrofits
//      `FD_CLOEXEC` with a warning (Release — keep production alive).
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
                #if DEBUG
                fatalError("FD \(fd) is not FD_CLOEXEC; origin must be instrumented to set O_CLOEXEC at open time")
                #else
                _ = fcntl(fd, F_SETFD, flags | FD_CLOEXEC)
                logger.warning("FD \(fd) was not FD_CLOEXEC; retrofitted")
                #endif
            }
        }
    }
}
