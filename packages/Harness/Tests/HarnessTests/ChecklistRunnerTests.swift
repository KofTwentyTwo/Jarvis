// ChecklistRunnerTests.swift
//
// Phase 8 Plan 04 Task 1 — verifies ChecklistManifest decode (D-17
// enforcement on grep-style items, MANUAL pass-through, plist scalar
// shapes) and ChecklistRunner mechanization dispatch (script exit codes,
// grep counts, MANUAL warning rows, swift_test coherence stub).

import Testing
import Foundation
@testable import Harness

@Suite("ChecklistRunnerTests")
struct ChecklistRunnerTests {

    // MARK: - Manifest decode tests

    @Test("MANUAL item decodes with description payload")
    func decodesManual() throws {
        let yaml = """
        phase: test
        items:
          - id: T-01
            description: "manual gate"
            mechanization:
              type: MANUAL
              description: "operator runs it"
        """
        let url = try writeTempYAML(yaml)
        let manifest = try ChecklistManifest.load(yamlURL: url)
        #expect(manifest.phase == "test")
        #expect(manifest.items.count == 1)
        switch manifest.items[0].mechanization {
        case .manual(let desc): #expect(desc == "operator runs it")
        default: Issue.record("expected .manual")
        }
    }

    @Test("D-17: grep_negative without expected_count throws DecodingError")
    func grepNegativeMissingExpectedCountThrows() throws {
        let yaml = """
        phase: test
        items:
          - id: T-01
            description: "should reject"
            mechanization:
              type: grep_negative
              file: README.md
              pattern: "forbidden"
        """
        let url = try writeTempYAML(yaml)
        do {
            _ = try ChecklistManifest.load(yamlURL: url)
            Issue.record("expected DecodingError on missing expected_count")
        } catch let DecodingError.dataCorrupted(ctx) {
            #expect(ctx.debugDescription.contains("D-17"))
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test("D-17: grep_positive without expected_count throws DecodingError")
    func grepPositiveMissingExpectedCountThrows() throws {
        let yaml = """
        phase: test
        items:
          - id: T-01
            description: "should reject"
            mechanization:
              type: grep_positive
              file: README.md
              pattern: "required"
        """
        let url = try writeTempYAML(yaml)
        do {
            _ = try ChecklistManifest.load(yamlURL: url)
            Issue.record("expected DecodingError on missing expected_count")
        } catch let DecodingError.dataCorrupted(ctx) {
            #expect(ctx.debugDescription.contains("D-17"))
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test("D-17: codesign_grep without expected_count throws DecodingError")
    func codesignGrepMissingExpectedCountThrows() throws {
        let yaml = """
        phase: test
        items:
          - id: T-01
            description: "should reject"
            mechanization:
              type: codesign_grep
              identity: build/Jarvis.app
              pattern: "com.apple.security.cs.allow-jit"
        """
        let url = try writeTempYAML(yaml)
        do {
            _ = try ChecklistManifest.load(yamlURL: url)
            Issue.record("expected DecodingError on missing expected_count")
        } catch let DecodingError.dataCorrupted(ctx) {
            #expect(ctx.debugDescription.contains("D-17"))
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test("plist_check decodes Bool/Int/String expected_value")
    func plistCheckDecodes() throws {
        let yaml = """
        phase: test
        items:
          - id: T-bool
            description: "bool key"
            mechanization:
              type: plist_check
              file: Info.plist
              key: LSUIElement
              expected_value: true
          - id: T-int
            description: "int key"
            mechanization:
              type: plist_check
              file: Info.plist
              key: VersionMajor
              expected_value: 1
          - id: T-str
            description: "string key"
            mechanization:
              type: plist_check
              file: Info.plist
              key: CFBundleIdentifier
              expected_value: com.example.test
        """
        let url = try writeTempYAML(yaml)
        let m = try ChecklistManifest.load(yamlURL: url)
        #expect(m.items.count == 3)
        switch m.items[0].mechanization {
        case .plistCheck(_, _, .bool(let b)): #expect(b == true)
        default: Issue.record("expected .plistCheck(.bool)")
        }
        switch m.items[1].mechanization {
        case .plistCheck(_, _, .int(let i)): #expect(i == 1)
        default: Issue.record("expected .plistCheck(.int)")
        }
        switch m.items[2].mechanization {
        case .plistCheck(_, _, .string(let s)): #expect(s == "com.example.test")
        default: Issue.record("expected .plistCheck(.string)")
        }
    }

    @Test("Unknown mechanization type throws DecodingError")
    func unknownTypeThrows() throws {
        let yaml = """
        phase: test
        items:
          - id: T-01
            description: "bogus"
            mechanization:
              type: telepathy
              what: ever
        """
        let url = try writeTempYAML(yaml)
        do {
            _ = try ChecklistManifest.load(yamlURL: url)
            Issue.record("expected DecodingError on unknown type")
        } catch let DecodingError.dataCorrupted(ctx) {
            #expect(ctx.debugDescription.contains("Unknown mechanization type"))
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    // MARK: - Runner dispatch tests

    @Test("MANUAL items pass with warnedAsManual=true")
    func manualItemDispatch() async throws {
        let (yamlURL, repoRoot) = try makeFixtureRepo(yaml: """
        phase: test
        items:
          - id: M-01
            description: "physical-hardware step"
            mechanization:
              type: MANUAL
              description: "operator does X"
        """)
        let runner = ChecklistRunner()
        let result = try await runner.runManifest(at: yamlURL, repoRoot: repoRoot)
        #expect(result.passed) // failed=0
        #expect(result.manualCount == 1)
        #expect(result.failedCount == 0)
        #expect(result.results[0].warnedAsManual)
        #expect(result.results[0].passed)
        #expect(result.results[0].detail.contains("MANUAL"))
    }

    @Test("script item: exit 0 → pass")
    func scriptPasses() async throws {
        let (yamlURL, repoRoot) = try makeFixtureRepo(yaml: """
        phase: test
        items:
          - id: S-OK
            description: "script returns 0"
            mechanization:
              type: script
              path: scripts/zz-test-pass.sh
        """)
        try writeScript(repoRoot: repoRoot, name: "zz-test-pass.sh", body: "#!/usr/bin/env bash\nexit 0\n")
        let runner = ChecklistRunner()
        let result = try await runner.runManifest(at: yamlURL, repoRoot: repoRoot)
        #expect(result.passed)
        #expect(result.results[0].passed)
    }

    @Test("script item: exit non-zero → fail")
    func scriptFails() async throws {
        let (yamlURL, repoRoot) = try makeFixtureRepo(yaml: """
        phase: test
        items:
          - id: S-FAIL
            description: "script returns 7"
            mechanization:
              type: script
              path: scripts/zz-test-fail.sh
        """)
        try writeScript(repoRoot: repoRoot, name: "zz-test-fail.sh", body: "#!/usr/bin/env bash\nexit 7\n")
        let runner = ChecklistRunner()
        let result = try await runner.runManifest(at: yamlURL, repoRoot: repoRoot)
        #expect(!result.passed)
        #expect(!result.results[0].passed)
    }

    @Test("grep_negative passes when count matches expected")
    func grepNegativePass() async throws {
        let (yamlURL, repoRoot) = try makeFixtureRepo(yaml: """
        phase: test
        items:
          - id: G-NEG
            description: "no forbidden token"
            mechanization:
              type: grep_negative
              file: payload.txt
              pattern: "FORBIDDEN_TOKEN"
              expected_count: 0
        """)
        let payload = repoRoot.appendingPathComponent("payload.txt")
        try "all clean here\n".write(to: payload, atomically: true, encoding: .utf8)
        let runner = ChecklistRunner()
        let result = try await runner.runManifest(at: yamlURL, repoRoot: repoRoot)
        #expect(result.passed)
    }

    @Test("grep_negative fails when token leaks")
    func grepNegativeFail() async throws {
        let (yamlURL, repoRoot) = try makeFixtureRepo(yaml: """
        phase: test
        items:
          - id: G-NEG
            description: "no forbidden token"
            mechanization:
              type: grep_negative
              file: payload.txt
              pattern: "BANNED"
              expected_count: 0
        """)
        let payload = repoRoot.appendingPathComponent("payload.txt")
        try "this has BANNED inside\n".write(to: payload, atomically: true, encoding: .utf8)
        let runner = ChecklistRunner()
        let result = try await runner.runManifest(at: yamlURL, repoRoot: repoRoot)
        #expect(!result.passed)
    }

    @Test("grep_positive matches expected count")
    func grepPositiveMatches() async throws {
        let (yamlURL, repoRoot) = try makeFixtureRepo(yaml: """
        phase: test
        items:
          - id: G-POS
            description: "exactly two markers"
            mechanization:
              type: grep_positive
              file: payload.txt
              pattern: "MARKER"
              expected_count: 2
        """)
        let payload = repoRoot.appendingPathComponent("payload.txt")
        try "MARKER one\nplain\nMARKER two\n".write(to: payload, atomically: true, encoding: .utf8)
        let runner = ChecklistRunner()
        let result = try await runner.runManifest(at: yamlURL, repoRoot: repoRoot)
        #expect(result.passed)
    }

    @Test("grep filters out commented lines")
    func grepFiltersComments() async throws {
        // A self-documenting comment that mentions the pattern must not
        // self-invalidate the manifest (CLAUDE.md grep gate hygiene).
        let (yamlURL, repoRoot) = try makeFixtureRepo(yaml: """
        phase: test
        items:
          - id: G-NEG-COMMENT
            description: "no real hit"
            mechanization:
              type: grep_negative
              file: payload.txt
              pattern: "TOKEN"
              expected_count: 0
        """)
        let payload = repoRoot.appendingPathComponent("payload.txt")
        try "# this comment mentions TOKEN but is filtered\nclean line\n"
            .write(to: payload, atomically: true, encoding: .utf8)
        let runner = ChecklistRunner()
        let result = try await runner.runManifest(at: yamlURL, repoRoot: repoRoot)
        #expect(result.passed)
    }

    @Test("swift_test row: coherent suite+test passes (advisory)")
    func swiftTestAdvisoryPass() async throws {
        let (yamlURL, repoRoot) = try makeFixtureRepo(yaml: """
        phase: test
        items:
          - id: ST-01
            description: "swift_test row"
            mechanization:
              type: swift_test
              suite: ChecklistRunnerTests
              test: swiftTestAdvisoryPass
        """)
        let runner = ChecklistRunner()
        let result = try await runner.runManifest(at: yamlURL, repoRoot: repoRoot)
        #expect(result.passed)
    }

    @Test("script outside repo throws RunError")
    func scriptOutsideRepoRejected() async throws {
        let (yamlURL, repoRoot) = try makeFixtureRepo(yaml: """
        phase: test
        items:
          - id: S-EVIL
            description: "absolute path attempt"
            mechanization:
              type: script
              path: /etc/passwd
        """)
        let runner = ChecklistRunner()
        do {
            _ = try await runner.runManifest(at: yamlURL, repoRoot: repoRoot)
            Issue.record("expected RunError.scriptOutsideRepo")
        } catch ChecklistRunner.RunError.scriptOutsideRepo {
            // pass
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    // MARK: - Helpers

    private func writeTempYAML(_ contents: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("checklist-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("manifest.yaml")
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func makeFixtureRepo(yaml: String) throws -> (URL, URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("checklist-fixture-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("scripts"),
            withIntermediateDirectories: true
        )
        let yamlURL = root.appendingPathComponent("manifest.yaml")
        try yaml.write(to: yamlURL, atomically: true, encoding: .utf8)
        return (yamlURL, root)
    }

    private func writeScript(repoRoot: URL, name: String, body: String) throws {
        let path = repoRoot.appendingPathComponent("scripts").appendingPathComponent(name)
        try body.write(to: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: path.path
        )
    }
}
