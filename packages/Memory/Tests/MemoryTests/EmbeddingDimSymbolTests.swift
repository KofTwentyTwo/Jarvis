import XCTest
@testable import Memory

final class EmbeddingDimSymbolTests: XCTestCase {

    /// MEM-02: the canonical constant must equal 768.
    func testEmbeddingDimIsSeventySixtyEight() {
        XCTAssertEqual(MemoryConstants.embeddingDim, 768,
                       "EMBEDDING_DIM is the single source of truth for vector schema column width and embedding response length. Changing 768 requires a coordinated migration.")
    }

    /// MEM-02 single-symbol guard. Greps the workspace for any literal
    /// shadow of the embedding-dimension constant outside Memory/Constants.swift.
    /// Local copies / shadows fail this test.
    ///
    /// Note: We grep the source tree from $REPO_ROOT — derived by walking up
    /// from the test file location until we find the workspace root marker
    /// (`project.yml` or `Jarvis.xcodeproj`).
    ///
    /// The test itself contains the trigger pattern inside this docstring
    /// (you're reading it now). Self-references are filtered by skipping
    /// this very file and `Constants.swift` (the canonical declaration).
    func testEmbeddingDimIsSingleSymbol() throws {
        let repoRoot = try Self.repoRoot()

        // Search for definitions of the embedding-dim literal (any whitespace,
        // any access modifier). Narrow regex: only matches a constant
        // DEFINITION, not call sites that reference the canonical symbol.
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/grep")
        task.arguments = [
            "-rEn",
            #"\bEMBEDDING_DIM\s*=\s*768\b"#,
            "\(repoRoot.path)/packages",
            "\(repoRoot.path)/App",
            "--include=*.swift",
        ]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()
        try task.run()
        task.waitUntilExit()

        let data = try pipe.fileHandleForReading.readToEnd() ?? Data()
        let output = String(decoding: data, as: UTF8.self)

        // Filter out (a) this test file's own self-referential comments and
        // (b) Constants.swift docstrings (canonical declaration site). What
        // remains must be empty.
        let selfFile = URL(fileURLWithPath: #file).path
        let constantsFile = URL(fileURLWithPath: #file)
            .deletingLastPathComponent()                // MemoryTests
            .deletingLastPathComponent()                // Tests
            .deletingLastPathComponent()                // packages/Memory
            .appendingPathComponent("Sources/Memory/Constants.swift")
            .path

        let offending = output
            .split(separator: "\n")
            .filter { !$0.isEmpty }
            .filter { line in
                let s = String(line)
                return !s.hasPrefix(selfFile + ":")
                    && !s.hasPrefix(constantsFile + ":")
            }

        XCTAssertTrue(offending.isEmpty,
                      "MEM-02 violation: an embedding-dim literal was found outside MemoryConstants.embeddingDim (the canonical symbol). Hits:\n\(offending.joined(separator: "\n"))\nUse MemoryConstants.embeddingDim instead.")
    }

    private static func repoRoot() throws -> URL {
        // Walk up from #file. The repo root is the directory whose ancestry
        // ends at the filesystem root and which contains a top-level project
        // marker. We look for either `project.yml` (XcodeGen) or
        // `Jarvis.xcodeproj` to identify the workspace root, since this
        // project does not use a top-level Package.swift.
        var dir = URL(fileURLWithPath: #file).deletingLastPathComponent()
        for _ in 0..<10 {
            let projectYml = dir.appendingPathComponent("project.yml")
            let xcodeproj = dir.appendingPathComponent("Jarvis.xcodeproj")
            if FileManager.default.fileExists(atPath: projectYml.path)
                || FileManager.default.fileExists(atPath: xcodeproj.path) {
                return dir
            }
            dir = dir.deletingLastPathComponent()
        }
        throw NSError(domain: "EmbeddingDimSymbolTests", code: 1)
    }
}
