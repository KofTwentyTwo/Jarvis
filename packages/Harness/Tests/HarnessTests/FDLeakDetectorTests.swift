import XCTest
import Darwin
@testable import Harness

final class FDLeakDetectorTests: XCTestCase {

    // MARK: - parseLsofTerse: edge cases

    func test_parseLsofTerse_empty() {
        let parsed = FDLeakDetector.parseLsofTerse(Data())
        XCTAssertTrue(parsed.isEmpty)
    }

    func test_parseLsofTerse_happyPath() {
        let fixture = """
        p1234
        f0
        tCHR
        n/dev/null
        f7
        tREG
        n/tmp/jarvis-replay.sqlite
        """.data(using: .utf8)!
        let parsed = FDLeakDetector.parseLsofTerse(fixture)
        XCTAssertEqual(parsed.count, 2)
        XCTAssertTrue(parsed.contains("fd=0 type=CHR path=/dev/null"))
        XCTAssertTrue(parsed.contains("fd=7 type=REG path=/tmp/jarvis-replay.sqlite"))
    }

    func test_parseLsofTerse_fifo_and_socket_withoutPath() {
        // Sockets/FIFOs in `-F ftn` output frequently omit the `n` line.
        // Parser must NOT throw and MUST emit the FD entry minus the path.
        let fixture = """
        p4242
        f3
        tFIFO
        f5
        tIPv4
        """.data(using: .utf8)!
        let parsed = FDLeakDetector.parseLsofTerse(fixture)
        XCTAssertEqual(parsed.count, 2)
        XCTAssertTrue(parsed.contains("fd=3 type=FIFO"))
        XCTAssertTrue(parsed.contains("fd=5 type=IPv4"))
    }

    func test_parseLsofTerse_nonUTF8PathBytes() {
        // Lossy-decode pipeline must replace invalid UTF-8 with U+FFFD.
        // Path: /tmp/<0xFF><0xFE><0xFD>weird (3 invalid bytes mid-string).
        var bytes: [UInt8] = Array("p1\nf9\ntREG\nn/tmp/".utf8)
        bytes.append(contentsOf: [0xFF, 0xFE, 0xFD])
        bytes.append(contentsOf: Array("weird".utf8))
        let parsed = FDLeakDetector.parseLsofTerse(Data(bytes))
        XCTAssertEqual(parsed.count, 1)
        let only = parsed.first!
        XCTAssertTrue(only.hasPrefix("fd=9 type=REG path=/tmp/"))
        // Replacement char count: 3 invalid bytes → 3 U+FFFD characters.
        XCTAssertEqual(only.filter { $0 == "\u{FFFD}" }.count, 3)
    }

    func test_parseLsofTerse_ignoresUnknownTags() {
        // lsof of the future may add a tag we don't model; the parser must
        // skip it without breaking the surrounding record.
        let fixture = """
        p99
        f1
        tREG
        Xignored-future-field
        n/etc/hosts
        """.data(using: .utf8)!
        let parsed = FDLeakDetector.parseLsofTerse(fixture)
        XCTAssertEqual(parsed.count, 1)
        XCTAssertTrue(parsed.contains("fd=1 type=REG path=/etc/hosts"))
    }

    // MARK: - snapshot: live process

    func test_snapshot_currentProcess_isNonEmpty() throws {
        // The current XCTest process always has stdin/stdout/stderr at
        // minimum. lsof should report at least 3 entries.
        let snap = try FDLeakDetector.snapshot()
        XCTAssertEqual(snap.pid, ProcessInfo.processInfo.processIdentifier)
        XCTAssertGreaterThanOrEqual(snap.fds.count, 3,
            "expected at least stdin/stdout/stderr; got \(snap.fds.count)")
    }

    func test_snapshot_observesNewlyOpenedAndClosedFD() throws {
        let before = try FDLeakDetector.snapshot()

        // Open a known FD on a temp file and remember the path.
        let tmp = NSTemporaryDirectory()
            + "fdleak-test-\(UUID().uuidString).bin"
        FileManager.default.createFile(atPath: tmp, contents: Data("seed".utf8))
        defer { try? FileManager.default.removeItem(atPath: tmp) }

        let fd = open(tmp, O_RDONLY)
        XCTAssertGreaterThan(fd, 0, "open failed")

        let after = try FDLeakDetector.snapshot()
        let delta = FDLeakDetector.delta(from: before, to: after)
        // Expect SOME added FD whose path matches our tmp file.
        let matchedAdded = delta.added.contains { $0.contains(tmp) }
        XCTAssertTrue(matchedAdded,
            "expected an added FD entry containing path \(tmp); added=\(delta.added)")

        close(fd)

        let final = try FDLeakDetector.snapshot()
        let cleanup = FDLeakDetector.delta(from: after, to: final)
        let matchedRemoved = cleanup.removed.contains { $0.contains(tmp) }
        XCTAssertTrue(matchedRemoved,
            "expected the FD entry to be removed after close; removed=\(cleanup.removed)")
    }

    // MARK: - delta: pure set algebra

    func test_delta_disjointSets() {
        let a = FDSnapshot(pid: 1, fds: ["fd=0", "fd=1", "fd=2"])
        let b = FDSnapshot(pid: 1, fds: ["fd=2", "fd=3", "fd=4"])
        let d = FDLeakDetector.delta(from: a, to: b)
        XCTAssertEqual(d.added, ["fd=3", "fd=4"])
        XCTAssertEqual(d.removed, ["fd=0", "fd=1"])
    }

    func test_delta_emptyBothDirections_onIdenticalSnapshots() {
        let s = FDSnapshot(pid: 1, fds: ["fd=0", "fd=1"])
        let d = FDLeakDetector.delta(from: s, to: s)
        XCTAssertTrue(d.added.isEmpty)
        XCTAssertTrue(d.removed.isEmpty)
    }
}
