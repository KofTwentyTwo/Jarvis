import { describe, it, expect, beforeEach, vi } from "vitest";
import { installJarvisBus } from "../src/bridge.js";
import { BUS_PROTOCOL_VERSION } from "../src/protocol.js";

describe("installJarvisBus", () => {
  let postMessage: ReturnType<typeof vi.fn>;

  beforeEach(() => {
    postMessage = vi.fn().mockResolvedValue({ ok: true });
    // @ts-expect-error — test shim: replace the global window with a minimal
    // stub exposing only webkit.messageHandlers.jarvisBus.
    globalThis.window = {
      webkit: { messageHandlers: { jarvisBus: { postMessage } } },
    };
  });

  it("installs window.jarvisBus with the correct protocol version", () => {
    installJarvisBus();
    expect(window.jarvisBus).toBeDefined();
    expect(window.jarvisBus.protocolVersion).toBe(BUS_PROTOCOL_VERSION);
  });

  it("dispatches decoded outbound to the registered handler", () => {
    installJarvisBus();
    const handler = vi.fn();
    window.jarvisBus.onOutbound(handler);
    window.jarvisBus.receive(`{"type":"hudState","state":"thinking"}`);
    expect(handler).toHaveBeenCalledWith({ type: "hudState", state: "thinking" });
  });

  it("auto-acks hello when no handler is registered", async () => {
    installJarvisBus();
    window.jarvisBus.receive(`{"type":"hello","version":"2.0.0"}`);
    // Let the async send fire
    await new Promise((r) => setTimeout(r, 0));
    expect(postMessage).toHaveBeenCalledWith(
      `{"type":"helloAck","version":"${BUS_PROTOCOL_VERSION}"}`
    );
  });

  it("surfaces decode errors to onDecodeError, does not throw", () => {
    const onDecodeError = vi.fn();
    installJarvisBus({ onDecodeError });
    expect(() => window.jarvisBus.receive(`{not json`)).not.toThrow();
    expect(onDecodeError).toHaveBeenCalled();
    const firstCall = onDecodeError.mock.calls[0];
    expect(firstCall).toBeDefined();
    const [error] = firstCall as [string, string];
    expect(error).toContain("parse error");
  });

  it("send() JSON-encodes and posts to webkit.messageHandlers.jarvisBus", async () => {
    installJarvisBus();
    const reply = await window.jarvisBus.send({ type: "uiReady" });
    expect(postMessage).toHaveBeenCalledWith(`{"type":"uiReady"}`);
    expect(reply).toEqual({ ok: true });
  });

  it("throws helpful error if webkit is missing", async () => {
    // @ts-expect-error — test shim: webkit intentionally absent
    globalThis.window = {};
    installJarvisBus();
    await expect(window.jarvisBus.send({ type: "uiReady" })).rejects.toThrow(/webkit/);
  });

  it("onOutbound latest wins", () => {
    installJarvisBus();
    const a = vi.fn();
    const b = vi.fn();
    window.jarvisBus.onOutbound(a);
    window.jarvisBus.onOutbound(b);
    window.jarvisBus.receive(`{"type":"hudState","state":"idle"}`);
    expect(a).not.toHaveBeenCalled();
    expect(b).toHaveBeenCalledOnce();
  });

  // H-02: both `Injection.js` (`WKUserScript` at document-start) and this
  // bundle's `installJarvisBus()` run in the SAME page world since `fb41c5f`
  // retired the prior isolated named content world. Injection.js fires first
  // and stamps a minimal `window.jarvisBus`; if `installJarvisBus()` naively
  // overwrote it, the early handshake state and queued messages captured
  // against the original closure would be orphaned. Therefore the bundle's
  // installer must attach to — not replace — a pre-existing bus.
  describe("H-02 attach-to-existing (pre-installed window.jarvisBus)", () => {
    it("returns the pre-existing bus unchanged when one is already installed", () => {
      const preExistingSend = vi.fn().mockResolvedValue(undefined);
      const preExistingOnOutbound = vi.fn();
      const preExistingReceive = vi.fn();
      const preExisting = {
        protocolVersion: "2.0.0",
        send: preExistingSend,
        onOutbound: preExistingOnOutbound,
        receive: preExistingReceive,
      };
      // @ts-expect-error — test shim: seed a pre-installed bus shape matching Injection.js
      globalThis.window = {
        jarvisBus: preExisting,
        // Note: webkit is intentionally absent — Injection.js's pre-existing
        // bus captures a reference to `window.webkit` at install time, and the
        // shape guard must trust the pre-existing bus to route through that
        // captured reference rather than re-resolving `webkit` here.
      };

      installJarvisBus();

      // Attach-to-existing: window.jarvisBus is the SAME object as before,
      // not a replacement.
      expect(window.jarvisBus).toBe(preExisting);
      expect(window.jarvisBus.send).toBe(preExistingSend);
      expect(window.jarvisBus.onOutbound).toBe(preExistingOnOutbound);
    });

    it("routes send() through the pre-existing bus's send (reaches Injection.js-captured handler)", async () => {
      const preExistingSend = vi.fn().mockResolvedValue({ ok: true });
      const preExisting = {
        protocolVersion: "2.0.0",
        send: preExistingSend,
        onOutbound: vi.fn(),
        receive: vi.fn(),
      };
      // @ts-expect-error — test shim
      globalThis.window = { jarvisBus: preExisting };

      installJarvisBus();
      const reply = await window.jarvisBus.send({ type: "uiReady" });

      // The pre-existing send was called (not a replacement).
      expect(preExistingSend).toHaveBeenCalledWith({ type: "uiReady" });
      expect(reply).toEqual({ ok: true });
    });

    it("registers outbound handler on the pre-existing bus's onOutbound slot", () => {
      const preExistingOnOutbound = vi.fn();
      const preExisting = {
        protocolVersion: "2.0.0",
        send: vi.fn(),
        onOutbound: preExistingOnOutbound,
        receive: vi.fn(),
      };
      // @ts-expect-error — test shim
      globalThis.window = { jarvisBus: preExisting };

      installJarvisBus();
      const handler = vi.fn();
      window.jarvisBus.onOutbound(handler);

      expect(preExistingOnOutbound).toHaveBeenCalledWith(handler);
    });

    it("falls through to fresh install when no pre-existing bus is present (bus-harness.html path)", () => {
      // Baseline: nothing on window.jarvisBus → fresh install must still win.
      installJarvisBus();
      expect(window.jarvisBus).toBeDefined();
      expect(window.jarvisBus.protocolVersion).toBe(BUS_PROTOCOL_VERSION);
      // Fresh bus's send reaches webkit directly (configured by outer beforeEach).
      void window.jarvisBus.send({ type: "uiReady" });
      expect(postMessage).toHaveBeenCalledWith(`{"type":"uiReady"}`);
    });

    it("falls through to fresh install if pre-existing value lacks the bus shape", () => {
      // A non-bus-shaped leftover (e.g. stale test debris) must not hijack
      // the install — we overwrite, matching pre-H-02 behavior for that path.
      // @ts-expect-error — test shim: jarvisBus lacks send/onOutbound/receive
      globalThis.window = {
        jarvisBus: { something: "else" },
        webkit: { messageHandlers: { jarvisBus: { postMessage } } },
      };
      installJarvisBus();
      expect(typeof window.jarvisBus.send).toBe("function");
      expect(typeof window.jarvisBus.onOutbound).toBe("function");
      expect(window.jarvisBus.protocolVersion).toBe(BUS_PROTOCOL_VERSION);
    });
  });
});
