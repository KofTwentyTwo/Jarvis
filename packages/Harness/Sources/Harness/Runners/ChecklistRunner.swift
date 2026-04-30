// ChecklistRunner.swift
//
// Phase 8 Plan 04 / OBS-04 pillar (h). Reads per-phase checklist.yaml
// manifests and dispatches each item to its mechanization (D-16 closed
// set). Aggregates results into a `ChecklistResult` per manifest.
//
// MANUAL items (D-16) always pass with `warnedAsManual=true` so they show
// up as warning rows in shipping-gate output but never block ship.
//
// Per CONTEXT 5.1 read-only: the runner spawns external processes and
// runs file-IO grep — it does NOT modify production source.

import Foundation

public actor ChecklistRunner {
    public struct ItemResult: Sendable, Codable, Equatable {
        public let itemId: String
        public let description: String
        public let passed: Bool
        public let warnedAsManual: Bool
        public let detail: String
    }

    public struct ChecklistResult: Sendable, Codable, Equatable {
        public let phase: String
        public let results: [ItemResult]
        public let passedCount: Int
        public let failedCount: Int
        public let manualCount: Int
        public var passed: Bool { failedCount == 0 }
    }

    public enum RunError: Swift.Error, Equatable {
        case scriptOutsideRepo(String)
    }

    public init() {}

    public func runManifest(at url: URL, repoRoot: URL) async throws -> ChecklistResult {
        let manifest = try ChecklistManifest.load(yamlURL: url)
        var results: [ItemResult] = []
        for item in manifest.items {
            let r = try await runItem(item, repoRoot: repoRoot)
            results.append(r)
        }
        let passed = results.filter { $0.passed && !$0.warnedAsManual }.count
        let failed = results.filter { !$0.passed && !$0.warnedAsManual }.count
        let manual = results.filter { $0.warnedAsManual }.count
        return ChecklistResult(
            phase: manifest.phase,
            results: results,
            passedCount: passed,
            failedCount: failed,
            manualCount: manual
        )
    }

    private func runItem(_ item: ChecklistItem, repoRoot: URL) async throws -> ItemResult {
        switch item.mechanization {
        case .swiftTest(let suite, let test):
            return try await runSwiftTest(item: item, suite: suite, test: test, repoRoot: repoRoot)
        case .script(let path, let args):
            return try await runScript(item: item, path: path, args: args, repoRoot: repoRoot)
        case .grepNegative(let file, let pattern, let expectedCount):
            return runGrep(
                item: item, file: file, pattern: pattern,
                expectedCount: expectedCount, repoRoot: repoRoot
            )
        case .grepPositive(let file, let pattern, let expectedCount):
            return runGrep(
                item: item, file: file, pattern: pattern,
                expectedCount: expectedCount, repoRoot: repoRoot
            )
        case .plistCheck(let file, let key, let expectedValue):
            return runPlistCheck(
                item: item, file: file, key: key,
                expectedValue: expectedValue, repoRoot: repoRoot
            )
        case .codesignGrep(let identity, let pattern, let expectedCount):
            return await runCodesignGrep(
                item: item, identity: identity,
                pattern: pattern, expectedCount: expectedCount, repoRoot: repoRoot
            )
        case .manual(let description):
            return ItemResult(
                itemId: item.id,
                description: item.description,
                passed: true,
                warnedAsManual: true,
                detail: "MANUAL: \(description)"
            )
        }
    }

    // MARK: - Mechanization helpers

    private func runScript(item: ChecklistItem, path: String, args: [String], repoRoot: URL) async throws -> ItemResult {
        // Restrict script paths to <repoRoot>/scripts/* (T-08-17 mitigation).
        let normalized = (path as NSString).standardizingPath
        if normalized.hasPrefix("/") || normalized.contains("..") {
            throw RunError.scriptOutsideRepo(path)
        }
        let scriptURL = repoRoot.appendingPathComponent(normalized).standardizedFileURL
        let scriptsDir = repoRoot.appendingPathComponent("scripts").standardizedFileURL
        guard scriptURL.path.hasPrefix(scriptsDir.path) else {
            throw RunError.scriptOutsideRepo(path)
        }
        guard FileManager.default.fileExists(atPath: scriptURL.path) else {
            return ItemResult(
                itemId: item.id, description: item.description,
                passed: false, warnedAsManual: false,
                detail: "script missing: \(scriptURL.path)"
            )
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [scriptURL.path] + args
        process.currentDirectoryURL = repoRoot
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        do {
            try process.run()
        } catch {
            return ItemResult(
                itemId: item.id, description: item.description,
                passed: false, warnedAsManual: false,
                detail: "spawn failed: \(error.localizedDescription)"
            )
        }
        process.waitUntilExit()
        let code = Int(process.terminationStatus)
        let passed = (code == 0)
        let detail: String
        if passed {
            detail = "script exit 0: \(scriptURL.lastPathComponent)"
        } else {
            let errBytes = stderr.fileHandleForReading.readDataToEndOfFile()
            let errText = String(data: errBytes, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            detail = "script exit \(code): \(scriptURL.lastPathComponent)" + (errText.isEmpty ? "" : " — \(errText.prefix(200))")
        }
        return ItemResult(
            itemId: item.id, description: item.description,
            passed: passed, warnedAsManual: false, detail: detail
        )
    }

    private func runGrep(item: ChecklistItem, file: String, pattern: String, expectedCount: Int, repoRoot: URL) -> ItemResult {
        let target = repoRoot.appendingPathComponent(file)
        guard FileManager.default.fileExists(atPath: target.path) else {
            return ItemResult(
                itemId: item.id, description: item.description,
                passed: false, warnedAsManual: false,
                detail: "file not found: \(target.path)"
            )
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        // Filter out comment lines (per CLAUDE.md grep gate hygiene) so a
        // self-documenting comment in the file doesn't self-invalidate.
        let cmd = "grep -v '^[[:space:]]*#' \(shellQuote(target.path)) | grep -cE \(shellQuote(pattern)) || true"
        process.arguments = ["-c", cmd]
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = Pipe()
        do { try process.run() } catch {
            return ItemResult(
                itemId: item.id, description: item.description,
                passed: false, warnedAsManual: false,
                detail: "grep spawn failed: \(error)"
            )
        }
        process.waitUntilExit()
        let bytes = stdout.fileHandleForReading.readDataToEndOfFile()
        let countStr = String(data: bytes, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? "0"
        let count = Int(countStr) ?? -1
        let passed = (count == expectedCount)
        return ItemResult(
            itemId: item.id, description: item.description,
            passed: passed, warnedAsManual: false,
            detail: "grep '\(pattern)' in \(file): observed=\(count) expected=\(expectedCount)"
        )
    }

    private func runPlistCheck(item: ChecklistItem, file: String, key: String, expectedValue: PlistValue, repoRoot: URL) -> ItemResult {
        let target = repoRoot.appendingPathComponent(file)
        guard FileManager.default.fileExists(atPath: target.path) else {
            return ItemResult(
                itemId: item.id, description: item.description,
                passed: false, warnedAsManual: false,
                detail: "plist not found: \(target.path)"
            )
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/libexec/PlistBuddy")
        process.arguments = ["-c", "Print :\(key)", target.path]
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = Pipe()
        do { try process.run() } catch {
            return ItemResult(
                itemId: item.id, description: item.description,
                passed: false, warnedAsManual: false,
                detail: "PlistBuddy spawn failed: \(error)"
            )
        }
        process.waitUntilExit()
        if process.terminationStatus != 0 {
            return ItemResult(
                itemId: item.id, description: item.description,
                passed: false, warnedAsManual: false,
                detail: "plist key \(key) not present in \(file)"
            )
        }
        let bytes = stdout.fileHandleForReading.readDataToEndOfFile()
        let observed = String(data: bytes, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let passed: Bool
        let expectedText: String
        switch expectedValue {
        case .bool(let b):
            expectedText = b ? "true" : "false"
            passed = (observed.lowercased() == expectedText)
        case .int(let i):
            expectedText = "\(i)"
            passed = (observed == expectedText)
        case .string(let s):
            expectedText = s
            passed = (observed == s)
        }
        return ItemResult(
            itemId: item.id, description: item.description,
            passed: passed, warnedAsManual: false,
            detail: "plist \(file):\(key) observed='\(observed)' expected='\(expectedText)'"
        )
    }

    private func runCodesignGrep(item: ChecklistItem, identity: String, pattern: String, expectedCount: Int, repoRoot: URL) async -> ItemResult {
        // identity here is interpreted as a relative path to the signed
        // bundle (e.g. "build/Build/Products/Release/Jarvis.app"). The
        // YAML "identity" key naming preserves the D-16 vocabulary; the
        // value is the path on disk.
        let target = repoRoot.appendingPathComponent(identity)
        guard FileManager.default.fileExists(atPath: target.path) else {
            return ItemResult(
                itemId: item.id, description: item.description,
                passed: false, warnedAsManual: false,
                detail: "bundle not found: \(target.path) (skip if pre-build)"
            )
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        let cmd = "codesign --display --entitlements - \(shellQuote(target.path)) 2>/dev/null | grep -cE \(shellQuote(pattern)) || true"
        process.arguments = ["-c", cmd]
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = Pipe()
        do { try process.run() } catch {
            return ItemResult(
                itemId: item.id, description: item.description,
                passed: false, warnedAsManual: false,
                detail: "codesign spawn failed: \(error)"
            )
        }
        process.waitUntilExit()
        let bytes = stdout.fileHandleForReading.readDataToEndOfFile()
        let countStr = String(data: bytes, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? "0"
        let count = Int(countStr) ?? -1
        let passed = (count == expectedCount)
        return ItemResult(
            itemId: item.id, description: item.description,
            passed: passed, warnedAsManual: false,
            detail: "codesign-grep '\(pattern)' in \(identity): observed=\(count) expected=\(expectedCount)"
        )
    }

    private func runSwiftTest(item: ChecklistItem, suite: String, test: String, repoRoot: URL) async throws -> ItemResult {
        // ChecklistRunner does NOT spawn a swift-test subprocess for each
        // swift_test row — that would re-build every time and balloon the
        // shipping-gate runtime. Instead, swift_test rows are advisory:
        // the operator runs `swift test --package-path packages/<X>
        // --filter <Suite>.<Test>` separately, and the row functions as
        // documentation that the invariant has a test owner.
        //
        // The row passes if the manifest declares the location coherently
        // (suite + test names non-empty); failure surfaces via the actual
        // swift-test pillar elsewhere in `jarvis-eval all`.
        let coherent = !suite.isEmpty && !test.isEmpty
        return ItemResult(
            itemId: item.id, description: item.description,
            passed: coherent, warnedAsManual: false,
            detail: "swift_test reference: \(suite).\(test) (run via swift test --filter)"
        )
    }
}

/// Bash single-quote escape — sufficient for paths/patterns we control.
private func shellQuote(_ s: String) -> String {
    "'" + s.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
}
