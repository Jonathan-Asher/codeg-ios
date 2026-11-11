import SwiftUI

/// What a session screen says about the copy of the transcript it shows
/// (``SessionDetailViewModel/freshness``). A session opens on the copy saved
/// on the phone, or the one a kept screen held, which can be minutes or hours
/// old, and the server's copy replaces it once read: until then the screen
/// says it is updating, and if the read fails, that it couldn't, with Try
/// Again, instead of leaving an old copy looking current.
enum TranscriptFreshness: Equatable {
    /// The server's copy as of the last read, or nothing shown to update.
    case current
    /// A saved or kept copy is on screen while the server's is read.
    case updating
    /// The read failed; the copy stays on screen. Why, for the log.
    case failed(String)
}

/// ``TranscriptFreshness`` at the top of the session screen, under the
/// navigation bar: "Updating…", or "Couldn’t update" with Try Again. Drawn
/// like ``ConnectionCapsule``, which goes first: while the link has something
/// to say ("Offline", "Reconnecting…"), this waits. "Updating…" appears only
/// once the read has taken half a second (``ConnectionDisplayTracker/updatingAfter``,
/// as the link's own "Updating…"), so a quick one passes without a flicker.
struct TranscriptFreshnessCapsule: View {
    let freshness: TranscriptFreshness
    let onRetry: () -> Void

    @State private var showsUpdating = false

    /// The link's capsule shows nothing.
    private var linkIsQuiet: Bool {
        if case .none = LinkStatus.shared.display { return true }
        return false
    }

    var body: some View {
        ZStack {
            if linkIsQuiet {
                switch freshness {
                case .current:
                    EmptyView()
                case .updating:
                    if showsUpdating {
                        updating
                    }
                case .failed:
                    failed
                }
            }
        }
        .animation(.snappy(duration: 0.25), value: freshness)
        .animation(.snappy(duration: 0.25), value: showsUpdating)
        .task(id: freshness) {
            guard freshness == .updating else {
                showsUpdating = false
                return
            }
            try? await Task.sleep(for: .seconds(ConnectionDisplayTracker.updatingAfter))
            if !Task.isCancelled { showsUpdating = true }
        }
        .onChange(of: freshness) { _, new in
            // The capsule doesn't take VoiceOver's focus: say it.
            if case .failed = new {
                AccessibilityNotification.Announcement(
                    String(localized: "Couldn’t update the session. Showing the saved copy.")
                ).post()
            }
        }
    }

    private var updating: some View {
        HStack(spacing: 6) {
            ProgressView()
                .controlSize(.mini)
            Text("Updating…")
                .font(.footnote.weight(.medium))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .glassEffect(.regular, in: Capsule())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Showing the saved copy. Updating to the latest messages."))
        .allowsHitTesting(false)
        .transition(.move(edge: .top).combined(with: .opacity))
    }

    private var failed: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Theme.textSecondary)
                .accessibilityHidden(true)
            Text("Couldn’t update")
                .font(.footnote.weight(.medium))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)
                .accessibilityLabel(Text("Couldn’t update the session. Showing the saved copy."))
            Button("Try Again", action: onRetry)
                .font(.footnote.weight(.semibold))
                .buttonStyle(.borderless)
                .tint(Theme.accent)
        }
        .padding(.leading, 12)
        .padding(.trailing, 10)
        .padding(.vertical, 6)
        .glassEffect(.regular, in: Capsule())
        .accessibilityElement(children: .contain)
        .transition(.move(edge: .top).combined(with: .opacity))
    }
}

extension View {
    /// Shows ``TranscriptFreshnessCapsule`` at the top of this screen's
    /// content, where ``ConnectionCapsule`` sits when the link is down.
    func transcriptFreshness(_ freshness: TranscriptFreshness, onRetry: @escaping () -> Void) -> some View {
        overlay(alignment: .top) {
            TranscriptFreshnessCapsule(freshness: freshness, onRetry: onRetry)
                .padding(.top, 6)
        }
    }
}
