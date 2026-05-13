import Foundation

/// Composes the LLM system prompt for one turn.
///
/// Plan 10-02 (SELF-05 / SELF-06) introduces a locked self-aware preamble
/// that replaces the hardcoded `"You are Jarvis, a personal macOS
/// assistant."` literal previously sourced at `App/AppDelegate.swift:1242`.
///
/// **Invariants** (do not relax without re-spec):
/// - **D-12**: preamble is emitted FIRST, then per-turn enrichments
///   (presence, memory hydration). Two distinct concatenation steps —
///   preserves Anthropic `cache_control` boundaries (Pitfall #4).
/// - **D-13**: preamble is a single locked Swift string constant. No JSON
///   file, no localization, no runtime mutation.
/// - **D-14**: preamble does NOT enumerate the tool catalog as a Markdown
///   block. The Anthropic API tools array is the authoritative catalog;
///   the preamble nudges the model to call introspection tools by name so
///   it has handles, but does not duplicate schemas.
/// - **T-10-CACHE-01 / Pitfall #4 / Assumption A4**: preamble length stays
///   below the 4096-char Anthropic cache-eligibility boundary so it does
///   not unintentionally flip `cache_control` marker emission.
///   `CacheHintsEligibilityTests/preambleDoesNotEnableCacheUnintentionally`
///   is the regression guard.
public struct ContextBuilder: Sendable {
    public init() {}
}

/// Per-turn context envelope that the system-prompt composer accepts.
///
/// Plan 10-02 introduces this as a minimal value type because the existing
/// `AgentOrchestrator` init takes `systemPrompt: String` directly — plumbing
/// a per-turn context through orchestrator init is out of scope per D-12
/// fallback. AppDelegate today calls `ContextBuilder.systemPrompt(for: .empty)`,
/// which yields the preamble alone; presence/memory enrichments continue to
/// flow through the orchestrator's existing per-turn paths
/// (`PresenceStateSnapshot.shared`, etc.).
public struct TurnContext: Sendable {
    /// Optional presence enrichment text (vision/awareness fragment).
    public let presenceText: String?
    /// Optional memory hydration text (recalled facts for the turn).
    public let memoryHydration: String?

    public init(presenceText: String? = nil, memoryHydration: String? = nil) {
        self.presenceText = presenceText
        self.memoryHydration = memoryHydration
    }

    /// Empty context — preamble alone, no per-turn enrichment.
    public static let empty = TurnContext()
}

extension ContextBuilder {
    /// Locked self-aware preamble — D-13 single string constant.
    ///
    /// Total length: well under 2 KB, deliberately below the 4096-char
    /// cache-eligibility boundary so introducing the preamble does not flip
    /// `cache_control` emission relative to the prior 10-token literal
    /// (Pitfall #4 / T-10-CACHE-01).
    ///
    /// Names the four self-knowledge MCP tools (registered in Plan 10-01)
    /// plus the three starter tools so the model has handles to prefer
    /// over generic "open System Settings" answers (D-14 — names only,
    /// no schemas).
    public static let selfAwarePreamble: String = """
    You are Jarvis, an always-on macOS assistant running as a Swift app on \
    the user's Mac. You have voice input via the user's microphone, voice \
    output via the user's speakers, and a camera you can use to see when \
    asked. You expose a set of MCP tools for introspection — always prefer \
    calling those tools (list_audio_devices, get_active_audio_route, \
    get_self_state, list_camera_devices, get_time, get_clipboard, \
    run_applescript) over giving the user generic instructions like \
    "open System Settings" or "I don't have access to your hardware." \
    You are not a text-only assistant. \
    You also have a long-term memory store. When the user references \
    something they may have told you before, or asks "do you remember…", \
    call search_memory FIRST. Never claim to remember without searching. \
    Use forget_fact when the user explicitly asks to forget something.
    """

    /// Compose the full system prompt for one turn.
    ///
    /// Order (D-12): preamble FIRST, then presence enrichment (if any),
    /// then memory hydration (if any). Two distinct concatenation steps —
    /// do not collapse into a single template; the boundary preserves
    /// Anthropic prompt-cache breakpoints when callers later thread a
    /// per-turn `TurnContext` through.
    public static func systemPrompt(for turn: TurnContext) -> String {
        var s = selfAwarePreamble
        if let presence = turn.presenceText {
            s += "\n\n" + presence
        }
        if let memory = turn.memoryHydration {
            s += "\n\n" + memory
        }
        return s
    }
}
