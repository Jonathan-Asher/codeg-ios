import SwiftUI

/// The link's state at the top of a screen, under the navigation bar (see
/// ``LinkStatus``): "Reconnecting…", "Offline · updated 3 min ago",
/// "Updating…", "Back online". A small capsule over the content that takes
/// no taps, so a drop never covers or blocks what is on screen.
struct ConnectionCapsule: View {
    /// When what this screen shows was last current, when it knows better
    /// than the last list refresh (a session's transcript).
    var updatedAt: Date?

    private var status: LinkStatus { LinkStatus.shared }

    var body: some View {
        ZStack {
            switch status.display {
            case .none:
                EmptyView()
            case .reconnecting:
                capsule(Text("Reconnecting…"), spinner: true)
            case .updating:
                capsule(Text("Updating…"), spinner: true)
            case .backOnline:
                capsule(Text("Back online"), icon: "checkmark.circle.fill")
            case .offline:
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    capsule(offlineText(now: context.date), icon: "wifi.slash")
                }
            }
        }
        .animation(.snappy(duration: 0.25), value: status.display)
        .allowsHitTesting(false)
    }

    private func offlineText(now: Date) -> Text {
        guard let date = updatedAt ?? status.lastContact else { return Text("Offline") }
        return Text("Offline · updated \(RelativeTime.string(from: date, relativeTo: now))")
    }

    private func capsule(_ label: Text, spinner: Bool = false, icon: String? = nil) -> some View {
        HStack(spacing: 6) {
            if spinner {
                ProgressView()
                    .controlSize(.mini)
            }
            if let icon {
                Image(systemName: icon)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Theme.textSecondary)
            }
            label
                .font(.footnote.weight(.medium))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .glassEffect(.regular, in: Capsule())
        .accessibilityElement(children: .combine)
        .transition(.move(edge: .top).combined(with: .opacity))
    }
}

extension View {
    /// Shows ``ConnectionCapsule`` at the top of this screen's content,
    /// under the navigation bar.
    func connectionCapsule(updatedAt: Date? = nil) -> some View {
        overlay(alignment: .top) {
            ConnectionCapsule(updatedAt: updatedAt)
                .padding(.top, 6)
        }
    }
}
