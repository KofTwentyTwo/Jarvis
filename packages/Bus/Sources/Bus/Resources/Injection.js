// Injected at document-start in WKContentWorld("JarvisBusWorld").
// Installs window.jarvisBus with the minimum surface needed to complete
// the handshake. bus-harness.html's <script type="module"> can load the full
// TS-compiled version and REPLACE window.jarvisBus when the module
// evaluates — but the injection ensures a handler exists even before
// the module fetch completes (race prevention per RESEARCH §pitfall 3).
(function () {
  "use strict";
  if (window.jarvisBus) { return; }
  window.jarvisBus = {
    protocolVersion: "2.0.0",
    _handler: null,
    _pendingHello: null,
    receive: function (payload) {
      var msg;
      try { msg = JSON.parse(payload); }
      catch (e) {
        console.error("[bus] parse error:", e);
        return;
      }
      if (!msg || typeof msg.type !== "string") {
        console.error("[bus] missing discriminator");
        return;
      }
      if (this._handler) { this._handler(msg); return; }
      if (msg.type === "hello") {
        this.send({ type: "helloAck", version: this.protocolVersion });
      } else {
        this._pendingHello = msg;
        console.warn("[bus] received before handler registered");
      }
    },
    send: function (inbound) {
      if (!window.webkit || !window.webkit.messageHandlers || !window.webkit.messageHandlers.jarvisBus) {
        return Promise.reject(new Error("webkit.messageHandlers.jarvisBus missing"));
      }
      return window.webkit.messageHandlers.jarvisBus.postMessage(JSON.stringify(inbound));
    },
    onOutbound: function (fn) {
      this._handler = fn;
      if (this._pendingHello) {
        fn(this._pendingHello);
        this._pendingHello = null;
      }
    }
  };
})();
