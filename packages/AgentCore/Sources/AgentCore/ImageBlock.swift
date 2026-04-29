import Foundation

/// Canonical frame representation across the LLM provider surface.
///
/// Plan 07-05 / D-18: a transport-format-agnostic value type carried by
/// `LLMProvider.stream(messages:images:...)`, `TurnInput.images`, and
/// `VisionRouter`. Each provider encodes the bytes per its API:
///   - `AnthropicProvider` → base64 inside `image_block` (Anthropic Vision API)
///   - `OllamaProvider`    → data-URL inside `image_url` (OpenAI-compat shape)
///
/// Privacy invariant (D-15): an `ImageBlock` lives only in process memory
/// for the duration of a single user-initiated turn. `FrameAttachController`
/// is the SOLE call site that releases the bytes (`discardFrame()` on the
/// assistant-turn-complete edge). The replay log NEVER persists the raw bytes
/// — only a `{"type":"image","discarded":true,...}` placeholder.
public struct ImageBlock: Sendable, Equatable {
    /// IANA media type — e.g. `image/jpeg`, `image/png`. Each provider's
    /// encoder reads this verbatim into its wire-format media-type field.
    public let mediaType: String

    /// Raw image bytes. Each provider base64-encodes (or data-URL-encodes)
    /// this on the wire; the bytes themselves never reach disk.
    public let data: Data

    public init(mediaType: String, data: Data) {
        self.mediaType = mediaType
        self.data = data
    }
}
