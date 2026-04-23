/**
 * `window.jarvisBus` glue — the only TS surface that calls
 * `webkit.messageHandlers.jarvisBus.postMessage`. All other app code routes
 * through `window.jarvisBus.send(msg)` / `onOutbound(handler)`.
 *
 * Trust boundary: Swift is the source of truth; this module is a thin
 * transport. Decoding happens in `protocol.ts` which never throws.
 */

import {
  BUS_PROTOCOL_VERSION,
  decodeOutbound,
  encodeInbound,
  type BusInbound,
  type BusOutbound,
} from "./protocol.js";

export type OutboundHandler = (msg: BusOutbound) => void;
export type DecodeErrorHandler = (error: string, raw: string) => void;

declare global {
  interface Window {
    jarvisBus: JarvisBus;
    webkit?: {
      messageHandlers: {
        jarvisBus: { postMessage(body: unknown): Promise<unknown> };
      };
    };
  }
}

export interface JarvisBus {
  /** Called by Swift via `callAsyncJavaScript("window.jarvisBus.receive(payload)", ...)`. */
  receive(payload: string): void;
  /** Send a BusInbound to Swift. Returns the Promise resolved by Swift's replyHandler. */
  send(msg: BusInbound): Promise<unknown>;
  /** Register the outbound handler (latest wins). Auto-acks hello internally if unset. */
  onOutbound(handler: OutboundHandler): void;
  readonly protocolVersion: string;
}

export interface InstallOptions {
  onDecodeError?: DecodeErrorHandler;
}

/**
 * Install `window.jarvisBus`. Call once at document-start.
 *
 * Behavior:
 * - `receive(payload)` decodes via `decodeOutbound`; valid messages go to the
 *   registered `onOutbound` handler; decode failures go to `onDecodeError`
 *   (default: `console.error`).
 * - If a `hello` message arrives BEFORE `onOutbound` is registered, the bridge
 *   synthesizes the `helloAck` response itself so the handshake completes with
 *   the minimal `bus-harness.html` stub. P3's real HUD registers a handler
 *   early, so this branch never fires in production.
 * - `send(msg)` JSON-encodes and posts to `webkit.messageHandlers.jarvisBus`.
 *   Callers await the returned Promise to observe Swift's reply.
 *
 * Returns a cleanup fn (noop in production; useful for tests).
 */
export function installJarvisBus(options: InstallOptions = {}): () => void {
  const onDecodeError: DecodeErrorHandler =
    options.onDecodeError ??
    ((error, raw) => {
      // eslint-disable-next-line no-console
      console.error("[bus] decode failed:", error, raw);
    });

  let handler: OutboundHandler | null = null;

  const bus: JarvisBus = {
    protocolVersion: BUS_PROTOCOL_VERSION,

    receive(payload: string): void {
      const result = decodeOutbound(payload);
      if (!result.ok) {
        onDecodeError(result.error, payload);
        return;
      }
      if (handler) {
        handler(result.value);
        return;
      }
      // No handler yet. Auto-ack `hello` so a minimal harness (bus-harness.html)
      // can complete the handshake without any page-side code.
      if (result.value.type === "hello") {
        void bus.send({ type: "helloAck", version: BUS_PROTOCOL_VERSION });
        return;
      }
      // Other messages before a handler is registered are dropped, but we
      // surface them so misconfigured harnesses are loud.
      onDecodeError("received message before onOutbound handler", payload);
    },

    async send(msg: BusInbound): Promise<unknown> {
      const json = encodeInbound(msg);
      const handlers = window.webkit?.messageHandlers?.jarvisBus;
      if (!handlers) {
        throw new Error("[bus] webkit.messageHandlers.jarvisBus is not available");
      }
      return handlers.postMessage(json);
    },

    onOutbound(newHandler: OutboundHandler): void {
      handler = newHandler;
    },
  };

  window.jarvisBus = bus;
  return () => {
    /* test cleanup — noop in production */
  };
}
