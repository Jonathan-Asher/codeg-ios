import Foundation

/// A model provider's refusal or error, recognized in the text an agent handed
/// back, so the transcript can show it as what it is (a compact "stopped: …"
/// state with the provider's own message under Details) instead of as a reply.
/// Mirrors codeg web's `src/lib/provider-errors.ts`.
///
/// Presentation only: nothing here changes, retries or hides what the provider
/// said, and ``raw`` keeps the text verbatim.
///
/// Claude Code turns a failed API request into the message `API Error:
/// <status> <the provider's message>` (or the provider's JSON error body). A
/// sub-agent that fails that way returns it as its Agent/Task result; the main
/// agent's own failure reaches the phone as the turn's error. Recognition is
/// narrow, because a false match would hide a real reply: the text must BE
/// the error (start with the prefix, optionally after a short "Error:"
/// lead-in, start with a policy block's own opening, or be a provider's JSON
/// error body) and be short. Prose that quotes one is left alone.
struct ProviderError: Equatable, Sendable {
    enum Kind: String, Equatable, Sendable {
        /// Blocked by the provider's usage policy or terms.
        case policyBlock
        case rateLimit
        case overloaded
        /// The provider refused the request as malformed or not allowed.
        case invalidRequest
        /// Any other provider/API failure.
        case apiError

        /// Why, as the end of a "… stopped: <reason>" line.
        var reason: String {
            switch self {
            case .policyBlock: return String(localized: "request blocked by the provider’s usage policy")
            case .rateLimit: return String(localized: "the provider’s rate limit was reached")
            case .overloaded: return String(localized: "the provider is overloaded")
            case .invalidRequest: return String(localized: "the provider rejected the request")
            case .apiError: return String(localized: "the provider returned an error")
            }
        }
    }

    let kind: Kind
    /// The text as received, trimmed, minus the agent-id / usage lines Claude
    /// Code appends to a sub-agent's result. Shown verbatim under Details.
    let raw: String
    /// The provider's own message: a JSON body's `error.message`, else the
    /// text after the client's `API Error: <status>` lead-in.
    let message: String
    /// The HTTP status the client reported, when it reported one.
    let status: Int?
    /// The first web link in the message: the provider's "learn more" page.
    let link: URL?

    /// Claude Code caps its API error text at 1000 characters; leave headroom.
    private static let maxPrefixedLength = 1500
    /// A provider's JSON error body (or a bare policy notice) is short too.
    private static let maxBareLength = 4000

    /// The provider error `text` is, or nil when it is anything else.
    static func detect(_ text: String?) -> ProviderError? {
        guard let text, !text.isEmpty, text.count <= maxBareLength * 2 else { return nil }
        let raw = stripTrailers(text)
        guard !raw.isEmpty, raw.count <= maxBareLength else { return nil }

        var body = raw
        if let inner = Pattern.toolUseError.captures(in: body)?.first ?? nil {
            body = inner.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        body = Pattern.leadIn.removingMatch(from: body)

        var status: Int?
        var rest: String
        let prefixed = Pattern.apiErrorPrefix.matches(body)
        if prefixed {
            guard raw.count <= maxPrefixedLength else { return nil }
            rest = Pattern.apiErrorPrefix.removingMatch(from: body)
            if let code = Pattern.statusPrefix.captures(in: rest)?.first ?? nil {
                status = Int(code)
                rest = Pattern.statusPrefix.removingMatch(from: rest)
            }
            rest = rest.trimmingCharacters(in: .whitespacesAndNewlines)
        } else if Pattern.barePolicyOpening.matches(body) {
            guard Pattern.policyBlock.matches(body) else { return nil }
            rest = body
        } else if Pattern.errorEnvelope.matches(body) {
            // Unprefixed, only a provider's error envelope counts: a JSON
            // result that merely has a `message` field is a result.
            rest = body
        } else {
            return nil
        }

        let errorBody = readErrorBody(rest)
        let extracted = (errorBody?.message ?? rest).trimmingCharacters(in: .whitespacesAndNewlines)
        let message = extracted.isEmpty ? raw : extracted
        return ProviderError(
            kind: kind(of: message, type: errorBody?.type, status: status),
            raw: raw,
            message: message,
            status: status,
            link: firstLink(in: message) ?? firstLink(in: raw)
        )
    }

    // MARK: - Parts

    private enum Pattern {
        static let leadIn = ErrorPattern(#"^(?:error|internal error|turn failed|prompt failed)\s*:\s*"#, caseInsensitive: true)
        static let apiErrorPrefix = ErrorPattern(#"^API Error\b[\s:–—-]*"#)
        static let statusPrefix = ErrorPattern(#"^(\d{3})\b[\s:–—-]*"#)
        static let barePolicyOpening = ErrorPattern(
            #"^(?:this request was blocked\b|(?:claude(?: code)? is )?unable to respond to this request, which appears to violate\b)"#,
            caseInsensitive: true)
        static let policyBlock = ErrorPattern(
            #"\b(?:blocked|violat\w*)\b[\s\S]{0,200}?\b(?:usage polic(?:y|ies)|terms of service|acceptable use|commercial terms)\b"#,
            caseInsensitive: true)
        static let errorEnvelope = ErrorPattern(#"^\{\s*"(?:type"\s*:\s*"error"|error"\s*:\s*\{)"#)
        static let link = ErrorPattern(#"https?://[^\s<>"'`)\]]+"#)
        static let usageTrailer = ErrorPattern(#"\s*<usage>[\s\S]*?</usage>\s*$"#)
        static let agentIDTrailer = ErrorPattern(#"(?:^|\n)\s*agentId:[^\n]*\s*$"#)
        static let toolUseError = ErrorPattern(#"^<tool_use_error>([\s\S]*?)</tool_use_error>$"#)
        static let rateLimitWords = ErrorPattern(#"\brate[ -]?limit|\brequest rejected \(429\)"#, caseInsensitive: true)
        static let overloadedWord = ErrorPattern(#"\boverloaded\b"#, caseInsensitive: true)
        static let bodyType = ErrorPattern(#""error"\s*:\s*\{\s*"type"\s*:\s*"([a-z_]+)""#)
        static let bodyMessage = ErrorPattern(#""message"\s*:\s*"((?:[^"\\]|\\.)*)"#)
    }

    /// The trailers Claude Code adds after a sub-agent's text.
    private static func stripTrailers(_ text: String) -> String {
        var out = text.trimmingCharacters(in: .whitespacesAndNewlines)
        for _ in 0..<3 {
            let next = Pattern.agentIDTrailer
                .removingMatch(from: Pattern.usageTrailer.removingMatch(from: out))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if next == out { break }
            out = next
        }
        return out
    }

    /// A provider JSON error body (`{"type":"error","error":{…}}`,
    /// `{"error":{…}}` or `{"message":…}`); a truncated one is read field by
    /// field. nil when it is no such body.
    private static func readErrorBody(_ text: String) -> (type: String?, message: String?)? {
        guard text.hasPrefix("{") else { return nil }
        if let data = text.data(using: .utf8),
           let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            let inner = root["error"] as? [String: Any] ?? root
            let type = inner["type"] as? String
            let message = inner["message"] as? String
            if type == nil, message == nil { return nil }
            return (type == "error" ? nil : type, message)
        }
        let type = Pattern.bodyType.captures(in: text)?.first ?? nil
        let quoted = Pattern.bodyMessage.captures(in: text)?.first ?? nil
        if type == nil, quoted == nil { return nil }
        var message = quoted
        if let quoted, let data = "\"\(quoted)\"".data(using: .utf8),
           let decoded = try? JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed) as? String {
            message = decoded
        }
        return (type, message)
    }

    private static func kind(of message: String, type: String?, status: Int?) -> Kind {
        if Pattern.policyBlock.matches(message) { return .policyBlock }
        switch type ?? "" {
        case "rate_limit_error": return .rateLimit
        case "overloaded_error": return .overloaded
        case "invalid_request_error", "request_too_large": return .invalidRequest
        default: break
        }
        if status == 429 { return .rateLimit }
        if status == 529 { return .overloaded }
        if Pattern.rateLimitWords.matches(message) { return .rateLimit }
        if Pattern.overloadedWord.matches(message) { return .overloaded }
        if status == 400 || status == 413 || status == 422 { return .invalidRequest }
        return .apiError
    }

    private static func firstLink(in text: String) -> URL? {
        guard let match = Pattern.link.firstMatch(in: text) else { return nil }
        var link = match
        while let last = link.last, ".,;:!?".contains(last) { link.removeLast() }
        return URL(string: link)
    }
}

/// A small `NSRegularExpression` wrapper for the patterns above.
private struct ErrorPattern {
    let expression: NSRegularExpression

    init(_ pattern: String, caseInsensitive: Bool = false) {
        // The patterns are literals checked by the tests; a typo is a crash
        // at first use in development, never a silent miss.
        expression = try! NSRegularExpression(
            pattern: pattern,
            options: caseInsensitive ? [.caseInsensitive] : []
        )
    }

    private func firstResult(in text: String) -> NSTextCheckingResult? {
        expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text))
    }

    func matches(_ text: String) -> Bool { firstResult(in: text) != nil }

    func firstMatch(in text: String) -> String? {
        guard let result = firstResult(in: text), let range = Range(result.range, in: text) else { return nil }
        return String(text[range])
    }

    /// The capture groups of the first match (nil for a group that took no
    /// part), or nil when nothing matches.
    func captures(in text: String) -> [String?]? {
        guard let result = firstResult(in: text) else { return nil }
        return (1..<max(result.numberOfRanges, 1)).map { index in
            Range(result.range(at: index), in: text).map { String(text[$0]) }
        }
    }

    /// `text` with the first match removed.
    func removingMatch(from text: String) -> String {
        guard let result = firstResult(in: text), let range = Range(result.range, in: text) else { return text }
        var out = text
        out.removeSubrange(range)
        return out
    }
}
