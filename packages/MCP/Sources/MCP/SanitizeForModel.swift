// SanitizeForModel.swift
//
// SEC-07: byte-stream sanitize + head-truncate pipeline for the MCP boundary.
//
// THE PIPELINE ORDER IS FIXED. `prepareForBoundary` is the SOLE entry point:
//
//   sanitize → headTruncate
//
// followed (later, in AgentOrchestrator) by:
//
//   the SEC-06 wrap step (Plan 04-04)
//
// Why the order matters (RESEARCH §7, anti-pattern table):
//
//   - headTruncate BEFORE sanitize: the head bytes carry invalid UTF-8 / bidi
//     overrides forward into the model context.
//   - wrap BEFORE headTruncate: the truncation marker ends up wrapped
//     in nonce-gated tags, breaking the "every untrusted byte the model sees
//     is inside one envelope" invariant.
//
// THIS FILE OWNS sanitize + headTruncate. The wrap step lives in AgentCore;
// the orchestrator (Plan 04-04) calls it AFTER our dispatcher returns. DO NOT
// add a wrap call here — that would double-wrap and corrupt the per-turn
// nonce envelope.
//
// Plan: 05-04 Task 1

import Foundation

public enum SanitizeForModel {

    /// Per-line UTF-8 byte budget. Configurable upward later, but ROADMAP-
    /// prescribed at 4 KiB to keep individual lines from blowing up token
    /// budgets even when the total result is under the boundary cap.
    public static let perLineCapBytes: Int = 4096

    /// Step 1 — UTF-8 valid; strip C0 (except `\t`) + DEL; strip bidi
    /// overrides (U+202A..E) + isolates (U+2066..9); strip zero-width
    /// (U+200B..D, U+2060) + BOM (U+FEFF); cap each line at `perLineCapBytes`.
    ///
    /// The `\n` (U+000A) line separator is technically a C0 control. To
    /// preserve newline semantics we split on `\n` FIRST, scrub each line,
    /// then re-join with `\n`. This matches the canonical pattern in
    /// RESEARCH §4 and is the reason the C0 filter never sees an LF.
    public static func sanitize(_ input: String) -> String {
        let lines = input.split(separator: "\n", omittingEmptySubsequences: false)
        let cleaned: [String] = lines.map { line in
            // Scalar-range filter (faster + auditably explicit vs regex).
            let scalars = line.unicodeScalars.filter { scalar in
                let v = scalar.value
                if v == 0x09 { return true }                     // \t kept
                if v < 0x20 || v == 0x7F { return false }        // C0 + DEL dropped
                if (0x202A...0x202E).contains(v) { return false } // bidi override
                if (0x2066...0x2069).contains(v) { return false } // bidi isolate
                switch v {
                case 0x200B, 0x200C, 0x200D, 0x2060, 0xFEFF: return false // zero-width / BOM
                default: return true
                }
            }
            var s = String(String.UnicodeScalarView(scalars))
            if s.utf8.count > perLineCapBytes {
                // Trim by UTF-8 byte count, not character count, to honor the
                // byte budget. `String(decoding:as:)` handles a possibly-
                // truncated multibyte tail at the cap by replacing with U+FFFD.
                let prefixData = Data(s.utf8.prefix(perLineCapBytes))
                s = String(decoding: prefixData, as: UTF8.self) + "…[line-truncated]"
            }
            return s
        }
        return cleaned.joined(separator: "\n")
    }

    /// Step 2 — head-truncate by UTF-8 byte count. Default cap matches
    /// AGENT-08's `ToolResultPacker.modelFacingCapBytes` (8 KiB).
    ///
    /// Marker format is intentionally explicit so future contributors who see
    /// truncated tool output in a replay log can grep for it.
    public static func headTruncate(_ input: String, capBytes: Int = 8192) -> String {
        let utf8 = Data(input.utf8)
        guard utf8.count > capBytes else { return input }
        let head = utf8.prefix(capBytes)
        let headStr = String(decoding: head, as: UTF8.self)
        return headStr + "\n…[tool-result-truncated at \(capBytes) bytes]"
    }

    /// Canonical fixed-order pipeline composition.
    ///
    /// **THE ONLY entry point from MCPToolDispatcher.** Direct callers cannot
    /// accidentally reorder steps. Wrapping is intentionally absent — the
    /// orchestrator's nonce-gated wrap step runs AFTER this returns
    /// (see Plan 04-04 §dispatch loop).
    public static func prepareForBoundary(_ raw: String, capBytes: Int = 8192) -> String {
        let sanitized = sanitize(raw)
        return headTruncate(sanitized, capBytes: capBytes)
    }
}
