// Fixture: contains runModal() outside any allowlist.
// scripts/check-no-modal-presentation.sh must reject this file in
// `--fixture` mode (exit code 1) — Plan 05-05 Task 5 self-test.
import AppKit

func bad() {
    let alert = NSAlert()
    alert.messageText = "boom"
    let _ = alert.runModal()
}
