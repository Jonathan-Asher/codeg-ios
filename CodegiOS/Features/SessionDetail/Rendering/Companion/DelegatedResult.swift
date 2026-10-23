import SwiftUI

/// A continued sub-agent's final result, delivered to its parent session as a
/// message. A usage limit paused the sub-agent, codeg continued it once the
/// limit reset, and its result reaches the parent as a user message (the
/// backend's `limit_delivery::delivery_prompt`): a note to the agent, then
///
///     <delegation-result task_id="…" agent="claude_code" status="completed" child_session="42">
///     the result
///     </delegation-result>
///
/// (`error_code="…"` follows `status` when the sub-agent failed). The
/// transcript draws it as a compact card instead of the markup.
struct DelegatedResult: Hashable, Sendable {
    var taskId: String?
    /// The agent's wire slug (`claude_code`).
    var agentSlug: String?
    /// `completed`, `failed`, `canceled`, `running` or `unknown`.
    var status: String
    var errorCode: String?
    /// The sub-agent's own session.
    var childConversationId: Int?
    /// The result as delivered (codeg caps it at 32k characters).
    var body: String

    var agent: AgentType? { agentSlug.map(AgentType.parse) }

    var badge: ResolvedBadge {
        switch status {
        case "completed": return ResolvedBadge(status: .ok)
        case "running":
            return DelegationModel.isPaused(errorCode)
                ? ResolvedBadge(status: .paused, errorCode: errorCode)
                : ResolvedBadge(status: .checked)
        case "canceled": return ResolvedBadge(status: .err, errorCode: errorCode ?? "canceled")
        case "unknown": return ResolvedBadge(status: .err, errorCode: "unknown")
        default: return ResolvedBadge(status: .err, errorCode: errorCode)
        }
    }

    var isFailure: Bool { badge.status == .err }

    /// The start of the result on one line, for the card.
    var preview: String {
        let flat = body.prefix(600).split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return flat.count > 280 ? String(flat.prefix(280)) + "…" : flat
    }

    private static let openTag = "<delegation-result"
    private static let closeTag = "</delegation-result>"

    /// The delivered result a message is, or nil. The message must end with the
    /// block; what comes before it is codeg's note to the agent.
    static func parse(_ text: String) -> DelegatedResult? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasSuffix(closeTag),
              let open = trimmed.range(of: openTag),
              let tagEnd = trimmed[open.upperBound...].firstIndex(of: ">") else { return nil }
        // The tag name must end where the attributes (or the tag) begin.
        guard let next = trimmed[open.upperBound...].first, next == " " || next == ">" || next == "\n" else {
            return nil
        }
        let bodyEnd = trimmed.index(trimmed.endIndex, offsetBy: -closeTag.count)
        let bodyStart = trimmed.index(after: tagEnd)
        guard bodyStart <= bodyEnd else { return nil }

        var attributes: [String: String] = [:]
        let tag = String(trimmed[open.upperBound..<tagEnd])
        let pattern = #"([A-Za-z_][\w-]*)="([^"]*)""#
        if let regex = try? NSRegularExpression(pattern: pattern) {
            let ns = tag as NSString
            for match in regex.matches(in: tag, range: NSRange(location: 0, length: ns.length)) {
                attributes[ns.substring(with: match.range(at: 1))] = ns.substring(with: match.range(at: 2))
            }
        }
        guard let status = attributes["status"], !status.isEmpty else { return nil }
        func value(_ key: String) -> String? { attributes[key].flatMap { $0.isEmpty ? nil : $0 } }
        return DelegatedResult(
            taskId: value("task_id"),
            agentSlug: value("agent"),
            status: status,
            errorCode: value("error_code"),
            childConversationId: value("child_session").flatMap { Int($0) },
            body: String(trimmed[bodyStart..<bodyEnd]).trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    /// A user turn that is a delivered result: text only, ending with the block.
    static func parse(_ turn: MessageTurn) -> DelegatedResult? {
        guard turn.role == .user else { return nil }
        var texts: [String] = []
        for block in turn.blocks {
            guard case .text(let text) = block else { return nil }
            texts.append(text)
        }
        let text = texts.joined(separator: "\n")
        guard text.contains(openTag) else { return nil }
        return parse(text)
    }
}

/// A delivered sub-agent result in the transcript: the agent, the result's
/// status, the start of the result, and a tap that opens the sub-agent's
/// session.
struct DelegatedResultCard: View {
    let result: DelegatedResult
    @Environment(SessionActions.self) private var actions: SessionActions?

    var body: some View {
        if let child = result.childConversationId, let actions {
            Button { actions.openSession(child) } label: { card(opens: true) }
                .buttonStyle(.plain)
                .accessibilityHint(Text("Opens the session"))
        } else {
            card(opens: false)
        }
    }

    private func card(opens: Bool) -> some View {
        let badge = result.badge
        return HStack(alignment: .top, spacing: 10) {
            avatar
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(verbatim: result.agent?.displayName ?? String(localized: "Sub-agent"))
                        .font(Theme.Typography.cardTitle)
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                    if let taskId = result.taskId {
                        Text(verbatim: "#" + taskId.prefix(8))
                            .font(.mono(10.5)).foregroundStyle(Theme.textTertiary)
                    }
                    Spacer(minLength: 4)
                    CompanionStatusBadge(status: badge.status, errorCode: badge.errorCode)
                        .fixedSize()
                }
                Text("Sub-agent result")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(Theme.textTertiary)
                if !result.preview.isEmpty {
                    Text(verbatim: result.preview)
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if opens {
                    HStack(spacing: 3) {
                        Text("Open the sub-agent’s session")
                        Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold))
                    }
                    .font(.caption.weight(.medium))
                    .foregroundStyle(Theme.accent)
                    .padding(.top, 2)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous))
        .hairlineBorder(Theme.Radius.md, color: result.isFailure ? Theme.danger.opacity(0.4) : Theme.surfaceStroke)
        .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous))
    }

    @ViewBuilder private var avatar: some View {
        if let agent = result.agent {
            AgentAvatar(agent: agent, size: 34)
        } else {
            Image(systemName: "person.2")
                .font(.system(size: 14))
                .foregroundStyle(Theme.textTertiary)
                .frame(width: 34, height: 34)
                .background(Theme.surfaceNested, in: Circle())
                .overlay(Circle().strokeBorder(Theme.hairline, lineWidth: 1))
        }
    }
}
