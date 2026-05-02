/**
 * @jarvis/bus protocol — TS mirror of packages/Bus/Sources/Bus/Protocol.swift.
 *
 * Source of truth: this file's BUS_PROTOCOL_VERSION and the Swift side's
 * constant must be byte-identical. Plan 04 adds a build-time parity check.
 *
 * Plan 07-03 bumped Swift 2.0.0 -> 2.1.0 (additive sessionHistory case);
 * Plan 07-06 mirrored that bump here.
 *
 * Plan 09-02 bumped 2.1.0 -> 2.2.0 (additive BusInbound case
 * frameAttachRequested for the HUD camera-icon button → FrameAttachController).
 *
 * Plan 09-04 bumped 2.2.0 -> 2.3.0 (additive BusInbound cases chatSubmit +
 * chatCancelAndSubmit for chat-panel submit + barge-in; additive BusOutbound
 * case submitRejected for D-10 text-path rejection toast).
 */

export const BUS_PROTOCOL_VERSION = "2.3.0";

export type HudState =
  | "idle"
  | "listening"
  | "thinking"
  | "speaking"
  | "awaitingConfirmation"
  | "reconfiguring"
  | "booting";

export type TurnTerminator =
  | "completed"
  | "cancelled"
  | "errored"
  | "superseded";

/**
 * Local mirror of `Memory.TurnRow` (the backend Swift type) and
 * `Bus.TurnRow` (the Swift bus mirror). Bus deliberately does NOT depend on
 * the Memory package — this duplicated shape preserves the lightweight
 * bridge layer. AppDelegate.installMemory translates between
 * `Memory.TurnRow` and `Bus.TurnRow` when emitting `sessionHistory`.
 */
export interface TurnRow {
  id: number;
  sessionId: string;
  role: string; // "user" | "assistant" | "tool"
  content: string;
  source: string; // TurnSource rawValue
  createdAt: number; // unix-ms
}

export type BusOutbound =
  | { type: "hello"; version: string }
  | { type: "hudState"; state: HudState }
  | { type: "tokenDelta"; text: string }
  | { type: "audioLevel"; rms: number }
  | { type: "toolCallStart"; id: string; name: string; argsPreview: string }
  | { type: "toolCallEnd"; id: string; ok: boolean; previewOrError: string }
  | { type: "turnStarted"; id: string }
  | { type: "turnEnded"; id: string; terminator: TurnTerminator }
  | { type: "sessionHistory"; turns: TurnRow[] }
  /**
   * Plan 09-04 / D-10 — emitted when AgentOrchestrator.submit(.text(...))
   * returns SubmitOutcome.rejected. The chat panel renders this as a
   * transient toast. Body string is byte-identical to the voice-path HUD
   * banner (single source of truth: RejectReasonCopy.swift).
   */
  | { type: "submitRejected"; reason: string };

export type BusInbound =
  | { type: "helloAck"; version: string }
  | { type: "uiReady" }
  /**
   * Plan 09-02 / D-15 / VIS-07. The HUD's camera-icon button posts this when
   * the user clicks it; AppDelegate routes it to
   * FrameAttachController.requestAttach(reason: .hudButton).
   */
  | { type: "frameAttachRequested" }
  /**
   * Plan 09-04 / D-12 — chat-panel "Send" button. AppDelegate routes this
   * to AgentOrchestrator.submit(.text(text)).
   */
  | { type: "chatSubmit"; text: string }
  /**
   * Plan 09-04 / D-12 — chat-panel barge-in. AppDelegate routes this to
   * AgentOrchestrator.cancelAndSubmit(.text(text)).
   */
  | { type: "chatCancelAndSubmit"; text: string };

export type DecodeResult<T> =
  | { ok: true; value: T }
  | { ok: false; error: string };

function isObject(v: unknown): v is Record<string, unknown> {
  return typeof v === "object" && v !== null && !Array.isArray(v);
}

// Type-guard arrays: `satisfies readonly HudState[]` forces us to update the
// array when the union expands. The cast to `readonly string[]` in the body of
// isHudState/isTurnTerminator is the one unsafe-feeling line, but it's bounded
// by the `satisfies` clause above.
const HUD_STATES = [
  "idle",
  "listening",
  "thinking",
  "speaking",
  "awaitingConfirmation",
  "reconfiguring",
  "booting",
] as const satisfies readonly HudState[];

const TURN_TERMINATORS = [
  "completed",
  "cancelled",
  "errored",
  "superseded",
] as const satisfies readonly TurnTerminator[];

function isHudState(v: string): v is HudState {
  return (HUD_STATES as readonly string[]).includes(v);
}

function isTurnTerminator(v: string): v is TurnTerminator {
  return (TURN_TERMINATORS as readonly string[]).includes(v);
}

/**
 * Decode a BusOutbound JSON string. Never throws: malformed input returns
 * `{ok: false, error}`. The default branch hits a `const _exhaustive: never`
 * assignment — adding a new discriminator to BusOutbound without extending
 * this switch fails `tsc --strict` at compile time.
 */
export function decodeOutbound(json: string): DecodeResult<BusOutbound> {
  let parsed: unknown;
  try {
    parsed = JSON.parse(json);
  } catch (e) {
    return { ok: false, error: `parse error: ${String(e)}` };
  }
  if (!isObject(parsed)) return { ok: false, error: "payload is not an object" };
  if (typeof parsed.type !== "string") return { ok: false, error: "missing discriminator" };

  // Narrow by discriminator. Every arm of BusOutbound has a case; the default
  // branch's `never` sentinel is the compile-time exhaustiveness check.
  // `type` is typed as the discriminator union itself — adding a new variant
  // widens this union, and the default branch's `never` assignment fails tsc.
  const type: BusOutbound["type"] = parsed.type as BusOutbound["type"];
  switch (type) {
    case "hello":
      if (typeof parsed.version !== "string") return { ok: false, error: "hello: version must be string" };
      return { ok: true, value: { type: "hello", version: parsed.version } };
    case "hudState":
      if (typeof parsed.state !== "string") return { ok: false, error: "hudState: state must be string" };
      if (!isHudState(parsed.state)) return { ok: false, error: `hudState: unknown state '${parsed.state}'` };
      return { ok: true, value: { type: "hudState", state: parsed.state } };
    case "tokenDelta":
      if (typeof parsed.text !== "string") return { ok: false, error: "tokenDelta: text must be string" };
      return { ok: true, value: { type: "tokenDelta", text: parsed.text } };
    case "audioLevel":
      if (typeof parsed.rms !== "number") return { ok: false, error: "audioLevel: rms must be number" };
      return { ok: true, value: { type: "audioLevel", rms: parsed.rms } };
    case "toolCallStart":
      if (
        typeof parsed.id !== "string" ||
        typeof parsed.name !== "string" ||
        typeof parsed.argsPreview !== "string"
      ) {
        return { ok: false, error: "toolCallStart: invalid fields" };
      }
      return {
        ok: true,
        value: {
          type: "toolCallStart",
          id: parsed.id,
          name: parsed.name,
          argsPreview: parsed.argsPreview,
        },
      };
    case "toolCallEnd":
      if (
        typeof parsed.id !== "string" ||
        typeof parsed.ok !== "boolean" ||
        typeof parsed.previewOrError !== "string"
      ) {
        return { ok: false, error: "toolCallEnd: invalid fields" };
      }
      return {
        ok: true,
        value: {
          type: "toolCallEnd",
          id: parsed.id,
          ok: parsed.ok,
          previewOrError: parsed.previewOrError,
        },
      };
    case "turnStarted":
      if (typeof parsed.id !== "string") return { ok: false, error: "turnStarted: id must be string" };
      return { ok: true, value: { type: "turnStarted", id: parsed.id } };
    case "turnEnded":
      if (typeof parsed.id !== "string" || typeof parsed.terminator !== "string") {
        return { ok: false, error: "turnEnded: invalid fields" };
      }
      if (!isTurnTerminator(parsed.terminator)) {
        return { ok: false, error: `turnEnded: unknown terminator '${parsed.terminator}'` };
      }
      return {
        ok: true,
        value: { type: "turnEnded", id: parsed.id, terminator: parsed.terminator },
      };
    case "sessionHistory": {
      if (!Array.isArray(parsed.turns)) {
        return { ok: false, error: "sessionHistory: turns must be array" };
      }
      const decodedTurns: TurnRow[] = [];
      for (const t of parsed.turns) {
        if (!isObject(t)) return { ok: false, error: "sessionHistory: turn entry not an object" };
        if (
          typeof t.id !== "number" ||
          typeof t.sessionId !== "string" ||
          typeof t.role !== "string" ||
          typeof t.content !== "string" ||
          typeof t.source !== "string" ||
          typeof t.createdAt !== "number"
        ) {
          return { ok: false, error: "sessionHistory: invalid turn fields" };
        }
        decodedTurns.push({
          id: t.id,
          sessionId: t.sessionId,
          role: t.role,
          content: t.content,
          source: t.source,
          createdAt: t.createdAt,
        });
      }
      return { ok: true, value: { type: "sessionHistory", turns: decodedTurns } };
    }
    case "submitRejected":
      if (typeof parsed.reason !== "string") return { ok: false, error: "submitRejected: reason must be string" };
      return { ok: true, value: { type: "submitRejected", reason: parsed.reason } };
    default: {
      // Compile-time exhaustiveness. After all cases above narrow `type`, the
      // default branch should see `type: never`. Adding a new BusOutbound
      // variant without a case above leaves a non-never residual here, and
      // `const _exhaustive: never = type;` fails tsc. NO `as never` cast —
      // that would defeat the check.
      const _exhaustive: never = type;
      void _exhaustive;
      return { ok: false, error: `unknown type: ${String(parsed.type)}` };
    }
  }
}

/**
 * Decode a BusInbound JSON string. Same contract as decodeOutbound.
 */
export function decodeInbound(json: string): DecodeResult<BusInbound> {
  let parsed: unknown;
  try {
    parsed = JSON.parse(json);
  } catch (e) {
    return { ok: false, error: `parse error: ${String(e)}` };
  }
  if (!isObject(parsed)) return { ok: false, error: "payload is not an object" };
  if (typeof parsed.type !== "string") return { ok: false, error: "missing discriminator" };

  const type: BusInbound["type"] = parsed.type as BusInbound["type"];
  switch (type) {
    case "helloAck":
      if (typeof parsed.version !== "string") return { ok: false, error: "helloAck: version must be string" };
      return { ok: true, value: { type: "helloAck", version: parsed.version } };
    case "uiReady":
      return { ok: true, value: { type: "uiReady" } };
    case "frameAttachRequested":
      // Plan 09-02 / D-15 — no payload fields; the case alone is the signal.
      return { ok: true, value: { type: "frameAttachRequested" } };
    case "chatSubmit":
      if (typeof parsed.text !== "string") return { ok: false, error: "chatSubmit: text must be string" };
      return { ok: true, value: { type: "chatSubmit", text: parsed.text } };
    case "chatCancelAndSubmit":
      if (typeof parsed.text !== "string") return { ok: false, error: "chatCancelAndSubmit: text must be string" };
      return { ok: true, value: { type: "chatCancelAndSubmit", text: parsed.text } };
    default: {
      const _exhaustive: never = type;
      void _exhaustive;
      return { ok: false, error: `unknown type: ${String(parsed.type)}` };
    }
  }
}

export function encodeOutbound(msg: BusOutbound): string {
  return JSON.stringify(msg);
}

export function encodeInbound(msg: BusInbound): string {
  return JSON.stringify(msg);
}
