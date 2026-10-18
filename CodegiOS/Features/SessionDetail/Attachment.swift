import SwiftUI
import UniformTypeIdentifiers

/// A picture or a video the user has attached to the next prompt.
///
/// A picture travels inline: the already-prepared (downscaled/compressed)
/// bytes, so the chip thumbnail and the wire payload come from the same
/// source. A video is uploaded to codeg first (``AttachmentUpload``) and the
/// prompt links to the uploaded file (a `resource_link`, as codeg web attaches
/// a file that isn't a picture); it can be sent once the upload is done.
///
/// NOTE: the web client gates image attaching on the connection's
/// `prompt_capabilities.image`. That capability is delivered as a live
/// `prompt_capabilities` stream event on a persistent per-conversation
/// connection, which this Phase-1 client does not maintain or model (same root
/// as the agent-options probe seam). Image-unsupported agents are therefore not
/// pre-gated here; such a turn surfaces the agent's error via the normal live-turn
/// failure path rather than being blocked up front. Capability gating is a
/// follow-up that depends on modeling live session/capability events. A
/// resource link needs no capability: every ACP agent takes one.
struct Attachment: Identifiable, Hashable, Sendable {
    let id: UUID
    let name: String
    let mimeType: String
    /// A picture's bytes. Empty for a video.
    let data: Data
    /// A video's upload; nil for a picture.
    let upload: AttachmentUpload?

    init(id: UUID = UUID(), name: String, mimeType: String, data: Data) {
        self.id = id
        self.name = name
        self.mimeType = mimeType
        self.data = data
        self.upload = nil
    }

    /// A video on its way to the server.
    init(id: UUID = UUID(), video upload: AttachmentUpload) {
        self.id = id
        self.name = upload.displayName
        self.mimeType = "video/mp4"
        self.data = Data()
        self.upload = upload
    }

    var isVideo: Bool { upload != nil }
    /// Bytes that ride in the prompt itself (a video's are uploaded instead).
    var byteCount: Int { data.count }
    var base64: String { data.base64EncodedString() }
    /// Ready to send: a picture always, a video once it is uploaded.
    @MainActor var isReady: Bool { upload?.isDone ?? true }

    /// The wire block sent in `acp_prompt`.
    @MainActor var promptInputBlock: PromptInputBlock {
        if let uploaded = upload?.uploaded {
            return .resourceLink(uri: MediaAttachmentText.fileURI(forPath: uploaded.path), name: uploaded.name,
                                 mimeType: uploaded.mimeType ?? VideoAttachmentPrep.mimeType(
                                    forExtension: (uploaded.name as NSString).pathExtension))
        }
        return .image(data: base64, mimeType: mimeType, uri: nil)
    }

    /// The block used to render this attachment immediately in the optimistic
    /// user turn: a picture decoded by `InlineImageView`; a video as the link
    /// codeg shows for it (`[name](file://…)`), which the message's card plays.
    @MainActor var optimisticBlock: ContentBlock {
        if let uploaded = upload?.uploaded {
            return .text(MediaAttachmentText.marker(name: uploaded.name, path: uploaded.path))
        }
        return .image(ImageData(data: base64, mimeType: mimeType, uri: nil))
    }
}

/// Prepares picked/captured images into compact `Attachment`s: downscales to a
/// sane max dimension and re-encodes large images as JPEG so a full-res photo
/// doesn't become a multi-megabyte base64 blob on the wire.
enum AttachmentPrep {
    static let maxDimension: CGFloat = 1568
    static let jpegQuality: CGFloat = 0.75
    /// Hard cap on a single prepared image (sanity bound; the aggregate budget
    /// below is the binding limit in practice).
    static let maxBytes = 4 * 1024 * 1024
    /// Aggregate cap on the RAW bytes of all staged images. `acp_prompt` rides
    /// Axum's default 2 MiB JSON body limit, and base64 inflates by ~33%, so the
    /// combined payload (base64 + text + JSON overhead) must stay well under
    /// 2 MiB. ~1.3 MB raw → ~1.73 MB base64, leaving comfortable headroom.
    static let maxTotalBytes = 1_300_000
    /// Max simultaneous attachments on one prompt (secondary to the byte budget).
    static let maxCount = 10

    /// Prepare an in-memory image (camera capture or Photos pick) as a
    /// downscaled JPEG attachment.
    static func make(from image: UIImage, name: String) -> Attachment? {
        let scaled = downscaled(image, maxDimension: maxDimension)
        guard let data = scaled.jpegData(compressionQuality: jpegQuality), !data.isEmpty else { return nil }
        guard data.count <= maxBytes else { return nil }
        return Attachment(name: name.isEmpty ? defaultName : name, mimeType: "image/jpeg", data: data)
    }

    /// Prepare image bytes (e.g. from `PhotosPickerItem.loadTransferable`).
    /// Returns nil if the bytes aren't a decodable image.
    static func make(fromImageData raw: Data, name: String) -> Attachment? {
        guard let image = UIImage(data: raw) else { return nil }
        // Re-encode through `make(from:)` when oversized or large; otherwise keep
        // the original bytes (preserves PNG transparency, avoids needless recompress)
        // — but ONLY for formats we can positively identify as agent-safe. Anything
        // unrecognized (HEIC/TIFF/…) is re-encoded to JPEG so we never ship bytes
        // under a mislabeled mime type.
        if raw.count > maxBytes || max(image.size.width, image.size.height) > maxDimension {
            return make(from: image, name: name)
        }
        guard let mime = raw.imageMimeType else {
            return make(from: image, name: name)
        }
        return Attachment(name: name.isEmpty ? defaultName : name, mimeType: mime, data: raw)
    }

    /// Prepare an image file chosen via `.fileImporter` (security-scoped URL).
    static func make(fromFile url: URL) -> Attachment? {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let raw = try? Data(contentsOf: url) else { return nil }
        let name = url.lastPathComponent
        // Files are filtered to images by the picker, but guard anyway.
        guard UIImage(data: raw) != nil else { return nil }
        return make(fromImageData: raw, name: name)
    }

    private static let defaultName = "image"

    private static func downscaled(_ image: UIImage, maxDimension: CGFloat) -> UIImage {
        let longest = max(image.size.width, image.size.height)
        guard longest > maxDimension, longest > 0 else { return image }
        let scale = maxDimension / longest
        let target = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        return UIGraphicsImageRenderer(size: target, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
    }
}

private extension Data {
    /// Sniff a common image mime type from the file's magic bytes. Operates on a
    /// zero-based byte copy so it's safe regardless of the `Data`'s start index.
    var imageMimeType: String? {
        let bytes = Array(prefix(12))
        guard let first = bytes.first else { return nil }
        switch first {
        case 0x89: return "image/png"
        case 0xFF: return "image/jpeg"
        case 0x47: return "image/gif"
        case 0x52: // "RIFF…WEBP"
            return bytes.count >= 12 && bytes[8...11].elementsEqual([0x57, 0x45, 0x42, 0x50]) ? "image/webp" : nil
        default: return nil
        }
    }
}
