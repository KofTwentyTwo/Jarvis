// Deliberately bad: contains a forbidden evaluateJavaScript call.
// The HUD-04 lint script must flag this file.
import WebKit

func badCall(_ webView: WKWebView, _ json: String) {
    webView.evaluateJavaScript("window.foo(\(json))")
}
