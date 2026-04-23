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
});
