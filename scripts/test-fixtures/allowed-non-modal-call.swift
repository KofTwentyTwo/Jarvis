// Fixture: uses beginSheet (allowed) and contains zero modal calls.
// scripts/check-no-modal-presentation.sh must accept this file in
// `--fixture` mode (exit code 0) — Plan 05-05 Task 5 self-test.
import AppKit

func good(parent: NSWindow, child: NSWindow) {
    parent.beginSheet(child) { _ in }
}
