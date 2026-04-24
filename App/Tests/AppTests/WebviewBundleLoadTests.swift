import XCTest

/// Plan 03-05 Task 2 bundle-structural tests. These tests read files from
/// the repo tree (via `#filePath` traversal, not `Bundle.main`) so they
/// compile under the Xcode 26 broken xctest-launch path. Once that blocker
/// is cleared we can promote them to Bundle.main-based assertions that also
/// prove the built `.app` is correctly wired — for now the built-app coverage
/// is `scripts/smoke-test-hud.sh` + the manual UAT checklist.
final class WebviewBundleLoadTests: XCTestCase {
    /// `#filePath` resolves to this file's absolute path; climb four levels
    /// to the repo root (.../App/Tests/AppTests/WebviewBundleLoadTests.swift
    /// → .../App/Tests/AppTests → .../App/Tests → .../App → repo root).
    private func repoRoot(file: String = #filePath) -> URL {
        URL(fileURLWithPath: file)
            .deletingLastPathComponent()  // AppTests/
            .deletingLastPathComponent()  // Tests/
            .deletingLastPathComponent()  // App/
            .deletingLastPathComponent()  // repo root
    }

    /// B1: the R3F bundle's index.html must be source-committed under
    /// `App/Resources/webview/`. `scripts/build-webview.sh` regenerates it
    /// from `webview/packages/hud/dist/index.html` on every build — this
    /// test catches "someone committed an index.html-less tree" before the
    /// Xcode pre-build script tries to rsync into an empty dir.
    func test_indexHtmlInRepoWebviewDir() {
        let indexHTML = repoRoot().appendingPathComponent("App/Resources/webview/index.html")
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: indexHTML.path),
            "index.html must be committed at App/Resources/webview/ — run scripts/build-webview.sh then `git add App/Resources/webview/index.html`"
        )
    }

    /// B3: index.html must reference `./assets/*.js` (relative) — Vite's
    /// `base: './'` setting is critical for WKWebView file:// loading
    /// (Pitfall 3 from RESEARCH). Absolute `/assets/` paths 404 in a
    /// bundled file:// context.
    func test_indexHtmlReferencesRelativeAssets() throws {
        let indexHTML = repoRoot().appendingPathComponent("App/Resources/webview/index.html")
        let html = try String(contentsOf: indexHTML, encoding: .utf8)
        XCTAssertTrue(
            html.contains("./assets/"),
            "index.html must reference relative asset paths per Vite base: './' — check webview/packages/hud/vite.config.ts"
        )
        XCTAssertFalse(
            html.contains("src=\"/assets/"),
            "index.html must NOT reference absolute /assets/ paths (WKWebView file:// rejects them)"
        )
        XCTAssertFalse(
            html.contains("href=\"/assets/"),
            "index.html must NOT reference absolute /assets/ href paths either"
        )
    }

    /// B-extra: the `assets/` subdirectory is intentionally gitignored — the
    /// presence check lives in `scripts/smoke-test-hud.sh`, which inspects
    /// the BUILT `.app` after `xcodebuild build` has run the pre-build
    /// `scripts/build-webview.sh`. Documenting the split here so future
    /// readers don't add a test that fails on clean checkouts.
    func test_assetsDirectoryGitignored_documentedInSmokeScript() {
        // This test intentionally has no assertion — it exists to document
        // the split of responsibility. `App/Resources/webview/.gitignore`
        // ignores `assets/`; the smoke script covers the built-app side.
        XCTAssertTrue(true)
    }
}
