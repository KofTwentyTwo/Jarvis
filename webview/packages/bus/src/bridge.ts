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
 * ## WKContentWorld attach-to-existing path (H-02)
 *
 * When the HUD bundle runs in the page's default JS world (via
 * `<script type="module" src="…">`), `webkit.messageHandlers.jarvisBus` is
 * NOT visible — Swift registered the handler `in: JarvisBusWorld` and
 * WebKit isolates message handlers per content world. However,
 * `window.jarvisBus` is a property on the (cross-world-shared) `window`
 * object, so the bus instance installed by `Injection.js` inside
 * `JarvisBusWorld` IS observable from the default world.
 *
 * If we detect a pre-existing `window.jarvisBus` with the expected
 * `send` + `onOutbound` + `receive` shape, we attach our options to it
 * and return it verbatim rather than overwriting it. This routes every
 * outbound `send()` through the JarvisBusWorld-captured message handler
 * reference and keeps `onOutbound` hooked to the same `_handler` slot the
 * Injection.js bus exposes. Without this branch the default-world bundle
 * replaces `window.jarvisBus` with a bus whose `send()` cannot reach
 * `webkit.messageHandlers.jarvisBus` and every outbound frame — including
 * the first `uiReady` — is lost.
 *
 * bus-harness.html (Phase 2) loads its marker script in a page where
 * Injection.js has installed the same bus; the harness never called `send()`
 * so the regression wasn't observed until Phase 3. For that path this
 * function still returns the pre-installed bus, which is exactly what the
 * harness needs.
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

  // H-02: attach-to-existing path. Injection.js in JarvisBusWorld installs a
  // minimal bus with the same surface; if it's already on window we MUST NOT
  // replace it (that would orphan webkit.messageHandlers.jarvisBus, which is
  // only visible inside JarvisBusWorld).
  const existing: unknown =
    typeof window !== "undefined"
      ? (window as unknown as { jarvisBus?: unknown }).jarvisBus
      : undefined;
  if (isJarvisBusShape(existing)) {
    return () => {
      /* test cleanup — noop in production */
    };
  }

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

/**
 * Duck-type guard for a pre-existing `window.jarvisBus`. Matches the shape
 * installed by `packages/Bus/Sources/Bus/Resources/Injection.js` at
 * document-start in JarvisBusWorld. Intentionally narrow: if the shape
 * doesn't match (e.g. a left-over test stub), we fall through to the
 * fresh-install branch and overwrite it.
 */
function isJarvisBusShape(v: unknown): v is JarvisBus {
  if (typeof v !== "object" || v === null) return false;
  const b = v as Record<string, unknown>;
  return (
    typeof b.send === "function" &&
    typeof b.onOutbound === "function" &&
    typeof b.receive === "function"
  );
}
