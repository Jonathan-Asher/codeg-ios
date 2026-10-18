import SwiftUI
import UIKit

/// The media files a message or reply refers to, as cards under it: pictures
/// as thumbnails, videos as a poster with their length, audio as an inline
/// player, documents as a row that opens Quick Look.
struct MediaCardsView: View {
    let refs: [MediaRef]
    @Environment(\.codegMedia) private var media

    var body: some View {
        if let media {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(refs) { ref in
                    MediaCard(ref: ref, library: media.library)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// One file's card.
struct MediaCard: View {
    let ref: MediaRef
    let library: MediaLibrary

    var body: some View {
        switch ref.kind {
        case .image:
            if ref.format.vector {
                DocumentMediaCard(ref: ref, library: library)
            } else {
                ImageMediaCard(ref: ref, library: library)
            }
        case .video:
            if ref.format.unsupported {
                MediaNoteRow(ref: ref, message: "\(ref.ext.uppercased()) files don't play on the iPhone.")
            } else {
                VideoMediaCard(ref: ref, library: library)
            }
        case .audio:
            AudioMediaCard(model: library.player(for: ref))
        case .document:
            DocumentMediaCard(ref: ref, library: library)
        }
    }
}

// MARK: - Shared pieces

/// The file's name and its folder, small, under a card.
private struct MediaCaption: View {
    let ref: MediaRef
    var detail: String?

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: MediaSymbols.symbol(for: ref))
                .font(.system(size: 10, weight: .semibold))
            Text(verbatim: ref.name)
                .font(Theme.Typography.metaLabel)
                .lineLimit(1)
                .truncationMode(.middle)
            if let detail {
                Text(verbatim: "· \(detail)")
                    .font(Theme.Typography.metaLabel.monospacedDigit())
                    .lineLimit(1)
            }
        }
        .foregroundStyle(Theme.textTertiary)
    }
}

enum MediaSymbols {
    static func symbol(for ref: MediaRef) -> String {
        switch ref.kind {
        case .image: return ref.format.vector ? "square.on.circle" : "photo"
        case .video: return "film"
        case .audio: return "waveform"
        case .document: return ref.ext == "pdf" ? "doc.richtext" : "doc"
        }
    }
}

/// A file that can't be shown, and why.
struct MediaNoteRow: View {
    let ref: MediaRef
    let message: String
    var retry: (() -> Void)?

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: MediaSymbols.symbol(for: ref))
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Theme.textTertiary)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: ref.name)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(message)
                    .font(.caption)
                    .foregroundStyle(Theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            if let retry {
                Button("Retry", action: retry)
                    .font(.caption.weight(.semibold))
                    .buttonStyle(.borderless)
                    .tint(Theme.accent)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Theme.surfaceNested, in: RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous))
        .hairlineBorder(Theme.Radius.md, color: Theme.hairline)
        .accessibilityElement(children: .combine)
    }
}

private extension MediaError {
    /// Worth a Retry button: the network, not the file.
    var isRetryable: Bool {
        if case .network = self { return true }
        if case .server = self { return true }
        return false
    }
}

// MARK: - Picture

private struct ImageMediaCard: View {
    let ref: MediaRef
    let library: MediaLibrary

    @State private var image: UIImage?
    @State private var error: MediaError?
    @State private var attempt = 0

    var body: some View {
        Group {
            if let image {
                VStack(alignment: .leading, spacing: 6) {
                    Button {
                        MediaPresenter.shared.showImage(.ref(ref, library: library))
                    } label: {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFit()
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .frame(maxHeight: 260)
                            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous))
                            .hairlineBorder(Theme.Radius.md)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text(verbatim: ref.name))
                    .accessibilityHint("Opens the picture full screen")
                    MediaCaption(ref: ref)
                }
            } else if let error {
                MediaNoteRow(ref: ref, message: error.errorDescription ?? "Couldn't load this picture.",
                             retry: error.isRetryable ? { self.error = nil; attempt += 1 } : nil)
            } else {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    MediaCaption(ref: ref)
                }
                .frame(maxWidth: .infinity, minHeight: 120)
                .background(Theme.surfaceNested, in: RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous))
                .hairlineBorder(Theme.Radius.md, color: Theme.hairline)
            }
        }
        .task(id: "\(ref.id)|\(attempt)") {
            do {
                image = try await library.image(for: ref, maxPixelSize: 1200)
            } catch {
                guard !Task.isCancelled else { return }
                self.error = MediaError.from(error)
            }
        }
    }
}

// MARK: - Video

private struct VideoMediaCard: View {
    let ref: MediaRef
    let library: MediaLibrary

    @State private var preview: VideoPreview?
    @State private var error: MediaError?
    @State private var attempt = 0

    var body: some View {
        Group {
            if let error {
                MediaNoteRow(ref: ref, message: error.errorDescription ?? "Couldn't load this video.",
                             retry: error.isRetryable || error == .expired ? { self.error = nil; attempt += 1 } : nil)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    Button(action: play) { poster }
                        .buttonStyle(.plain)
                        .accessibilityLabel(Text(verbatim: "Play \(ref.name)"))
                        .accessibilityValue(preview?.duration.map { Text(DurationText.clock($0)) } ?? Text(""))
                    MediaCaption(ref: ref, detail: detail)
                }
            }
        }
        .task(id: "\(ref.id)|\(attempt)") {
            do {
                preview = try await library.videoPreview(for: ref)
            } catch {
                guard !Task.isCancelled else { return }
                self.error = MediaError.from(error)
            }
        }
    }

    private var detail: String? {
        guard let preview else { return nil }
        var parts: [String] = []
        if let duration = preview.duration { parts.append(DurationText.clock(duration)) }
        if preview.size > 0 { parts.append(ByteCountFormatter.string(fromByteCount: preview.size, countStyle: .file)) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private var poster: some View {
        ZStack {
            Rectangle()
                .fill(Color.black.opacity(0.85))
            if let image = preview?.poster {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
            } else if preview == nil {
                ProgressView().tint(.white)
            } else {
                Image(systemName: "film")
                    .font(.system(size: 28))
                    .foregroundStyle(.white.opacity(0.5))
            }
            Image(systemName: "play.fill")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 54, height: 54)
                .background(.ultraThinMaterial, in: Circle())
                .environment(\.colorScheme, .dark)
        }
        .overlay(alignment: .bottomTrailing) {
            if let duration = preview?.duration {
                Text(DurationText.clock(duration))
                    .font(.caption2.weight(.semibold).monospacedDigit())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(Color.black.opacity(0.6), in: Capsule())
                    .padding(8)
            }
        }
        .aspectRatio(posterAspect, contentMode: .fit)
        .frame(maxWidth: .infinity)
        .frame(maxHeight: 240)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous))
        .hairlineBorder(Theme.Radius.md)
    }

    private var posterAspect: CGFloat {
        guard let size = preview?.poster?.size, size.height > 0 else { return 16 / 9 }
        return max(0.5, min(2.4, size.width / size.height))
    }

    private func play() {
        let model = library.videoPlayer(for: ref)
        MediaPresenter.shared.playVideo(model)
    }
}

// MARK: - Audio

/// An audio file's player inline: play and pause, a scrubber, the time.
struct AudioMediaCard: View {
    @Bindable var model: MediaPlayerModel
    @State private var scrubPosition: TimeInterval = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Button {
                    model.toggle()
                } label: {
                    ZStack {
                        Circle().fill(Theme.accent.opacity(0.16))
                        if model.isBusy {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
                                .font(.system(size: 15, weight: .bold))
                                .foregroundStyle(Theme.accent)
                                .offset(x: model.isPlaying ? 0 : 1)
                        }
                    }
                    .frame(width: 38, height: 38)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(model.isPlaying ? Text("Pause") : Text("Play"))

                VStack(alignment: .leading, spacing: 4) {
                    Text(verbatim: model.ref.name)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if let failure = model.failure {
                        Text(failure)
                            .font(.caption)
                            .foregroundStyle(Theme.danger)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        Slider(value: Binding(
                            get: { model.isScrubbing ? scrubPosition : model.position },
                            set: { scrubPosition = $0 }
                        ), in: 0...max(model.duration ?? 1, 0.01)) { editing in
                            if editing {
                                scrubPosition = model.position
                                model.isScrubbing = true
                            } else {
                                model.isScrubbing = false
                                model.seek(to: scrubPosition)
                            }
                        }
                        .controlSize(.mini)
                        .tint(Theme.accent)
                        .disabled(model.duration == nil)
                        .accessibilityLabel("Position")
                    }
                }
            }
            HStack {
                Text(DurationText.clock(model.isScrubbing ? scrubPosition : model.position))
                Spacer()
                Text(model.duration.map(DurationText.clock) ?? "--:--")
            }
            .font(Theme.Typography.metaLabel.monospacedDigit())
            .foregroundStyle(Theme.textTertiary)
            .padding(.leading, 50)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Theme.surfaceNested, in: RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous))
        .hairlineBorder(Theme.Radius.md, color: Theme.hairline)
    }
}

// MARK: - Documents and SVG

private struct DocumentMediaCard: View {
    let ref: MediaRef
    let library: MediaLibrary

    @State private var opening = false
    @State private var error: MediaError?

    var body: some View {
        Button(action: open) {
            HStack(spacing: 10) {
                Image(systemName: MediaSymbols.symbol(for: ref))
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(Theme.accent)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: ref.name)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(error?.errorDescription ?? (ref.format.vector ? "SVG image" : "\(ref.ext.uppercased()) document"))
                        .font(.caption)
                        .foregroundStyle(error == nil ? Theme.textTertiary : Theme.danger)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                if opening {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.textTertiary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(Theme.surfaceNested, in: RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous))
            .hairlineBorder(Theme.Radius.md, color: Theme.hairline)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(opening)
    }

    private func open() {
        opening = true
        error = nil
        Task {
            defer { opening = false }
            do {
                let file = try await library.localFile(for: ref, maxBytes: MediaLibrary.maxDocumentBytes)
                if ref.format.vector {
                    MediaPresenter.shared.showVector(fileURL: file, name: ref.name)
                } else {
                    MediaPresenter.shared.showDocument(fileURL: file, name: ref.name)
                }
            } catch {
                self.error = MediaError.from(error)
            }
        }
    }
}

// MARK: - Time

enum DurationText {
    /// 75 → "1:15"; 3725 → "1:02:05".
    static func clock(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "--:--" }
        let total = Int(seconds.rounded(.down))
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}

// MARK: - A file from the Files tab

/// A media file opened from a folder's Files tab: its card, full width.
struct MediaFileScreen: View {
    let ref: MediaRef
    let library: MediaLibrary

    var body: some View {
        ZStack {
            CodegBackground()
            ScrollView {
                MediaCard(ref: ref, library: library)
                    .padding(.horizontal, Theme.Layout.screenHMargin)
                    .padding(.vertical, 16)
            }
        }
        .navigationTitle(ref.name)
        .navigationBarTitleDisplayMode(.inline)
    }
}
