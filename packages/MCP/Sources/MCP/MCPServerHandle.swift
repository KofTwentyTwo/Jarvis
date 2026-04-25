// MCPServerHandle.swift
//
// Per-server actor that owns the lifecycle of one MCP helper subprocess:
// the `Process`, the three Pipes, the SDK `Client`, and the restart-task
// slot used by the per-server restart mutex (Pattern 2 in 05-RESEARCH).
//
// Spawn invariants enforced by `start()`:
//   1. ChildSpawnGate.shared.prepare() runs BEFORE Process.run().
//   2. process.environment = ChildSpawnGate.minimalEnvironment (PATH only).
//   3. StdioTransport is constructed with EXPLICIT FileDescriptor args
//      derived from the parent-side pipe ends. NEVER the no-arg init —
//      that's the helper-side default and would hang on the parent's
//      own stdin/stdout (Pitfall #1).
//
// Crash semantics:
//   - process.terminationHandler routes through `handleTermination`
//   - the SDK's Client.disconnect() drains its pending-request map with
//     MCPError.internalError("Client disconnected"); we wrap to
//     JarvisMCPError.serverCrashed at our boundary (in callTool).
//   - restart is LAZY — handleTermination only sets isCrashed = true.
//     The next callTool path triggers start() via the per-server mutex.
//
// Plan: 05-01 (MCP-07)

import Foundation
import Logging
import MCP
#if canImport(System)
import System
#else
import SystemPackage
#endif

public actor MCPServerHandle {
    public nonisolated let name: String
    public nonisolated let binaryURL: URL
    public nonisolated let requiresConfirmation: Bool

    /// Optional environment overlay merged ON TOP of `ChildSpawnGate.minimalEnvironment`.
    /// Keys with `nil` values are stripped. This stays empty for production
    /// helpers; tests use it to thread `MOCK_HELPER_CRASH_AFTER` etc. into
    /// the child without polluting the gate's contract.
    public var extraEnvironment: [String: String]

    /// The SDK Client. Recreated on every `start()` so restart cycles get a
    /// fresh pending-request map (the previous one was drained by disconnect).
    private var client: Client

    private var process: Process?
    private var stdinPipe: Pipe?
    private var stdoutPipe: Pipe?
    private var stderrPipe: Pipe?

    /// The per-server restart-mutex slot. `MCPClient.callTool` uses this:
    /// concurrent callers awaiting a crashed server share one in-flight
    /// restart Task instead of stampeding.
    public private(set) var restartTask: Task<Void, Error>?

    /// True once `handleTermination()` fires; cleared on a successful restart.
    public private(set) var isCrashed: Bool = false

    private let logger: Logger
    private let stderrLogger: Logger

    public init(name: String, binaryURL: URL, requiresConfirmation: Bool, extraEnvironment: [String: String] = [:]) {
        self.name = name
        self.binaryURL = binaryURL
        self.requiresConfirmation = requiresConfirmation
        self.extraEnvironment = extraEnvironment
        self.client = Client(name: "Jarvis", version: "1.0.0")
        self.logger = MCPLogChannel.logger(label: "client.\(name)")
        self.stderrLogger = MCPLogChannel.logger(label: "stderr.\(name)")
    }

    // MARK: - Lifecycle

    /// Spawn the helper, wire stdio, complete the SDK initialize handshake,
    /// and verify it advertises the `tools` capability.
    public func start() async throws {
        // Drop any stale state from a prior start before we rebuild — the
        // restart path always reaches here through this method.
        await teardownIfRunning()
        self.client = Client(name: "Jarvis", version: "1.0.0")

        // 1. Mandatory pre-spawn gate: FD_CLOEXEC sweep on parent FDs.
        try await ChildSpawnGate.shared.prepare()

        // 2. Wire fresh Process + 3 pipes.
        let process = Process()
        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.executableURL = binaryURL
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        // 3. Hard-set minimal env. The gate cannot enforce this on Process.environment
        //    from inside its actor; the contract is "every spawn passes this exact value".
        var env = ChildSpawnGate.minimalEnvironment
        for (k, v) in extraEnvironment { env[k] = v }
        process.environment = env

        // 4. Launch.
        do {
            try process.run()
        } catch {
            throw JarvisMCPError.spawnFailed(name: name, underlying: String(describing: error))
        }

        // 4a. Close the parent-side pipe ends that belong to the CHILD. Foundation
        //     forks + dup2 + closes inside the child before returning; the parent's
        //     copies are pure leaks if we don't release them. Each one is +1 FD per
        //     spawn cycle, so without this the 100-cycle FD-leak test fails.
        try? stdinPipe.fileHandleForReading.close()
        try? stdoutPipe.fileHandleForWriting.close()
        try? stderrPipe.fileHandleForWriting.close()

        // 4b. Set FD_CLOEXEC on the parent-side pipe ends WE retain so a future
        //     ChildSpawnGate.shared.prepare() sweep doesn't fatalError on them.
        //     The gate's contract is "every long-lived parent FD is CLOEXEC";
        //     Foundation creates Pipe FDs without O_CLOEXEC, so we own retrofit
        //     here at the FD-creation point (consistent with the gate's primary
        //     defense — CLOEXEC at open time, not at sweep time).
        Self.setCloexec(stdinPipe.fileHandleForWriting.fileDescriptor)
        Self.setCloexec(stdoutPipe.fileHandleForReading.fileDescriptor)
        Self.setCloexec(stderrPipe.fileHandleForReading.fileDescriptor)

        // 5. Wire stderr drain. The handler closure runs on a background queue
        //    owned by Foundation; we only forward bytes to a plain Logger so
        //    no actor isolation issues.
        let logger = self.stderrLogger
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            if let text = String(data: data, encoding: .utf8) {
                for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
                    logger.info("\(line)")
                }
            }
        }

        // 6. Build StdioTransport with EXPLICIT FileDescriptors.
        //    input  = parent's READ end of child's STDOUT  (bytes from child)
        //    output = parent's WRITE end of child's STDIN  (bytes to child)
        let transportInput = FileDescriptor(rawValue: stdoutPipe.fileHandleForReading.fileDescriptor)
        let transportOutput = FileDescriptor(rawValue: stdinPipe.fileHandleForWriting.fileDescriptor)
        // Single-line form keeps the grep gate `StdioTransport(input:` literal.
        let transport = StdioTransport(input: transportInput, output: transportOutput, logger: logger)

        // 7. Connect — this auto-runs the initialize handshake.
        //
        // CR-01 (REVIEW 05): on init-failure paths, parent-side pipe ends must
        // be closed BEFORE we throw, otherwise three FDs leak per failure
        // (stdin write, stdout read, stderr read). Foundation's Pipe deinit
        // does NOT close FDs (closeOnDealloc:false is the default), and
        // terminateProcessImmediately only SIGKILLs the child. Without this,
        // a poisoned helper that crashes during initialize would leak FDs
        // until ChildSpawnGate.shared.prepare()'s next CLOEXEC sweep
        // fatalErrors in DEBUG.
        let initResult: Initialize.Result
        do {
            initResult = try await client.connect(transport: transport)
        } catch {
            // Initialize failure: tear down and bubble up the cause.
            try? terminateProcessImmediately(process)
            Self.closeParentPipeEnds(stdinPipe: stdinPipe, stdoutPipe: stdoutPipe, stderrPipe: stderrPipe)
            throw JarvisMCPError.spawnFailed(name: name, underlying: String(describing: error))
        }

        guard initResult.capabilities.tools != nil else {
            try? terminateProcessImmediately(process)
            await client.disconnect()
            Self.closeParentPipeEnds(stdinPipe: stdinPipe, stdoutPipe: stdoutPipe, stderrPipe: stderrPipe)
            throw JarvisMCPError.helperMissingToolsCapability(name: name)
        }

        // 8. Wire termination handler. The handler captures a weak ref into
        //    a Task to bridge back into actor isolation. We pin the PID at
        //    wire time so a stale handler from a prior helper (post-restart)
        //    can't flip isCrashed on the LIVE process. handleTermination
        //    no-ops if the supplied PID no longer matches.
        let pinnedPID = process.processIdentifier
        process.terminationHandler = { [weak self] _ in
            Task { await self?.handleTermination(forPID: pinnedPID) }
        }

        // 9. Commit state.
        self.process = process
        self.stdinPipe = stdinPipe
        self.stdoutPipe = stdoutPipe
        self.stderrPipe = stderrPipe
        self.isCrashed = false
    }

    /// Graceful shutdown: close the parent's write-end of stdin to signal EOF,
    /// give the helper up to 2 seconds to exit, then SIGKILL if needed.
    public func shutdown() async {
        guard let process = self.process else { return }

        // Close parent write-end of stdin → child receives EOF on stdin → SDK Server
        // exits its read loop and we go through process.terminationHandler.
        try? stdinPipe?.fileHandleForWriting.close()

        // Wait up to 2s for natural exit.
        let deadline = Date().addingTimeInterval(2.0)
        while process.isRunning && Date() < deadline {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        if process.isRunning {
            kill(process.processIdentifier, SIGKILL)
            try? await Task.sleep(nanoseconds: 100_000_000)
        }

        await client.disconnect()
        await teardownIfRunning()
    }

    /// Wire the restart-task slot. Called by `MCPClient.callTool` to share a
    /// single in-flight restart across concurrent callers.
    public func setRestartTask(_ task: Task<Void, Error>?) {
        self.restartTask = task
    }

    /// Atomic claim-or-share: if the handle is still crashed and the slot is
    /// empty, install the supplied Task and return `(claimed: true, task)`.
    /// If another caller already installed a task, return `(false, that task)`.
    /// If the helper is no longer crashed (someone else completed restart and
    /// cleared the slot), return `(false, nil)` — caller proceeds directly.
    ///
    /// Runs entirely under this actor's isolation, so the read-modify-write is
    /// serialized w.r.t. other callers on the same handle. This is the
    /// load-bearing primitive of the per-server restart mutex.
    public func claimOrShareRestart(_ buildTask: () -> Task<Void, Error>) -> (claimed: Bool, task: Task<Void, Error>?) {
        if !isCrashed { return (false, nil) }
        if let existing = restartTask {
            return (false, existing)
        }
        let task = buildTask()
        self.restartTask = task
        return (true, task)
    }

    // MARK: - SDK call passthrough

    /// Public — used by `MCPClient` and (in Task 3) the per-server restart mutex.
    /// Preserved as a CallTool.Result wrapper so downstream consumers can read
    /// `content` and `isError` cleanly.
    public func callTool(name: String, arguments: [String: Value]?) async throws -> CallTool.Result {
        do {
            let tuple = try await client.callTool(name: name, arguments: arguments)
            return CallTool.Result(content: tuple.content, isError: tuple.isError)
        } catch {
            // If the SDK error came from a disconnected/torn-down client AND we know
            // the helper crashed, the caller wants `serverCrashed` to trigger restart.
            // Otherwise rethrow the SDK's own error verbatim.
            if isCrashed {
                throw JarvisMCPError.serverCrashed(name: self.name)
            }
            throw error
        }
    }

    /// Public — used by `MCPClient.register` after `start()` to populate the tool→server map.
    public func listTools() async throws -> (tools: [Tool], nextCursor: String?) {
        try await client.listTools()
    }

    // MARK: - Internals

    private func handleTermination(forPID pid: Int32) async {
        // Stale handler guard: only act if the terminating PID matches our
        // currently-tracked process. After a restart, the OLD process's
        // terminationHandler (still hooked up under iOS/macOS Foundation)
        // would otherwise flip isCrashed=true on the LIVE process.
        guard let p = self.process, p.processIdentifier == pid else { return }

        // SDK drains its pending-request map with `MCPError.internalError("Client disconnected")`.
        // Our callTool wrapper above translates that into `JarvisMCPError.serverCrashed` for any
        // caller still awaiting at the boundary (because `isCrashed` is set first).
        self.isCrashed = true
        await client.disconnect()
        // Detach the readability handler so we stop draining stderr from a dead pipe.
        stderrPipe?.fileHandleForReading.readabilityHandler = nil
    }

    private func teardownIfRunning() async {
        if let p = process, p.isRunning {
            kill(p.processIdentifier, SIGKILL)
        }
        // Close parent-side pipe ends explicitly to keep FD count from drifting
        // across restart cycles. POSIX close() is idempotent on already-closed FDs.
        try? stdinPipe?.fileHandleForWriting.close()
        try? stdoutPipe?.fileHandleForReading.close()
        try? stderrPipe?.fileHandleForReading.close()
        stderrPipe?.fileHandleForReading.readabilityHandler = nil
        process = nil
        stdinPipe = nil
        stdoutPipe = nil
        stderrPipe = nil
    }

    private nonisolated func terminateProcessImmediately(_ process: Process) throws {
        if process.isRunning {
            kill(process.processIdentifier, SIGKILL)
        }
    }

    /// Set FD_CLOEXEC on a file descriptor. Idempotent on closed FDs (returns
    /// silently). Used at FD-creation time on parent-side Pipe ends so the
    /// ChildSpawnGate sweep treats them as well-behaved on subsequent spawns.
    private nonisolated static func setCloexec(_ fd: Int32) {
        let flags = fcntl(fd, F_GETFD)
        if flags >= 0 {
            _ = fcntl(fd, F_SETFD, flags | FD_CLOEXEC)
        }
    }

    /// CR-01 (REVIEW 05): close the parent-retained pipe ends on
    /// initialize-failure paths so a poisoned helper doesn't leak 3 FDs per
    /// failed start(). Detaches the stderr readability handler first so
    /// Foundation's background queue doesn't fire on a closed FD.
    ///
    /// Idempotent — close() on an already-closed FD throws which `try?`
    /// swallows. Safe to call from any throw site.
    private nonisolated static func closeParentPipeEnds(
        stdinPipe: Pipe,
        stdoutPipe: Pipe,
        stderrPipe: Pipe
    ) {
        stderrPipe.fileHandleForReading.readabilityHandler = nil
        try? stdinPipe.fileHandleForWriting.close()
        try? stdoutPipe.fileHandleForReading.close()
        try? stderrPipe.fileHandleForReading.close()
    }

    // MARK: - Test-only inspection

    #if DEBUG
    /// Returns the helper's PID for tests that need to SIGKILL the child directly.
    public func _testProcessIdentifier() -> Int32 {
        process?.processIdentifier ?? -1
    }
    #endif
}
