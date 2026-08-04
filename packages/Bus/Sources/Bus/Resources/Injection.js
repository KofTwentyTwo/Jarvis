// Injected at document-start in the page world (the default
// `WKContentWorld.page` since `fb41c5f` retired the prior isolated named
// world; see WebviewBridge.swift). Installs window.jarvisBus with the
// minimum surface needed to complete the handshake.
//
// IMPORTANT — protocolVersion drift hazard: the full TS bundle's installer
// (Vy() in the minified output) shape-checks window.jarvisBus and SKIPS
// replacement when send/receive/onOutbound already exist. That means this
// placeholder IS the version reported in helloAck — the full bundle never
// overwrites it. Drift here surfaces as a runtime "HUD bundle was built
// against bus protocol vX.Y.Z; the app expects vA.B.C" hard-fail.
//
// MUST be bumped in lock-step with packages/Bus/Sources/Bus/Protocol.swift
// and webview/packages/bus/src/protocol.ts. scripts/check-bus-protocol-version.sh
// enforces three-way parity at build time.
(function () {
  "use strict";
  if (window.jarvisBus) { return; }
  window.jarvisBus = {
    protocolVersion: "2.4.0",
    _handler: null,
    // Queue (not a single slot) of messages received before the bundle
    // registered its handler via onOutbound. With a single slot, an early
    // burst of state-change messages (e.g. hudState then ollama telemetry)
    // overwrote each other and only the last survived — manifesting as the
    // HUD staying pinned at .booting because the .hudState(.idle) emitted
    // immediately after handshake-armed got clobbered by a subsequent
    // non-hello message before the bundle finished loading.
    _pendingMessages: [],
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
      // Hello is owned by the stub regardless of whether the bundle
      // handler has registered. Two reasons:
      //   1. Pre-handler: nobody else can ack — the stub's auto-ack is
      //      the only path that gets the Swift handshake out of .sentHello.
      //   2. Post-handler: the bundle's outbound switch has `case 'hello':
      //      break` — it intentionally ignores hello at the application
      //      layer. If we route hello to the bundle handler, no ack is
      //      sent and the handshake times out. So we ack here and stop.
      if (msg.type === "hello") {
        this.send({ type: "helloAck", version: this.protocolVersion });
        return;
      }
      if (this._handler) { this._handler(msg); return; }
      this._pendingMessages.push(msg);
    },
    send: function (inbound) {
      if (!window.webkit || !window.webkit.messageHandlers || !window.webkit.messageHandlers.jarvisBus) {
        return Promise.reject(new Error("webkit.messageHandlers.jarvisBus missing"));
      }
      return window.webkit.messageHandlers.jarvisBus.postMessage(JSON.stringify(inbound));
    },
    onOutbound: function (fn) {
      this._handler = fn;
      // Replay buffered messages in arrival order, then clear.
      while (this._pendingMessages.length > 0) {
        fn(this._pendingMessages.shift());
      }
    }
  };
})();
