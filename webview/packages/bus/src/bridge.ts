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
 * ## Defensive double-install guard (H-02)
 *
 * Both `Injection.js` (a `WKUserScript` injected at `.atDocumentStart`) and
 * this bundle's `installJarvisBus()` run in the SAME page world — the
 * default `WKContentWorld.page` since `fb41c5f` retired the prior
 * isolated named world. Injection.js fires first and stamps a
 * minimal `window.jarvisBus` with `protocolVersion`, `_handler`, plus the
 * `send` / `receive` / `onOutbound` surface needed for the handshake.
 * The bundle's installer fires later (top-level side-effect of `main.tsx`),
 * and if we naively overwrote `window.jarvisBus` we would orphan
 * Injection.js's queued early messages and any handshake state already
 * captured against the original closure.
 *
 * The shape check below (`isJarvisBusShape`) is therefore a defensive
 * double-install guard inside one page world, not a cross-world attach.
 * When we detect a pre-existing `window.jarvisBus` with the canonical
 * `send` + `onOutbound` + `receive` surface, we return early and leave
 * Injection.js's instance in place. Outbound `send()` calls still reach
 * `window.webkit.messageHandlers.jarvisBus` because that handler lives on
 * the same page world too.
 *
 * `bus-harness.html` (Phase 2) loads its marker script in a page where
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

  // H-02: defensive double-install guard. Injection.js runs first (at
  // document-start in the same page world) and stamps a minimal bus with the
  // same surface; if it's already on `window`, we MUST NOT replace it — doing
  // so would orphan Injection.js's queued early messages and captured handshake
  // state. See the class doc above for the full rationale.
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
 * document-start in the page world. Intentionally narrow: if the shape
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
