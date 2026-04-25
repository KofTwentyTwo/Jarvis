// Fixture: WR-01 (REVIEW 05) — string literals and block comments that
// mention runModal must NOT trigger the lint. Pre-WR-01, the script
// matched `runModal\b` inside string contents.
//
// scripts/check-no-modal-presentation.sh must accept this file in
// `--fixture` mode (exit code 0).
import AppKit

func mentionInString() {
    let docs = "Use NSAlert.runModal() to block the main actor; we forbid this."
    print(docs)
}

/* Block comment that mentions runModal() — also must not trigger. */
func mentionInBlockComment() {
    let other = "the runModal( call is forbidden"
    print(other)
}

// Regular trailing comment: do not call runModal() either.
func legitimateCallSite(parent: NSWindow, child: NSWindow) {
    parent.beginSheet(child) { _ in }
}
