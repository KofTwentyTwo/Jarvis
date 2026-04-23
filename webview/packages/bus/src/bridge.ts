// RED-phase stub. GREEN phase replaces this with the real installJarvisBus.

import type { BusInbound, BusOutbound } from "./protocol.js";

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
  receive(payload: string): void;
  send(msg: BusInbound): Promise<unknown>;
  onOutbound(handler: OutboundHandler): void;
  readonly protocolVersion: string;
}

export interface InstallOptions {
  onDecodeError?: DecodeErrorHandler;
}

export function installJarvisBus(_options: InstallOptions = {}): () => void {
  // Stub — tests expect this to fail until GREEN fills it in.
  return () => {};
}
