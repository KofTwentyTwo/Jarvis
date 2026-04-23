// Control file: uses the allowed API. The HUD-04 lint script must NOT flag this.
import WebKit

func goodCall(_ webView: WKWebView, _ json: String) async throws {
    _ = try await webView.callAsyncJavaScript(
        "window.foo(payload)",
        arguments: ["payload": json],
        in: nil,
        contentWorld: .defaultClient
    )
}
