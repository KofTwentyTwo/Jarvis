import Foundation

/// mem0 prompts (RESEARCH §5). This file is the ONLY producer of the
/// extractor's system + user prompts.
///
/// D-03 scope: durable personal facts only — preferences, relationships,
/// decisions, project state, recurring patterns. NOT trivia, ephemeral
/// state, or question content.
public enum MemoryPrompts {

    /// RESEARCH §5 system prompt template.
    ///
    /// Pre-loads up to ~4 KB of prior active facts so the model can choose
    /// UPDATE over ADD when it sees a contradiction. Caller is responsible
    /// for FTS5-shortlisting the priors (RESEARCH §5: top-K active facts
    /// for matched subjects).
    public static func mem0System(priorFacts: [Fact]) -> String {
        let priorBlock = renderPriorFacts(priorFacts)
        return """
        You are a memory extractor.

        Given a conversation turn, return operations:
        - ADD: a new durable fact worth remembering long-term.
        - UPDATE: an existing fact has changed; supersede it.
        - NOOP: no memory change is needed.

        Only durable personal facts:
        - preferences (e.g., "user prefers dark mode")
        - relationships (e.g., "Sarah is the user's manager")
        - decisions (e.g., "we decided to use Postgres")
        - project state (e.g., "the auth module is now in beta")
        - recurring patterns (e.g., "user usually works mornings")

        Exclude:
        - trivia (jokes, small talk, weather)
        - ephemeral state (current cursor position, what's on screen right now)
        - question content (the user asking "what time is it?" is NOT a fact)

        For UPDATE, set supersedes_fact_id to the prior fact's integer ID
        from the priors list below.

        \(priorBlock)

        Respond ONLY by calling the apply_memory_ops tool. Do not respond in
        free-form text. If nothing should be remembered, return a single
        NOOP entry.
        """
    }

    /// Per-turn user prompt — formats the user/assistant pair the extractor
    /// is summarizing into facts.
    public static func format(user: String, assistant: String) -> String {
        return """
        Conversation turn:

        USER: \(user)

        ASSISTANT: \(assistant)
        """
    }

    /// Render up to ~4 KB of prior active facts (RESEARCH §5 cap). Each
    /// fact is one line: `[id] subject — predicate — object`.
    private static func renderPriorFacts(_ facts: [Fact]) -> String {
        guard !facts.isEmpty else {
            return "Prior active facts: (none)"
        }
        let header = "Prior active facts (use these IDs for UPDATE):\n"
        let cap = 4096
        var body = ""
        for f in facts {
            let line = "[\(f.id)] \(f.subject) — \(f.predicate) — \(f.object)\n"
            if body.utf8.count + line.utf8.count > cap { break }
            body += line
        }
        return header + body
    }
}
