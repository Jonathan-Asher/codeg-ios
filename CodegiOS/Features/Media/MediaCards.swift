import SwiftUI
import UIKit

/// The files a message or reply refers to. One picture or video shows
/// inline at a capped height (an audio file as its player, a document as its
/// row); several fold into one row ("3 images · 1 PDF · 1 video" with tiny
/// thumbnails) that opens into a list, the way codeg web's "New files" card
/// keeps a reply short.
struct MediaGroupView: View {
    let group: MediaGroup
    @Environment(\.codegMedia) private var media

    var body: some View {
        if let media {
            Group {
                if group.showsInline {
                    MediaCard(ref: group.items[0].ref, library: media.library, compact: true)
                } else {
                    MediaGroupDisclosure(group: group, library: media.library)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// Several files as one row that opens into a list of them.
struct MediaGroupDisclosure: View {
    let group: MediaGroup
    let library: MediaLibrary
    @State private var expanded: Bool

    init(group: MediaGroup, library: MediaLibrary, expanded: Bool = false) {
        self.group = group
        self.library = library
        _expanded = State(initialValue: expanded)
    }

    private static let thumbnailCount = 4

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(Theme.Motion.expand) { expanded.toggle() }
            } label: {
                header
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(verbatim: MediaGroupSummary.spoken(group.items)))
            .accessibilityValue(expanded ? Text("Shown") : Text("Hidden"))
            .accessibilityHint(expanded ? Text("Hides the files") : Text("Shows the files"))
            if expanded {
                Divider().overlay(Theme.hairline)
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(group.items.enumerated()), id: \.element.id) { index, item in
                        if index > 0 {
                            Divider().overlay(Theme.hairline).padding(.leading, 58)
                        }
                        MediaListRow(item: item, library: library)
                    }
                }
                .padding(.vertical, 4)
                .transition(.opacity)
            }
        }
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous))
        .hairlineBorder(Theme.Radius.md)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous))
    }

    private var header: some View {
        HStack(spacing: 10) {
            HStack(spacing: 4) {
                ForEach(group.items.prefix(Self.thumbnailCount)) { item in
                    MediaThumbnail(item: item, library: library, side: 26)
                }
            }
            Text(verbatim: MediaGroupSummary.text(group.items))
                .font(Theme.Typography.cardTitle)
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)
                .truncationMode(.tail)
                .minimumScaleFactor(0.8)
            Spacer(minLength: 4)
            Image(systemName: "chevron.forward")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(Theme.textTertiary)
                // `chevron.forward` is mirrored right to left after the
                // rotation, so a quarter turn points down either way.
                .rotationEffect(.degrees(expanded ? 90 : 0))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
    }
}

/// "3 images · 1 PDF · 1 video", for the folded row.
enum MediaGroupSummary {
    static func text(_ items: [MediaItem]) -> String {
        parts(items).joined(separator: " · ")
    }

    /// The same, read out: "3 images, 1 PDF, 1 video".
    static func spoken(_ items: [MediaItem]) -> String {
        parts(items).joined(separator: ", ")
    }

    private static func parts(_ items: [MediaItem]) -> [String] {
        var images = 0, videos = 0, audio = 0, pdfs = 0, documents = 0, deleted = 0
        for item in items {
            if item.isDeleted { deleted += 1; continue }
            switch item.ref.kind {
            case .image: images += 1
            case .video: videos += 1
            case .audio: audio += 1
            case .document: if item.ref.ext == "pdf" { pdfs += 1 } else { documents += 1 }
            }
        }
        var out: [String] = []
        if images > 0 { out.append(count(images, "image", "images")) }
        if videos > 0 { out.append(count(videos, "video", "videos")) }
        if audio > 0 { out.append(count(audio, "audio file", "audio files")) }
        if pdfs > 0 { out.append(count(pdfs, "PDF", "PDFs")) }
        if documents > 0 { out.append(count(documents, "document", "documents")) }
        if deleted > 0 { out.append(out.isEmpty ? count(deleted, "deleted file", "deleted files") : "\(deleted) deleted") }
        return out
    }

    private static func count(_ n: Int, _ one: String, _ many: String) -> String {
        "\(n) \(n == 1 ? one : many)"
    }
}

/// One file in the opened list: its thumbnail, name and what it is. A
/// picture opens full screen, a video plays, a document opens in Quick Look;
/// an audio file is its own small player.
private struct MediaListRow: View {
    let item: MediaItem
    let library: MediaLibrary

    var body: some View {
        if item.ref.kind == .audio, !item.isDeleted, !item.ref.format.unsupported {
            AudioMediaCard(model: library.player(for: item.ref), embedded: true)
                .padding(.horizontal, 2)
        } else {
            Button(action: open) {
                HStack(spacing: 12) {
                    MediaThumbnail(item: item, library: library, side: 36)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: item.ref.name)
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(item.isDeleted ? Theme.textTertiary : Theme.textPrimary)
                            .strikethrough(item.isDeleted, color: Theme.textTertiary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text(verbatim: detail)
                            .font(.caption)
                            .foregroundStyle(Theme.textTertiary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 4)
                    if let trailing {
                        Image(systemName: trailing)
                            .font(.system(size: trailing == "play.fill" ? 12 : 11, weight: .semibold))
                            .foregroundStyle(Theme.textTertiary)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!canOpen)
            .accessibilityLabel(Text(verbatim: "\(item.ref.name), \(detail)"))
        }
    }

    private var canOpen: Bool { !item.isDeleted && !item.ref.format.unsupported }

    private var trailing: String? {
        guard canOpen else { return nil }
        return item.ref.kind == .video ? "play.fill" : "chevron.forward"
    }

    private var detail: String {
        if item.isDeleted { return "Deleted" }
        if item.ref.format.unsupported { return "\(item.ref.ext.uppercased()) files don't play on the iPhone" }
        var parts = [item.ref.format.vector ? "SVG" : item.ref.ext.uppercased()]
        if let size = item.size, size > 0 {
            parts.append(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
        }
        // A file without an extension (an attached `Makefile`) has no type to show.
        return parts.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    private func open() {
        MediaLinks.open(item.ref, library: library)
    }
}

/// A file's small square: a picture's thumbnail, a video's poster, or the
/// symbol of its kind.
struct MediaThumbnail: View {
    let item: MediaItem
    let library: MediaLibrary
    let side: CGFloat

    @State private var image: UIImage?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: side > 30 ? 8 : 6, style: .continuous)
                .fill(Theme.surfaceNested)
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: side, height: side)
                    .clipped()
                if item.ref.kind == .video {
                    Image(systemName: "play.fill")
                        .font(.system(size: side * 0.28, weight: .bold))
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.5), radius: 2)
                }
            } else {
                Image(systemName: MediaSymbols.symbol(for: item.ref))
                    .font(.system(size: side * 0.42, weight: .medium))
                    .foregroundStyle(item.isDeleted ? Theme.textTertiary : Theme.accent)
            }
        }
        .frame(width: side, height: side)
        .clipShape(RoundedRectangle(cornerRadius: side > 30 ? 8 : 6, style: .continuous))
        .opacity(item.isDeleted ? 0.6 : 1)
        .accessibilityHidden(true)
        .task(id: item.id) { await load() }
    }

    private func load() async {
        guard !item.isDeleted, image == nil else { return }
        switch item.ref.kind {
        case .image where !item.ref.format.vector:
            image = try? await library.image(for: item.ref, maxPixelSize: Int(side * 3))
        case .video where item.ref.format.native:
            image = (try? await library.videoPreview(for: item.ref))?.poster
        default:
            break
        }
    }
}

/// One file's card.
struct MediaCard: View {
    let ref: MediaRef
    let library: MediaLibrary
    /// Under a message: a picture or a video poster at most this tall.
    var compact = false

    /// The tallest an inline picture or poster gets under a message.
    static let compactHeight: CGFloat = 180

    var body: some View {
        switch ref.kind {
        case .image:
            if ref.format.vector {
                DocumentMediaCard(ref: ref, library: library)
            } else {
                ImageMediaCard(ref: ref, library: library, maxHeight: compact ? Self.compactHeight : 260)
            }
        case .video:
            if ref.format.unsupported {
                MediaNoteRow(ref: ref, message: "\(ref.ext.uppercased()) files don't play on the iPhone.")
            } else {
                VideoMediaCard(ref: ref, library: library, maxHeight: compact ? Self.compactHeight : 240)
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
                // The separator stands on its own, so it stays between the
                // name and the detail right to left too.
                Text(verbatim: "·")
                    .font(Theme.Typography.metaLabel)
                Text(verbatim: detail)
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
    var maxHeight: CGFloat = 260

    @State private var image: UIImage?
    @State private var error: MediaError?
    @State private var attempt = 0

    init(ref: MediaRef, library: MediaLibrary, maxHeight: CGFloat = 260) {
        self.ref = ref
        self.library = library
        self.maxHeight = maxHeight
        // Decoded before: shown at once, with no placeholder first.
        _image = State(initialValue: library.cachedImage(for: ref, maxPixelSize: 1200))
    }

    /// The loading box takes the picture's height when its proportions are
    /// known, or the card's full height (what a screenshot under a message
    /// takes), so the picture landing moves as little as possible.
    @ViewBuilder
    private var loadingBox: some View {
        let box = HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            MediaCaption(ref: ref)
        }
        if let aspect = library.knownAspect(for: ref, maxPixelSize: 1200) {
            Theme.surfaceNested
                .aspectRatio(aspect, contentMode: .fit)
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(maxHeight: maxHeight)
                .overlay { box }
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous))
                .hairlineBorder(Theme.Radius.md, color: Theme.hairline)
        } else {
            box
                .frame(maxWidth: .infinity, minHeight: maxHeight <= MediaCard.compactHeight ? maxHeight : min(120, maxHeight))
                .background(Theme.surfaceNested, in: RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous))
                .hairlineBorder(Theme.Radius.md, color: Theme.hairline)
        }
    }

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
                            .frame(maxHeight: maxHeight)
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
                loadingBox
            }
        }
        .task(id: "\(ref.id)|\(attempt)") {
            if image != nil, attempt == 0 { return }
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
    var maxHeight: CGFloat = 240

    @State private var preview: VideoPreview?
    @State private var error: MediaError?
    @State private var attempt = 0

    init(ref: MediaRef, library: MediaLibrary, maxHeight: CGFloat = 240) {
        self.ref = ref
        self.library = library
        self.maxHeight = maxHeight
        // Read before: the poster and its proportions from the start.
        _preview = State(initialValue: library.cachedPreview(for: ref))
    }

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
        .frame(maxHeight: maxHeight)
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
    /// Inside the opened list of a message's files: no card of its own.
    var embedded = false
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
        .background(embedded ? Color.clear : Theme.surfaceNested,
                    in: RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous))
        .hairlineBorder(Theme.Radius.md, color: embedded ? .clear : Theme.hairline)
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
                    Text(error?.errorDescription ?? (ref.format.vector ? "SVG image"
                        : ref.ext.isEmpty ? "Document" : "\(ref.ext.uppercased()) document"))
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
