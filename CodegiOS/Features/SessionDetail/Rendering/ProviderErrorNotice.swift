import SwiftUI

/// A provider's refusal or error (``ProviderError``), told compactly: one line
/// saying who stopped and why, the provider's own link, and the raw message
/// folded under Details, never the message dumped as a reply. The same state
/// codeg web draws on a sub-agent's card and for a stopped turn.
struct ProviderErrorNotice: View {
    enum Scope: Equatable {
        /// On a sub-agent's (Agent/Task) card.
        case subagent
        /// For the turn the transcript shows (the main agent's own error).
        case turn
    }

    let error: ProviderError
    let scope: Scope

    @State private var detailsOpen = false

    /// "Sub-agent stopped: …" or "Stopped: …".
    static func title(for error: ProviderError, scope: Scope) -> String {
        let reason = error.kind.reason
        switch scope {
        case .subagent: return String(localized: "Sub-agent stopped: \(reason)")
        case .turn: return String(localized: "Stopped: \(reason)")
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.octagon.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.danger)
                Text(verbatim: Self.title(for: error, scope: scope))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Theme.danger)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let link = error.link {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text("Learn more:")
                        .foregroundStyle(Theme.textSecondary)
                    Link(destination: link) {
                        Text(verbatim: link.absoluteString)
                            .underline()
                            .multilineTextAlignment(.leading)
                    }
                    .tint(Theme.accent)
                }
                .font(.caption)
                .padding(.leading, 19)
            }
            Button {
                withAnimation(Theme.Motion.expand) { detailsOpen.toggle() }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                        .rotationEffect(.degrees(detailsOpen ? 90 : 0))
                    Text("Details")
                }
                .font(.caption)
                .foregroundStyle(Theme.textSecondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.leading, 19)
            .accessibilityValue(detailsOpen ? Text("Expanded") : Text("Collapsed"))
            if detailsOpen {
                Text(verbatim: error.raw)
                    .font(.caption2.monospaced())
                    .foregroundStyle(Theme.textSecondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.danger.opacity(0.06),
                                in: RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous))
                    .padding(.leading, 19)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.danger.opacity(0.1), in: RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous))
        .hairlineBorder(Theme.Radius.sm, color: Theme.danger.opacity(0.4))
    }
}
