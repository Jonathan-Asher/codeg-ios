import Foundation

/// Context-compaction tool-call detection (port of the web `lib/context-compaction.ts`).
///
/// A compaction lifecycle arrives as an ACP `tool_call` whose
/// `_meta.contextCompaction` takes one of two shapes:
///
/// - the boolean marker `true`: codex-acp 1.1.3–1.2.x, and codeg's Grok bridge
///   for `auto_compact_completed` (live and in history), which stamps sibling
///   `tokensBefore` / `tokensAfter` counts next to it;
/// - the versioned object `{version: 1, …}`, whose optional `trigger`,
///   `preTokens`, `postTokens`, `durationMs` and `error` fields an adapter fills
///   as far as it knows them: codex-acp 1.3.0+, claude-agent-acp 0.75.0+, and
///   Pi (fork.234 synthesizes it from pi-acp's `compaction` records, live, and
///   from the transcript's compaction summaries).
///
/// It is addressed by that meta key, NOT by tool name, so it works for every
/// host that adopts it. It renders as a chrome-less centered divider ("context
/// was compacted here"), not as a tool card, and must never fold into a
/// "N tools" group.
enum ContextCompaction {
    /// Whether this tool call's `_meta` marks it as a compaction.
    static func matches(_ meta: AnyJSON?) -> Bool {
        guard let marker = meta?["contextCompaction"] else { return false }
        if marker.bool == true { return true }
        guard let version = marker["version"]?.double else { return false }
        return version.isFinite && version >= 1 && version == version.rounded()
    }

    /// The token counts, when the adapter knows them: the object's
    /// `preTokens` / `postTokens`, else Grok's sibling `tokensBefore` /
    /// `tokensAfter`. Often nil (codex sends none, Pi only the count before),
    /// and the divider falls back to a plain label then.
    static func tokens(_ meta: AnyJSON?) -> (before: Int?, after: Int?) {
        let payload = meta?["contextCompaction"]
        return (count(payload, "preTokens") ?? count(meta, "tokensBefore"),
                count(payload, "postTokens") ?? count(meta, "tokensAfter"))
    }

    /// How long it took, from the versioned object.
    static func durationMs(_ meta: AnyJSON?) -> Int? {
        count(meta?["contextCompaction"], "durationMs")
    }

    /// Why it failed, from the versioned object (`cancelled`, the agent's
    /// message); nil when it didn't.
    static func error(_ meta: AnyJSON?) -> String? {
        meta?["contextCompaction"]?["error"]?.nonEmptyString
    }

    /// A non-negative, finite integer field off the opaque meta pass-through.
    private static func count(_ meta: AnyJSON?, _ key: String) -> Int? {
        guard let value = meta?[key]?.double, value.isFinite, value >= 0, value < 9e15 else { return nil }
        return Int(value)
    }
}
