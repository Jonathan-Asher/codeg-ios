import Foundation

/// Role of a rendered turn (Rust `TurnRole`).
enum TurnRole: String, Codable, Hashable, Sendable {
    case user
    case assistant
    case system

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = TurnRole(rawValue: raw) ?? .system
    }
}

/// Token usage for a single turn (Rust `TurnUsage`). All fields present on wire.
struct TurnUsage: Codable, Hashable, Sendable {
    let inputTokens: Int
    let outputTokens: Int
    let cacheCreationInputTokens: Int
    let cacheReadInputTokens: Int

    var total: Int { inputTokens + outputTokens + cacheCreationInputTokens + cacheReadInputTokens }
}

/// Inline image payload (Rust `ImageData`).
struct ImageData: Codable, Hashable, Sendable {
    let data: String
    let mimeType: String
    let uri: String?
    /// Where the server serves the real image when a live frame could not carry
    /// it inline (`/api/live_image/<key>`, relative to the server). `data` is
    /// then a small placeholder picture.
    var dataRef: String? = nil
}

extension ImageData {
    /// Decode a list of images under `key`, skipping any that are malformed
    /// (and treating a missing or null list as empty) instead of failing the
    /// value that holds them — one bad image must not cost a whole transcript.
    static func lenientList<K: CodingKey>(_ c: KeyedDecodingContainer<K>, forKey key: K) -> [ImageData] {
        guard c.contains(key), (try? c.decodeNil(forKey: key)) == false,
              var list = try? c.nestedUnkeyedContainer(forKey: key) else { return [] }
        /// Always decodes, so a bad element is stepped over rather than retried.
        struct Skip: Decodable { init(from decoder: Decoder) {} }
        var out: [ImageData] = []
        while !list.isAtEnd {
            if let image = try? list.decode(ImageData.self) {
                out.append(image)
            } else if (try? list.decode(Skip.self)) == nil {
                break
            }
        }
        return out
    }
}

/// A polymorphic block of message content (Rust `ContentBlock`, internally
/// tagged by `type` with snake_case variant names). Decode-only: the server is
/// the source of truth for transcripts; locally-constructed optimistic turns
/// build cases directly. Unknown future variants decode to `.unknown` instead
/// of throwing.
enum ContentBlock: Hashable, Sendable, Decodable {
    case text(String)
    case thinking(String)
    case image(ImageData)
    case imageGeneration(revisedPrompt: String?, image: ImageData?)
    case toolUse(id: String?, name: String, inputPreview: String?, meta: AnyJSON?)
    /// `images`: what the tool returned as pictures — a Read of a PNG, a
    /// screenshot — shown after the tool's card.
    case toolResult(id: String?, outputPreview: String?, isError: Bool, images: [ImageData] = [])
    case unknown(type: String)

    private enum CodingKeys: String, CodingKey {
        // NOTE: the decoder uses `.convertFromSnakeCase`, so wire keys arrive
        // here already camelCased — match them in camelCase.
        case type, text, data, mimeType, uri, dataRef, revisedPrompt, image
        case toolUseId, toolName, inputPreview, meta
        case outputPreview, isError, images
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let type = try c.decode(String.self, forKey: .type)
        switch type {
        case "text":
            self = .text(try c.decodeIfPresent(String.self, forKey: .text) ?? "")
        case "thinking":
            self = .thinking(try c.decodeIfPresent(String.self, forKey: .text) ?? "")
        case "image":
            self = .image(ImageData(
                data: try c.decodeIfPresent(String.self, forKey: .data) ?? "",
                mimeType: try c.decodeIfPresent(String.self, forKey: .mimeType) ?? "image/png",
                uri: try c.decodeIfPresent(String.self, forKey: .uri),
                dataRef: try c.decodeIfPresent(String.self, forKey: .dataRef)
            ))
        case "image_generation":
            self = .imageGeneration(
                revisedPrompt: try c.decodeIfPresent(String.self, forKey: .revisedPrompt),
                image: try c.decodeIfPresent(ImageData.self, forKey: .image)
            )
        case "tool_use":
            self = .toolUse(
                id: try c.decodeIfPresent(String.self, forKey: .toolUseId),
                name: try c.decodeIfPresent(String.self, forKey: .toolName) ?? "tool",
                inputPreview: try c.decodeIfPresent(String.self, forKey: .inputPreview),
                // `meta["codeg.delegation"]` carries the delegate card's authoritative
                // terminal status; nil for tool uses without any meta.
                meta: try c.decodeIfPresent(AnyJSON.self, forKey: .meta)
            )
        case "tool_result":
            self = .toolResult(
                id: try c.decodeIfPresent(String.self, forKey: .toolUseId),
                outputPreview: try c.decodeIfPresent(String.self, forKey: .outputPreview),
                isError: try c.decodeIfPresent(Bool.self, forKey: .isError) ?? false,
                // Lenient: a malformed image must not fail the whole transcript.
                images: ImageData.lenientList(c, forKey: .images)
            )
        default:
            self = .unknown(type: type)
        }
    }
}

/// One turn in a conversation transcript (Rust `MessageTurn`).
struct MessageTurn: Identifiable, Hashable, Sendable, Decodable {
    let id: String
    let role: TurnRole
    let blocks: [ContentBlock]
    let timestamp: Date
    let usage: TurnUsage?
    let durationMs: Int?
    let model: String?
    let completedAt: Date?

    init(
        id: String,
        role: TurnRole,
        blocks: [ContentBlock],
        timestamp: Date,
        usage: TurnUsage? = nil,
        durationMs: Int? = nil,
        model: String? = nil,
        completedAt: Date? = nil
    ) {
        self.id = id
        self.role = role
        self.blocks = blocks
        self.timestamp = timestamp
        self.usage = usage
        self.durationMs = durationMs
        self.model = model
        self.completedAt = completedAt
    }
}
