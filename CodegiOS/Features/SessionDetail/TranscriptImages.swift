import ImageIO
import UIKit

/// Pictures in transcripts (attachments, generated images, what tools
/// return), decoded off the main thread and scaled down to what the screen
/// shows, then kept in memory.
///
/// `UIImage(data:)` defers decoding to the first draw, which happened on the
/// main thread at full size: a 3000-pixel screenshot cost tens of
/// milliseconds and a 36 MB bitmap there, the moment it scrolled in.
/// ImageIO's thumbnail path decodes once, at most `maxPixelSize` on the long
/// side, on a background thread. The pictures themselves are stored with the
/// transcript in `TranscriptCache`, so a cached session never fetches them.
enum TranscriptImages {
    /// The long side of a decoded picture. A transcript shows pictures at
    /// most 320 points high and the screen's width (1320 pixels on an
    /// iPhone Pro Max in portrait); 1600 keeps them sharp.
    static let maxPixelSize = 1600

    private static let memory: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.totalCostLimit = 96 * 1024 * 1024
        return cache
    }()

    /// A key that is cheap to compute on the main thread for a picture of
    /// any size: its length and both ends of its base64 text (the ends hold
    /// the format header and the final checksums), or the server path of a
    /// picture sent by reference.
    static func key(for image: ImageData) -> String {
        if let ref = image.dataRef { return "ref|\(ref)" }
        let text = image.data
        return "b64|\(text.utf8.count)|\(text.prefix(64))|\(text.suffix(64))"
    }

    static func cached(_ key: String) -> UIImage? {
        memory.object(forKey: key as NSString)
    }

    static func store(_ image: UIImage, key: String) {
        let cost = image.cgImage.map { $0.bytesPerRow * $0.height } ?? 0
        memory.setObject(image, forKey: key as NSString, cost: cost)
    }

    /// Base64 text to a decoded, downscaled picture, on a background thread.
    static func decode(base64: String, maxPixelSize: Int = maxPixelSize) async -> UIImage? {
        await Task.detached(priority: .userInitiated) {
            guard let data = Data(base64Encoded: base64, options: .ignoreUnknownCharacters) else { return nil }
            return downsample(data, maxPixelSize: maxPixelSize)
        }.value
    }

    /// Image file bytes to a decoded, downscaled picture, on a background thread.
    static func decode(data: Data, maxPixelSize: Int = maxPixelSize) async -> UIImage? {
        await Task.detached(priority: .userInitiated) {
            downsample(data, maxPixelSize: maxPixelSize)
        }.value
    }

    /// Decode `data` at most `maxPixelSize` on its long side, fully, now
    /// (not at first draw). Smaller pictures keep their size.
    static func downsample(_ data: Data, maxPixelSize: Int) -> UIImage? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return UIImage(cgImage: image)
    }
}
