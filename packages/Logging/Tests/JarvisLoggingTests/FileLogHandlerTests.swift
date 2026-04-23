import XCTest
import Logging
@testable import JarvisLogging

final class FileLogHandlerTests: XCTestCase {
    private var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("jarvis-logtest-\(UUID())", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    func test_rotatesAtDayBoundary() throws {
        let startDate = Date(timeIntervalSince1970: 1_800_000_000) // deterministic past date
        let dp = TestDateProvider(startingAt: startDate)
        let handler = FileLogHandler(label: "rotate-test", directory: tempDir, dateProvider: dp)

        handler.log(level: .info, message: "day one",
                    metadata: nil, source: "", file: "", function: "", line: 0)
        usleep(50_000) // let the serial queue drain

        // Advance 26 hours → crosses at least one midnight boundary.
        dp.advance(by: 26 * 3600)

        handler.log(level: .info, message: "day two",
                    metadata: nil, source: "", file: "", function: "", line: 0)
        usleep(50_000)

        let files = try FileManager.default.contentsOfDirectory(
            at: tempDir, includingPropertiesForKeys: nil
        ).filter { $0.lastPathComponent.hasPrefix("rotate-test.") }
        XCTAssertGreaterThanOrEqual(files.count, 2, "Should have rotated to a new file")
    }

    /// WR-01 (OBS-06): when the log directory becomes unwritable
    /// (simulated here by pointing the writer at a path that is a regular
    /// file, so FileManager.createDirectory silently keeps going and the
    /// FileHandle open fails), append() must increment the dropped-lines
    /// counter instead of silently swallowing the line.
    func test_dropsLinesWhenHandleUnavailable() throws {
        // Create a path where `directory` is actually a regular file —
        // subsequent `createFile(atPath:)` inside `directory` will refuse
        // because the directory can't be created on top of a file.
        let fileAsDir = tempDir.appendingPathComponent("not-a-dir")
        try "sentinel".data(using: .utf8)!.write(to: fileAsDir)

        let dp = TestDateProvider(startingAt: Date(timeIntervalSince1970: 1_800_000_000))
        let writer = FileRotatingWriter(
            directory: fileAsDir, // a regular file, not a directory
            baseName: "drop-test",
            retentionDays: 7,
            dateProvider: dp
        )
        writer.append("line1\n")
        writer.append("line2\n")
        writer.append("line3\n")

        // Wait for serial queue to drain.
        XCTAssertEqual(
            writer.droppedLinesSnapshot(), 3,
            "WR-01: unwritable directory must drop lines and count them"
        )
    }

    func test_deletesBeyondSeven() throws {
        // Seed 10 files with past dates, then write one log line → GC should leave ≤7.
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let fm = FileManager.default
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"

        for i in 0..<10 {
            let date = Calendar(identifier: .gregorian).date(byAdding: .day, value: -i, to: now)!
            let path = tempDir.appendingPathComponent("retain-test.\(df.string(from: date)).log")
            try "seed\n".data(using: .utf8)!.write(to: path)
        }

        let dp = TestDateProvider(startingAt: now)
        let handler = FileLogHandler(label: "retain-test", directory: tempDir, dateProvider: dp)
        handler.log(level: .info, message: "trigger-gc",
                    metadata: nil, source: "", file: "", function: "", line: 0)
        usleep(100_000) // let GC run

        let remaining = try fm.contentsOfDirectory(at: tempDir, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("retain-test.") }
        XCTAssertLessThanOrEqual(remaining.count, 8, "retain-7 + today means ≤8 files; got \(remaining.count)")
        // Stricter: the oldest file (9 days ago) should be deleted.
        let oldest = Calendar(identifier: .gregorian).date(byAdding: .day, value: -9, to: now)!
        let oldestPath = tempDir.appendingPathComponent("retain-test.\(df.string(from: oldest)).log")
        XCTAssertFalse(fm.fileExists(atPath: oldestPath.path), "9-day-old file should have been GC'd")
    }
}
