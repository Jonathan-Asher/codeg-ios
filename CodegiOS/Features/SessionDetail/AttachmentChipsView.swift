import SwiftUI

/// A horizontal strip of attached-image thumbnails shown above the compose
/// field, each with a remove button. Mirrors the web client's attachment row in
/// `ConversationContextBar`. A video's chip shows its poster and length once
/// it is ready, and until then how far it is: downloading from iCloud,
/// compressing, uploading, paused. One that failed says why and tries again on
/// a tap. An audio file's chip is a waveform with its length; a document's,
/// its symbol, name and size.
struct AttachmentChipsView: View {
    let attachments: [Attachment]
    let onRemove: (UUID) -> Void
    var onRetry: (UUID) -> Void = { _ in }
    var onSetQuality: (VideoQuality, UUID) -> Void = { _, _ in }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(attachments) { attachment in
                    if let upload = attachment.upload, upload.kind == .document {
                        DocumentAttachmentChip(upload: upload,
                                               onRemove: { onRemove(attachment.id) },
                                               onRetry: { onRetry(attachment.id) })
                    } else if let upload = attachment.upload {
                        VideoAttachmentChip(upload: upload,
                                            onRemove: { onRemove(attachment.id) },
                                            onRetry: { onRetry(attachment.id) },
                                            onSetQuality: { onSetQuality($0, attachment.id) })
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

/// A video or audio file on its way: its poster (or a film or waveform
/// symbol), a ring with how far it is, and what it is doing. A long press
/// offers Original or Compressed for a video on a server that takes large
/// files.
struct VideoAttachmentChip: View {
    let upload: AttachmentUpload
    let onRemove: () -> Void
    let onRetry: () -> Void
    var onSetQuality: (VideoQuality) -> Void = { _ in }

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
        .contextMenu {
            if upload.offersQuality {
                Picker(selection: Binding(get: { upload.quality }, set: { onSetQuality($0) })) {
                    ForEach(VideoQuality.allCases, id: \.self) { quality in
                        Text(verbatim: quality.label).tag(quality)
                    }
                } label: {
                    Text("Send the video")
                }
                .pickerStyle(.inline)
            }
            if let note = upload.note {
                Text(verbatim: note)
            }
            Button("Remove", systemImage: "xmark", role: .destructive, action: onRemove)
        }
        .overlay(alignment: .topTrailing) { ChipRemoveButton(action: onRemove) }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(verbatim: upload.displayName))
        .accessibilityValue(Text(verbatim: upload.spokenStatus))
        .accessibilityHint(upload.failure != nil ? Text("Shows why, and tries again") : Text(verbatim: ""))
        .alert(upload.kind == .audio ? "The audio file didn't upload" : "The video didn't upload",
               isPresented: $showsFailure) {
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
                Image(systemName: upload.kind == .audio ? "waveform" : "film")
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
                    Image(systemName: upload.kind == .audio ? "waveform" : "play.fill")
                        .font(.system(size: 7, weight: .bold))
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
        case .waiting(let fraction, .network):
            progressRing(fraction, symbol: "wifi.exclamationmark", dimmed: true)
        case .waiting(let fraction, .background):
            progressRing(fraction, symbol: "pause.fill", dimmed: true)
        }
    }

    private func progressRing(_ fraction: Double?, symbol: String, dimmed: Bool = false) -> some View {
        ZStack {
            Color.black.opacity(0.4)
            UploadRing(fraction: fraction, symbol: symbol, color: .white, dimmed: dimmed, side: 30)
        }
    }
}

/// A document on its way: its symbol (a ring while it uploads), its name and
/// its size. Removing, a failure's Try Again and its reason behave as on a
/// video's chip.
struct DocumentAttachmentChip: View {
    let upload: AttachmentUpload
    let onRemove: () -> Void
    let onRetry: () -> Void

    @State private var showsFailure = false

    private static let width: CGFloat = 176
    private static let height: CGFloat = 56

    var body: some View {
        Button {
            if upload.failure != nil { showsFailure = true }
        } label: {
            HStack(spacing: 9) {
                symbol
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: upload.displayName)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    detail
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(upload.failure == nil ? Theme.textTertiary : Theme.danger)
                        .lineLimit(1)
                }
            }
            // Room for the remove button in the corner.
            .padding(.leading, 10)
            .padding(.trailing, 22)
            .frame(width: Self.width, height: Self.height, alignment: .leading)
            .background(Color.primary.opacity(0.06),
                        in: RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous))
            .hairlineBorder(Theme.Radius.sm, color: upload.failure == nil ? Theme.surfaceStroke : Theme.danger)
        }
        .buttonStyle(.plain)
        .contextMenu {
            if let note = upload.note {
                Text(verbatim: note)
            }
            Button("Remove", systemImage: "xmark", role: .destructive, action: onRemove)
        }
        .overlay(alignment: .topTrailing) { ChipRemoveButton(action: onRemove) }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(verbatim: upload.displayName))
        .accessibilityValue(Text(verbatim: upload.spokenStatus))
        .accessibilityHint(upload.failure != nil ? Text("Shows why, and tries again") : Text(verbatim: ""))
        .alert("The document didn't upload", isPresented: $showsFailure) {
            Button("Try Again", action: onRetry)
            Button("Remove", role: .destructive, action: onRemove)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(verbatim: upload.failure ?? "")
        }
    }

    @ViewBuilder
    private var symbol: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Theme.accent.opacity(0.12))
            switch upload.phase {
            case .done:
                documentSymbol
            case .failed:
                Image(systemName: "exclamationmark.arrow.circlepath")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.danger)
            case .fetching(let fraction):
                UploadRing(fraction: fraction, symbol: "arrow.up", color: Theme.accent, side: 26)
            case .compressing(let fraction), .uploading(let fraction):
                UploadRing(fraction: fraction, symbol: "arrow.up", color: Theme.accent, side: 26)
            case .waiting(let fraction, .network):
                UploadRing(fraction: fraction, symbol: "wifi.exclamationmark", color: Theme.accent, dimmed: true, side: 26)
            case .waiting(let fraction, .background):
                UploadRing(fraction: fraction, symbol: "pause.fill", color: Theme.accent, dimmed: true, side: 26)
            }
        }
        .frame(width: 34, height: 34)
    }

    private var documentSymbol: some View {
        Image(systemName: DocumentAttachmentPrep.symbol(forFileNamed: upload.displayName))
            .font(.system(size: 16, weight: .medium))
            .foregroundStyle(Theme.accent)
    }

    /// The size, how far the upload is, or why it stopped.
    @ViewBuilder
    private var detail: some View {
        switch upload.phase {
        case .done:
            Text(verbatim: [typeLabel, sizeText].compactMap { $0 }.joined(separator: " · "))
        case .failed:
            Text("Didn't upload")
        case .uploading(let fraction), .compressing(let fraction):
            Text(verbatim: ["\(Int(fraction * 100))%", sizeText].compactMap { $0 }.joined(separator: " · "))
        case .fetching:
            Text(verbatim: sizeText ?? "…")
        case .waiting(_, .network):
            Text("Waiting for the network")
        case .waiting(_, .background):
            Text("Paused")
        }
    }

    /// "PDF", "DOCX": the extension, as the message's card shows it.
    private var typeLabel: String? {
        let ext = (upload.displayName as NSString).pathExtension
        return ext.isEmpty ? nil : ext.uppercased()
    }

    private var sizeText: String? {
        upload.totalBytes > 0 ? ByteCountFormatter.string(fromByteCount: upload.totalBytes, countStyle: .file) : nil
    }
}

/// How far an upload is: a ring that fills, and a symbol of what it is
/// doing; a spinner while that isn't known yet.
private struct UploadRing: View {
    let fraction: Double?
    let symbol: String
    let color: Color
    var dimmed = false
    let side: CGFloat

    var body: some View {
        ZStack {
            Circle()
                .stroke(color.opacity(0.3), lineWidth: 3)
                .frame(width: side, height: side)
            if let fraction {
                Circle()
                    .trim(from: 0, to: max(0.03, min(1, fraction)))
                    .stroke(color.opacity(dimmed ? 0.6 : 1), style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .frame(width: side, height: side)
                    .animation(.linear(duration: 0.2), value: fraction)
                Image(systemName: symbol)
                    .font(.system(size: side / 3, weight: .bold))
                    .foregroundStyle(color)
            } else {
                ProgressView().controlSize(.small).tint(color)
            }
        }
    }
}

extension AttachmentUpload {
    /// What the chip says to VoiceOver about where the upload is.
    var spokenStatus: String {
        switch phase {
        case .fetching(let fraction):
            if let fraction { return "Downloading from iCloud, \(Int(fraction * 100)) percent" }
            switch kind {
            case .video: return "Getting the video"
            case .audio: return "Getting the audio file"
            case .document: return "Getting the document"
            }
        case .compressing(let fraction): return "Compressing, \(Int(fraction * 100)) percent"
        case .uploading(let fraction): return "Uploading, \(Int(fraction * 100)) percent\(spokenBytes)"
        case .waiting(let fraction, .network):
            return "Waiting for the network, \(Int(fraction * 100)) percent uploaded"
        case .waiting(let fraction, .background):
            return "Paused, \(Int(fraction * 100)) percent uploaded. It goes on when the app is open."
        case .done:
            let size = kind == .document && totalBytes > 0
                ? ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file) : nil
            return [note, duration.map(DurationText.clock), size].compactMap { $0 }.joined(separator: ", ")
        case .failed(let message): return message
        }
    }

    /// ", 12 MB of 340 MB" for a file of a few megabytes or more.
    private var spokenBytes: String {
        guard totalBytes >= 4 * 1024 * 1024 else { return "" }
        let sent = ByteCountFormatter.string(fromByteCount: sentBytes, countStyle: .file)
        let total = ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file)
        return ", \(sent) of \(total)"
    }
}
