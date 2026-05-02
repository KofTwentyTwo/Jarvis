import { describe, it, expect } from "vitest";
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import {
  BUS_PROTOCOL_VERSION,
  decodeOutbound,
  decodeInbound,
  encodeOutbound,
  encodeInbound,
} from "../src/protocol.js";

const __dirname = dirname(fileURLToPath(import.meta.url));
const FIX = join(__dirname, "..", "fixtures");

function readFixture(name: string): { raw: string; parsed: unknown } {
  const raw = readFileSync(join(FIX, name), "utf-8");
  return { raw, parsed: JSON.parse(raw) };
}

describe("BUS_PROTOCOL_VERSION", () => {
  it("equals 2.3.0 (must match Swift constant — Plan 09-04 chatSubmit + chatCancelAndSubmit + submitRejected bump)", () => {
    expect(BUS_PROTOCOL_VERSION).toBe("2.3.0");
  });
});

describe("BusOutbound round-trip", () => {
  const outboundFixtures = [
    "hello.json",
    "hudState.idle.json",
    "hudState.listening.json",
    "hudState.thinking.json",
    "hudState.speaking.json",
    "hudState.awaitingConfirmation.json",
    "hudState.reconfiguring.json",
    "hudState.booting.json",
    "tokenDelta.json",
    "audioLevel.json",
    "toolCallStart.json",
    "toolCallEnd.json",
    "turnStarted.json",
    "turnEnded.json",
    "submitRejected.json",
  ];

  for (const name of outboundFixtures) {
    it(`decodes and re-encodes ${name}`, () => {
      const { raw, parsed } = readFixture(name);
      const result = decodeOutbound(raw);
      expect(result.ok, `decode failed: ${result.ok ? "" : result.error}`).toBe(true);
      if (!result.ok) return;
      const reEncoded = JSON.parse(encodeOutbound(result.value));
      expect(reEncoded).toEqual(parsed);
    });
  }
});

describe("BusInbound round-trip", () => {
  it("decodes and re-encodes helloAck.json", () => {
    const { raw, parsed } = readFixture("helloAck.json");
    const result = decodeInbound(raw);
    expect(result.ok).toBe(true);
    if (!result.ok) return;
    expect(JSON.parse(encodeInbound(result.value))).toEqual(parsed);
  });

  it("decodes and re-encodes frameAttachRequested.json (Plan 09-02 / D-15)", () => {
    const { raw, parsed } = readFixture("frameAttachRequested.json");
    const result = decodeInbound(raw);
    expect(result.ok).toBe(true);
    if (!result.ok) return;
    expect(JSON.parse(encodeInbound(result.value))).toEqual(parsed);
  });

  it("decodes and re-encodes chatSubmit.json (Plan 09-04 / D-12)", () => {
    const { raw, parsed } = readFixture("chatSubmit.json");
    const result = decodeInbound(raw);
    expect(result.ok).toBe(true);
    if (!result.ok) return;
    expect(JSON.parse(encodeInbound(result.value))).toEqual(parsed);
  });

  it("decodes and re-encodes chatCancelAndSubmit.json (Plan 09-04 / D-12)", () => {
    const { raw, parsed } = readFixture("chatCancelAndSubmit.json");
    const result = decodeInbound(raw);
    expect(result.ok).toBe(true);
    if (!result.ok) return;
    expect(JSON.parse(encodeInbound(result.value))).toEqual(parsed);
  });
});

describe("decodeOutbound error paths", () => {
  it("returns ok:false on unknown type", () => {
    const r = decodeOutbound(`{"type":"unknown"}`);
    expect(r.ok).toBe(false);
    if (!r.ok) expect(r.error).toContain("unknown type");
  });

  it("returns ok:false on malformed JSON", () => {
    const r = decodeOutbound(`{not json`);
    expect(r.ok).toBe(false);
    if (!r.ok) expect(r.error).toContain("parse error");
  });

  it("returns ok:false on missing discriminator", () => {
    const r = decodeOutbound(`{"version":"2.0.0"}`);
    expect(r.ok).toBe(false);
    if (!r.ok) expect(r.error).toContain("missing discriminator");
  });

  it("returns ok:false on invalid hudState", () => {
    const r = decodeOutbound(`{"type":"hudState","state":"garbage"}`);
    expect(r.ok).toBe(false);
  });

  it("returns ok:false on non-object payload", () => {
    const r = decodeOutbound(`"just a string"`);
    expect(r.ok).toBe(false);
  });
});
