import UIKit

/// A tapped link in a message that names a media file of the session: open
/// it full screen, as the card under the message would.
@MainActor
enum MediaLinks {
    /// The media file `url` names, resolved like a Markdown link destination.
    static func ref(for url: URL, context: MediaPathContext) -> MediaRef? {
        guard let path = MediaPaths.resolve(url.absoluteString, in: context, decode: true),
              let format = MediaFormats.format(forPath: path) else { return nil }
        return MediaRef(path: path, format: format, origin: .link, scope: "link")
    }

    /// Open `url` when it names a media file; false leaves it to the system.
    static func open(_ url: URL, in media: MediaEnvironment?) -> Bool {
        guard let media, let ref = ref(for: url, context: media.context) else { return false }
        open(ref, library: media.library)
        return true
    }

    static func open(_ ref: MediaRef, library: MediaLibrary) {
        switch ref.kind {
        case .image where !ref.format.vector:
            MediaPresenter.shared.showImage(.ref(ref, library: library))
        case .video, .audio:
            if ref.format.unsupported {
                MediaPresenter.shared.showError(title: ref.name,
                                                message: "\(ref.ext.uppercased()) files don't play on the iPhone.")
                return
            }
            MediaPresenter.shared.playVideo(library.videoPlayer(for: ref))
        case .image, .document:
            Task {
                do {
                    let file = try await library.localFile(for: ref, maxBytes: MediaLibrary.maxDocumentBytes)
                    if ref.format.vector {
                        MediaPresenter.shared.showVector(fileURL: file, name: ref.name)
                    } else {
                        MediaPresenter.shared.showDocument(fileURL: file, name: ref.name)
                    }
                } catch {
                    MediaPresenter.shared.showError(title: ref.name,
                                                    message: MediaError.from(error).errorDescription ?? "Couldn't open it.")
                }
            }
        }
    }
}
