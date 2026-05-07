// ProviderOverrides.swift
//
// G-004 LOCKED: external-service stubbing at the API boundary. JarvisHost.boot
// accepts a ProviderOverrides bundle; production passes nil → real providers;
// harness passes mocks for deterministic LLM / embedder / extractor / TTS / STT.
//
// The MockLLMProvider URL-protocol path from packages/Harness becomes the default
// for harness scenarios. CapturingSTTProvider, MockTTSForController, and the
// existing test doubles in packages/Voice/Tests are rehoused as harness-public
// types here.
//
// See JARVIS-API-TEST-CONTRACT.md §7.2 "Nondeterministic surfaces" and v0.2 §2.1 G-004.

import Foundation

/// Bundle of provider doubles passed at JarvisHost boot.
/// Each field is optional; nil → production provider for that role.
public struct ProviderOverrides: Sendable {
    /// Anthropic Messages-API provider double (cloud LLM).
    /// Default: `MockLLMProvider(fixtureURL:)` for harness; nil for production.
    public var anthropic: AnyLLMProvider?

    /// Ollama LLM provider double (local model).
    public var ollama: AnyLLMProvider?

    /// Embedding provider double (nomic-embed-text replacement).
    public var ollamaEmbedder: AnyEmbeddingProvider?

    /// Memory extractor double (Qwen 2.5-Coder ADD/UPDATE/NOOP).
    /// Test scenarios use `StubMemoryExtractor(map:)` mapping turn text → ops.
    public var memoryExtractor: AnyMemoryExtractor?

    /// TTS engine double — captures synthesis records without producing audio.
    /// Used by V-005, X-003, B-05 fix.
    public var tts: AnyTTSEngine?

    /// STT provider double — pairs with `_injectSTT` test seam.
    public var stt: AnySTTProvider?

    /// Anthropic API-key validator double — used by S-006 / S-007.
    public var keyValidator: AnyKeyValidator?

    public init(
        anthropic: AnyLLMProvider? = nil,
        ollama: AnyLLMProvider? = nil,
        ollamaEmbedder: AnyEmbeddingProvider? = nil,
        memoryExtractor: AnyMemoryExtractor? = nil,
        tts: AnyTTSEngine? = nil,
        stt: AnySTTProvider? = nil,
        keyValidator: AnyKeyValidator? = nil
    ) {
        self.anthropic = anthropic
        self.ollama = ollama
        self.ollamaEmbedder = ollamaEmbedder
        self.memoryExtractor = memoryExtractor
        self.tts = tts
        self.stt = stt
        self.keyValidator = keyValidator
    }

    /// Default harness override set: deterministic doubles for every collaborator.
    public static func deterministicDefaults() -> ProviderOverrides {
        // IMPL: wire MockLLMProvider, StubEmbedder, StubMemoryExtractor, FakeTTS,
        //       FakeSTT, StubKeyValidator with predictable canned responses.
        fatalError("not implemented — IMPL: ProviderOverrides.deterministicDefaults (M-0)")
    }
}

// MARK: - Type-erased provider boxes
//
// These are placeholders until packages/JarvisAPI defines the real protocols.
// Once JarvisAPI lands (M-0 step 1) these become typealiases or `any LLMProvider`
// existentials referencing the canonical protocols there.

public struct AnyLLMProvider: Sendable {
    public init() {
        // IMPL: hold an `any LLMProvider` from JarvisAPI once it exists
    }
}

public struct AnyEmbeddingProvider: Sendable {
    public init() {}
}

public struct AnyMemoryExtractor: Sendable {
    public init() {}
}

public struct AnyTTSEngine: Sendable {
    public init() {}
}

public struct AnySTTProvider: Sendable {
    public init() {}
}

public struct AnyKeyValidator: Sendable {
    public init() {}
}
