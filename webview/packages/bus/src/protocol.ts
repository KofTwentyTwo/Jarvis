// RED-phase stub. Real implementation lands in the GREEN commit.
// All exports are typed to satisfy the public API contract; decoders
// return {ok: false} so every round-trip test fails until implementation lands.

export const BUS_PROTOCOL_VERSION = "0.0.0-stub";

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

export type BusOutbound =
  | { type: "hello"; version: string }
  | { type: "hudState"; state: HudState }
  | { type: "tokenDelta"; text: string }
  | { type: "audioLevel"; rms: number }
  | { type: "toolCallStart"; id: string; name: string; argsPreview: string }
  | { type: "toolCallEnd"; id: string; ok: boolean; previewOrError: string }
  | { type: "turnStarted"; id: string }
  | { type: "turnEnded"; id: string; terminator: TurnTerminator };

export type BusInbound =
  | { type: "helloAck"; version: string }
  | { type: "uiReady" };

export type DecodeResult<T> =
  | { ok: true; value: T }
  | { ok: false; error: string };

export function decodeOutbound(_json: string): DecodeResult<BusOutbound> {
  return { ok: false, error: "stub" };
}

export function decodeInbound(_json: string): DecodeResult<BusInbound> {
  return { ok: false, error: "stub" };
}

export function encodeOutbound(msg: BusOutbound): string {
  return JSON.stringify(msg);
}

export function encodeInbound(msg: BusInbound): string {
  return JSON.stringify(msg);
}
