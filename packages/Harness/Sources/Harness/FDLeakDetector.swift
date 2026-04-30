import Foundation

/// Snapshot of a process's open file descriptors at one point in time.
///
/// Each entry in `fds` is a normalized `"fd=<N> type=<TYPE> path=<PATH>"`
/// string assembled from a single `lsof -F ftn` record block. Set semantics
/// let `delta(from:to:)` cleanly express FD churn across an interval.
public struct FDSnapshot: Equatable, Sendable, Codable {
    public let pid: Int32
    public let fds: Set<String>

    public init(pid: Int32, fds: Set<String>) {
        self.pid = pid
        self.fds = fds
    }
}

/// File-descriptor leak detector built on top of `lsof -p <pid> -F ftn`.
///
/// Used by `MCPCrashRunner` (Plan 08-03 Task 2) to assert that 50–100
/// register/crash/restart cycles of an MCP helper do not leak FDs in the
/// parent process. The hybrid pattern is documented in
/// `.planning/phases/08-hardening/08-PATTERNS.md` §2.9: spawn template
/// matches `MCPServerHandle`'s `Process + Pipe` shape; output parser is
/// the lsof terse format.
///
/// `lsof -F ftn` emits one record per FD — a sequence of lines each
/// prefixed by a single-letter tag:
///   p<pid>      ← process ID (once at start)
///   f<fd>       ← FD number; starts a new record
///   t<type>     ← FD type (REG, PIPE, FIFO, IPv4, etc.)
///   n<name>     ← name (path, peer, etc.); MAY be absent for some types
///
/// Non-UTF-8 bytes in path names are tolerated via `String(decoding:as:)`
/// with `Unicode.UTF8.self` (lossy replacement to U+FFFD).
public enum FDLeakDetector {
    public enum DetectorError: Swift.Error, Sendable {
        case lsofFailed(exitCode: Int32, stderr: String)
        case lsofNotFound(path: String)
    }

    /// Capture a snapshot of the target process's open FDs.
    ///
    /// Defaults to the current process so call sites in unit tests can
    /// observe their own FD state with no additional plumbing.
    public static func snapshot(
        pid: Int32 = ProcessInfo.processInfo.processIdentifier
    ) throws -> FDSnapshot {
        let lsofURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        guard FileManager.default.isExecutableFile(atPath: lsofURL.path) else {
            throw DetectorError.lsofNotFound(path: lsofURL.path)
        }

        let process = Process()
        process.executableURL = lsofURL
        process.arguments = ["-p", "\(pid)", "-F", "ftn"]
        // Minimal environment matches ChildSpawnGate.minimalEnvironment
        // contract: don't inherit parent env into a short-lived child.
        process.environment = ["PATH": "/usr/bin:/bin"]
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let stderrBytes = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            let stderrText = String(data: stderrBytes, encoding: .utf8) ?? ""
            throw DetectorError.lsofFailed(
                exitCode: process.terminationStatus,
                stderr: stderrText
            )
        }
        let stdoutBytes = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        return FDSnapshot(pid: pid, fds: parseLsofTerse(stdoutBytes))
    }

    /// Compute the delta between two snapshots.
    public static func delta(
        from before: FDSnapshot,
        to after: FDSnapshot
    ) -> (added: Set<String>, removed: Set<String>) {
        (added: after.fds.subtracting(before.fds),
         removed: before.fds.subtracting(after.fds))
    }

    /// Parse `lsof -F ftn` terse output into a set of normalized FD entries.
    ///
    /// Defends against:
    ///   - non-UTF-8 path bytes (lossy decode to U+FFFD)
    ///   - missing `n<name>` line for socket / unnamed FDs
    ///   - blank input
    ///   - trailing FD record with no terminator
    ///
    /// Internal so `FDLeakDetectorTests` can feed fixture byte arrays.
    static func parseLsofTerse(_ data: Data) -> Set<String> {
        // Lossy-decode the entire blob in one shot — `lsof` writes ASCII
        // headers + (rarely) non-ASCII path bytes. Splitting on `\n` after
        // the lossy decode is tolerant of mixed encodings.
        let text = String(decoding: data, as: Unicode.UTF8.self)
        var fds: Set<String> = []
        var currentFD: String?
        var currentType: String?
        var currentName: String?

        func emit() {
            // Each FD record needs at least an `f` line. `t` and `n` are
            // both desirable but not strictly required (sockets often
            // omit `n` in `-F ftn` output unless `-i` is requested).
            guard let fd = currentFD else { return }
            let typePart = currentType.map { " type=\($0)" } ?? ""
            let namePart = currentName.map { " path=\($0)" } ?? ""
            fds.insert("fd=\(fd)\(typePart)\(namePart)")
            currentFD = nil
            currentType = nil
            currentName = nil
        }

        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: true) {
            // Each line is a single-letter tag followed by its payload
            // (no separator). Empty payload allowed: `t` alone means
            // type-unknown (rare but legal).
            guard let tag = rawLine.first else { continue }
            let payload = String(rawLine.dropFirst())
            switch tag {
            case "p":
                // Process line (`p<pid>`). Marks the start of all records
                // for this PID; ignore content (we already know the PID).
                continue
            case "f":
                // New FD record begins — flush whatever was being assembled.
                emit()
                currentFD = payload
            case "t":
                currentType = payload
            case "n":
                currentName = payload
            default:
                // `lsof -F ftn` should not emit other tags; ignore unknowns
                // rather than fail the entire parse on a future format
                // change.
                continue
            }
        }
        // Flush the trailing record.
        emit()
        return fds
    }
}
