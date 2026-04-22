import SwiftUI
import AppKit

/// SwiftUI glue that hosts a `ShortcutRecorderHostView` and drives two
/// bindings (the recorded shortcut + an inline error message). The Coordinator
/// implements `ShortcutRecorderHostView.Delegate` and writes into the parent
/// bindings on recorded / rejected callbacks.
///
/// Usage (from Wizard Stage 3):
///
///     @State private var shortcut: KeyboardShortcut? = nil
///     @State private var errorMessage: String? = nil
///     ShortcutRecorderView(shortcut: $shortcut, errorMessage: $errorMessage)
public struct ShortcutRecorderView: NSViewRepresentable {
    @Binding var shortcut: KeyboardShortcut?
    @Binding var errorMessage: String?

    public init(
        shortcut: Binding<KeyboardShortcut?>,
        errorMessage: Binding<String?>
    ) {
        self._shortcut = shortcut
        self._errorMessage = errorMessage
    }

    public func makeNSView(context: Context) -> ShortcutRecorderHostView {
        let view = ShortcutRecorderHostView()
        view.delegate = context.coordinator
        return view
    }

    public func updateNSView(_ view: ShortcutRecorderHostView, context: Context) {
        context.coordinator.parent = self
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    @MainActor
    public final class Coordinator: ShortcutRecorderHostView.Delegate {
        var parent: ShortcutRecorderView
        init(parent: ShortcutRecorderView) { self.parent = parent }

        public func shortcutRecorder(
            _ view: ShortcutRecorderHostView,
            recorded shortcut: KeyboardShortcut
        ) {
            parent.shortcut = shortcut
            parent.errorMessage = nil
        }

        public func shortcutRecorder(
            _ view: ShortcutRecorderHostView,
            rejected reason: String
        ) {
            parent.errorMessage = reason
        }

        public func shortcutRecorderDidAbort(_ view: ShortcutRecorderHostView) {
            // User pressed Escape; keep previous shortcut (if any) unchanged.
        }
    }
}
