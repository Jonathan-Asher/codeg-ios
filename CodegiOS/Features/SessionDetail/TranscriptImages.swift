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
        if image.size.width > 0, image.size.height > 0 {
            noteAspect(image.size.width / image.size.height, key: key)
        }
    }

    // MARK: Sizes

    /// Width over height of the pictures decoded so far, kept after the
    /// picture itself is evicted, so a placeholder can take the picture's
    /// height before it decodes again and nothing moves when it does.
    nonisolated(unsafe) private static var aspects: [String: CGFloat] = [:]
    private static let aspectsLock = NSLock()

    static func aspect(_ key: String) -> CGFloat? {
        aspectsLock.withLock { aspects[key] }
    }

    static func noteAspect(_ aspect: CGFloat, key: String) {
        aspectsLock.withLock {
            if aspects.count > 4000 { aspects.removeAll(keepingCapacity: true) }
            aspects[key] = aspect
        }
    }

    /// Width over height of an inline picture: as decoded before, or read
    /// from the first bytes of its file (PNG, GIF and JPEG), without decoding it.
    static func aspect(of image: ImageData) -> CGFloat? {
        let key = key(for: image)
        if let known = aspect(key) { return known }
        guard image.dataRef == nil, let size = ImageDimensions.size(ofBase64: image.data),
              size.width > 0, size.height > 0 else { return nil }
        let ratio = size.width / size.height
        noteAspect(ratio, key: key)
        return ratio
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

/// A picture's pixel size from the first bytes of its file, without decoding
/// it: PNG (`IHDR`), GIF (the logical screen) and JPEG (the first `SOFn`
/// frame, unless an Exif block could turn it).
enum ImageDimensions {
    /// The first bytes of base64 text are enough: PNG and GIF keep the size
    /// in their first 24 bytes, a JPEG in its first frame header.
    static let prefixCharacters = 65_536

    static func size(ofBase64 text: String) -> CGSize? {
        let head = text.prefix(prefixCharacters).filter { !$0.isWhitespace }
        let usable = head.count - head.count % 4
        guard usable >= 32, let data = Data(base64Encoded: String(head.prefix(usable))) else { return nil }
        return size(of: data)
    }

    static func size(of data: Data) -> CGSize? {
        let bytes = [UInt8](data)
        func be16(_ i: Int) -> Int { Int(bytes[i]) << 8 | Int(bytes[i + 1]) }
        func be32(_ i: Int) -> Int { be16(i) << 16 | be16(i + 2) }
        func le16(_ i: Int) -> Int { Int(bytes[i]) | Int(bytes[i + 1]) << 8 }
        // PNG: signature, then IHDR's width and height.
        if bytes.count >= 24, bytes[0] == 0x89, bytes[1] == 0x50, bytes[2] == 0x4E, bytes[3] == 0x47,
           bytes[12] == 0x49, bytes[13] == 0x48, bytes[14] == 0x44, bytes[15] == 0x52 {
            return CGSize(width: be32(16), height: be32(20))
        }
        // GIF87a / GIF89a: the logical screen's width and height.
        if bytes.count >= 10, bytes[0] == 0x47, bytes[1] == 0x49, bytes[2] == 0x46 {
            return CGSize(width: le16(6), height: le16(8))
        }
        // JPEG: walk the markers to the first frame header.
        guard bytes.count >= 4, bytes[0] == 0xFF, bytes[1] == 0xD8 else { return nil }
        var i = 2
        while i + 9 < bytes.count {
            guard bytes[i] == 0xFF else { return nil }
            let marker = bytes[i + 1]
            if marker == 0xFF { i += 1; continue }
            // Standalone markers carry no length.
            if marker == 0x01 || (0xD0...0xD7).contains(marker) { i += 2; continue }
            let length = be16(i + 2)
            guard length >= 2 else { return nil }
            // An Exif block may rotate the picture: the frame's size could be
            // the wrong way round, so leave it to the decode.
            if marker == 0xE1 { return nil }
            let isFrame = (0xC0...0xCF).contains(marker) && marker != 0xC4 && marker != 0xC8 && marker != 0xCC
            if isFrame {
                return CGSize(width: be16(i + 7), height: be16(i + 5))
            }
            i += 2 + length
        }
        return nil
    }
}
