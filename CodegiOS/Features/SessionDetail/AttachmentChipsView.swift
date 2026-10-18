import SwiftUI

/// A horizontal strip of attached-image thumbnails shown above the compose
/// field, each with a remove button. Mirrors the web client's attachment row in
/// `ConversationContextBar`. A video's chip shows its poster and length once
/// it is ready, and until then how far it is: downloading from iCloud,
/// compressing, uploading. One that failed says why and tries again on a tap.
struct AttachmentChipsView: View {
    let attachments: [Attachment]
    let onRemove: (UUID) -> Void
    var onRetry: (UUID) -> Void = { _ in }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(attachments) { attachment in
                    if let upload = attachment.upload {
                        VideoAttachmentChip(upload: upload,
                                            onRemove: { onRemove(attachment.id) },
                                            onRetry: { onRetry(attachment.id) })
                    } else {
                        AttachmentChip(attachment: attachment) { onRemove(attachment.id) }
                    }
                }
            }
            .padding(.horizontal, 2)
            .padding(.vertical, 2)
        }
        .scrollClipDisabled()
    }
}

/// The remove button in a chip's corner.
private struct ChipRemoveButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.white)
                .padding(4)
                .background(.black.opacity(0.55), in: Circle())
        }
        .buttonStyle(.plain)
        .padding(3)
        .accessibilityLabel("Remove attachment")
    }
}

private struct AttachmentChip: View {
    let attachment: Attachment
    let onRemove: () -> Void

    static let side: CGFloat = 56

    var body: some View {
        thumbnail
            .frame(width: Self.side, height: Self.side)
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous))
            .hairlineBorder(Theme.Radius.sm)
            .overlay(alignment: .topTrailing) { ChipRemoveButton(action: onRemove) }
    }

    @ViewBuilder
    private var thumbnail: some View {
        if let image = UIImage(data: attachment.data) {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
        } else {
            ZStack {
                Color.primary.opacity(0.06)
                Image(systemName: "photo")
                    .font(.system(size: 18))
                    .foregroundStyle(Theme.textTertiary)
            }
        }
    }
}

/// A video on its way: its poster (or a film symbol), a ring with how far it
/// is, and what it is doing.
struct VideoAttachmentChip: View {
    let upload: AttachmentUpload
    let onRemove: () -> Void
    let onRetry: () -> Void

    @State private var showsFailure = false

    private static let side: CGFloat = 56

    var body: some View {
        Button {
            if upload.failure != nil { showsFailure = true }
        } label: {
            ZStack {
                poster
                overlay
            }
            .frame(width: Self.side, height: Self.side)
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous))
            .hairlineBorder(Theme.Radius.sm, color: upload.failure == nil ? Theme.surfaceStroke : Theme.danger)
        }
        .buttonStyle(.plain)
        .overlay(alignment: .topTrailing) { ChipRemoveButton(action: onRemove) }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(verbatim: upload.displayName))
        .accessibilityValue(Text(verbatim: statusText))
        .accessibilityHint(upload.failure != nil ? Text("Shows why, and tries again") : Text(verbatim: ""))
        .alert("The video didn't upload", isPresented: $showsFailure) {
            Button("Try Again", action: onRetry)
            Button("Remove", role: .destructive, action: onRemove)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(verbatim: upload.failure ?? "")
        }
    }

    @ViewBuilder
    private var poster: some View {
        if let image = upload.poster {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: Self.side, height: Self.side)
        } else {
            ZStack {
                Color.primary.opacity(0.06)
                Image(systemName: "film")
                    .font(.system(size: 18))
                    .foregroundStyle(Theme.textTertiary)
            }
        }
    }

    @ViewBuilder
    private var overlay: some View {
        switch upload.phase {
        case .done:
            VStack {
                Spacer()
                HStack(spacing: 3) {
                    Image(systemName: "play.fill").font(.system(size: 7, weight: .bold))
                    if let duration = upload.duration {
                        Text(DurationText.clock(duration)).font(.system(size: 9, weight: .semibold).monospacedDigit())
                    }
                    Spacer(minLength: 0)
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 5)
                .padding(.vertical, 3)
                .background(LinearGradient(colors: [.clear, .black.opacity(0.6)], startPoint: .top, endPoint: .bottom))
            }
        case .failed:
            ZStack {
                Color.black.opacity(0.45)
                Image(systemName: "exclamationmark.arrow.circlepath")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.white)
            }
        case .fetching(let fraction):
            progressRing(fraction, symbol: "icloud.and.arrow.down")
        case .compressing(let fraction):
            progressRing(fraction, symbol: "wand.and.stars")
        case .uploading(let fraction):
            progressRing(fraction, symbol: "arrow.up")
        }
    }

    private func progressRing(_ fraction: Double?, symbol: String) -> some View {
        ZStack {
            Color.black.opacity(0.4)
            Circle()
                .stroke(.white.opacity(0.3), lineWidth: 3)
                .frame(width: 30, height: 30)
            if let fraction {
                Circle()
                    .trim(from: 0, to: max(0.03, min(1, fraction)))
                    .stroke(.white, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .frame(width: 30, height: 30)
                    .animation(.linear(duration: 0.2), value: fraction)
            } else {
                ProgressView().controlSize(.small).tint(.white)
            }
            if fraction != nil {
                Image(systemName: symbol)
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white)
            }
        }
    }

    private var statusText: String {
        switch upload.phase {
        case .fetching(let fraction):
            return fraction.map { "Downloading from iCloud, \(Int($0 * 100)) percent" } ?? "Getting the video"
        case .compressing(let fraction): return "Compressing, \(Int(fraction * 100)) percent"
        case .uploading(let fraction): return "Uploading, \(Int(fraction * 100)) percent"
        case .done: return [upload.note, upload.duration.map(DurationText.clock)].compactMap { $0 }.joined(separator: ", ")
        case .failed(let message): return message
        }
    }
}
