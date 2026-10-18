import Photos
import SwiftUI
import UIKit
import WebKit

/// A picture for the full-screen viewer: how to get it at full size and as a
/// file to share or save.
struct MediaImageItem {
    let name: String
    /// The picture's file on the iPhone (downloaded, or written from the
    /// transcript's base64), decoded by the viewer.
    let file: () async throws -> URL
}

extension MediaImageItem {
    /// A picture from the session's files.
    @MainActor
    static func ref(_ ref: MediaRef, library: MediaLibrary) -> MediaImageItem {
        MediaImageItem(name: ref.name) {
            try await library.localFile(for: ref, maxBytes: MediaLibrary.maxImageBytes)
        }
    }

    /// A picture the transcript carries inline (base64), written to a
    /// temporary file once opened.
    static func inline(_ image: ImageData, name: String = "Image") -> MediaImageItem {
        MediaImageItem(name: name) {
            try await Task.detached(priority: .userInitiated) {
                guard let data = Data(base64Encoded: image.data, options: .ignoreUnknownCharacters) else {
                    throw MediaError.unplayable("This picture couldn't be decoded.")
                }
                let ext = MediaImageItem.fileExtension(forMIME: image.mimeType)
                let url = FileManager.default.temporaryDirectory
                    .appendingPathComponent("image-\(UUID().uuidString)").appendingPathExtension(ext)
                try data.write(to: url, options: .atomic)
                return url
            }.value
        }
    }

    /// A picture the server serves by reference (`/api/live_image/<key>`).
    static func reference(_ request: URLRequest, mimeType: String) -> MediaImageItem {
        MediaImageItem(name: "Image") {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw MediaError.missing }
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("image-\(UUID().uuidString)")
                .appendingPathExtension(fileExtension(forMIME: mimeType))
            try data.write(to: url, options: .atomic)
            return url
        }
    }

    static func fileExtension(forMIME mime: String) -> String {
        switch mime.lowercased() {
        case "image/jpeg", "image/jpg": return "jpg"
        case "image/gif": return "gif"
        case "image/webp": return "webp"
        case "image/heic": return "heic"
        case "image/heif": return "heif"
        case "image/svg+xml": return "svg"
        case "image/bmp": return "bmp"
        case "image/tiff": return "tiff"
        default: return "png"
        }
    }
}

/// The full-screen picture: pinch or double-tap to zoom, Share, Save to
/// Photos, Done. An animated GIF plays.
struct MediaImageViewer: View {
    let item: MediaImageItem
    /// Close the viewer (it is presented from UIKit).
    let close: () -> Void

    @State private var image: UIImage?
    @State private var file: URL?
    @State private var error: String?
    @State private var saveNote: String?
    @State private var saving = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let image {
                ZoomableImage(image: image)
                    .ignoresSafeArea()
            } else if let error {
                VStack(spacing: 10) {
                    Image(systemName: "photo")
                        .font(.largeTitle)
                    Text(error)
                        .multilineTextAlignment(.center)
                }
                .foregroundStyle(.white.opacity(0.75))
                .padding(32)
            } else {
                ProgressView()
                    .tint(.white)
            }
        }
        .overlay(alignment: .top) { toolbar }
        .overlay(alignment: .bottom) {
            if let saveNote {
                Text(saveNote)
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(.ultraThinMaterial, in: Capsule())
                    .padding(.bottom, 24)
                    .transition(.opacity)
            }
        }
        .statusBarHidden()
        .task { await load() }
    }

    private var toolbar: some View {
        HStack(spacing: 12) {
            Button {
                close()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 15, weight: .semibold))
                    .frame(width: 38, height: 38)
            }
            .accessibilityLabel("Close")
            Text(item.name)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity)
            if let file {
                ShareLink(item: file) {
                    Image(systemName: "square.and.arrow.up")
                        .font(.system(size: 15, weight: .semibold))
                        .frame(width: 38, height: 38)
                }
                .accessibilityLabel("Share")
                Button {
                    Task { await save(file) }
                } label: {
                    Group {
                        if saving {
                            ProgressView().tint(.white)
                        } else {
                            Image(systemName: "square.and.arrow.down")
                                .font(.system(size: 15, weight: .semibold))
                        }
                    }
                    .frame(width: 38, height: 38)
                }
                .disabled(saving || image == nil)
                .accessibilityLabel("Save to Photos")
            } else {
                Color.clear.frame(width: 88, height: 38)
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.ultraThinMaterial.opacity(0.6), in: Capsule())
        .padding(.horizontal, 12)
        .padding(.top, 8)
    }

    private func load() async {
        do {
            let url = try await item.file()
            file = url
            let decoded = await Task.detached(priority: .userInitiated) {
                MediaImageViewer.decode(url)
            }.value
            guard let decoded else {
                error = "This picture couldn't be decoded."
                return
            }
            image = decoded
        } catch {
            self.error = MediaError.from(error).errorDescription
        }
    }

    /// The picture at up to 4096 pixels, or an animated GIF's frames.
    nonisolated static func decode(_ url: URL) -> UIImage? {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
        if let animated = animatedGIF(data) { return animated }
        return TranscriptImages.downsample(data, maxPixelSize: 4096)
    }

    nonisolated private static func animatedGIF(_ data: Data) -> UIImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 1,
              (CGImageSourceGetType(source) as String?) == "com.compuserve.gif" else { return nil }
        let count = min(CGImageSourceGetCount(source), 300)
        var frames: [UIImage] = []
        var total: Double = 0
        let thumbnail: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                          kCGImageSourceCreateThumbnailWithTransform: true,
                                          kCGImageSourceThumbnailMaxPixelSize: 1600]
        let options = thumbnail as CFDictionary
        for index in 0..<count {
            guard let frame = CGImageSourceCreateThumbnailAtIndex(source, index, options) else { continue }
            frames.append(UIImage(cgImage: frame))
            let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any]
            let gif = properties?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
            let delay = (gif?[kCGImagePropertyGIFUnclampedDelayTime] as? Double)
                ?? (gif?[kCGImagePropertyGIFDelayTime] as? Double) ?? 0.1
            total += delay < 0.02 ? 0.1 : delay
        }
        guard frames.count > 1 else { return frames.first }
        return UIImage.animatedImage(with: frames, duration: total)
    }

    private func save(_ file: URL) async {
        saving = true
        defer { saving = false }
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else {
            note("Allow \(AppIdentity.displayName) to add photos in Settings.")
            return
        }
        do {
            try await PHPhotoLibrary.shared().performChanges {
                PHAssetCreationRequest.forAsset().addResource(with: .photo, fileURL: file, options: nil)
            }
            note("Saved to Photos")
        } catch {
            // Photos takes JPEG, PNG, HEIC and GIF as they are; anything else
            // (WebP, BMP) is saved as the decoded picture.
            guard let image else { note("Couldn't save: \(error.localizedDescription)"); return }
            do {
                try await PHPhotoLibrary.shared().performChanges {
                    PHAssetChangeRequest.creationRequestForAsset(from: image)
                }
                note("Saved to Photos")
            } catch {
                note("Couldn't save: \(error.localizedDescription)")
            }
        }
    }

    private func note(_ text: String) {
        withAnimation { saveNote = text }
        Task {
            try? await Task.sleep(for: .seconds(2.5))
            withAnimation { saveNote = nil }
        }
    }
}

/// A picture in a `UIScrollView`: pinch to zoom, double-tap to zoom in and out.
private struct ZoomableImage: UIViewRepresentable {
    let image: UIImage

    func makeUIView(context: Context) -> ZoomingScrollView {
        let view = ZoomingScrollView()
        view.imageView.image = image
        return view
    }

    func updateUIView(_ view: ZoomingScrollView, context: Context) {
        if view.imageView.image !== image {
            view.imageView.image = image
            view.setNeedsLayout()
        }
    }
}

final class ZoomingScrollView: UIScrollView, UIScrollViewDelegate {
    let imageView = UIImageView()
    private var laidOutSize: CGSize = .zero

    override init(frame: CGRect) {
        super.init(frame: frame)
        delegate = self
        backgroundColor = .clear
        showsVerticalScrollIndicator = false
        showsHorizontalScrollIndicator = false
        contentInsetAdjustmentBehavior = .never
        decelerationRate = .fast
        minimumZoomScale = 1
        maximumZoomScale = 6
        imageView.contentMode = .scaleAspectFit
        imageView.isUserInteractionEnabled = true
        addSubview(imageView)
        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(doubleTapped(_:)))
        doubleTap.numberOfTapsRequired = 2
        addGestureRecognizer(doubleTap)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.size != laidOutSize else { return }
        laidOutSize = bounds.size
        zoomScale = 1
        imageView.frame = bounds
        contentSize = bounds.size
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }

    @objc private func doubleTapped(_ gesture: UITapGestureRecognizer) {
        if zoomScale > 1.01 {
            setZoomScale(1, animated: true)
        } else {
            let point = gesture.location(in: imageView)
            let scale: CGFloat = 3
            let size = CGSize(width: bounds.width / scale, height: bounds.height / scale)
            zoom(to: CGRect(x: point.x - size.width / 2, y: point.y - size.height / 2,
                            width: size.width, height: size.height), animated: true)
        }
    }
}

// MARK: - SVG

/// An SVG file, drawn by WebKit with JavaScript off and nothing fetched from
/// the network.
struct VectorImageViewer: View {
    let fileURL: URL
    let name: String
    let close: () -> Void

    var body: some View {
        NavigationStack {
            VectorWebView(fileURL: fileURL)
                .ignoresSafeArea(edges: .bottom)
                .navigationTitle(name)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Done", action: close)
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        ShareLink(item: fileURL)
                    }
                }
        }
    }
}

private struct VectorWebView: UIViewRepresentable {
    let fileURL: URL

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        let view = WKWebView(frame: .zero, configuration: config)
        view.isOpaque = false
        view.backgroundColor = .systemBackground
        if let data = try? Data(contentsOf: fileURL) {
            view.load(data, mimeType: "image/svg+xml", characterEncodingName: "utf-8",
                      baseURL: URL(string: "about:blank")!)
        }
        return view
    }

    func updateUIView(_ view: WKWebView, context: Context) {}
}
