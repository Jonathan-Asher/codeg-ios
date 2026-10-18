import SwiftUI
import UIKit
import XCTest
@testable import Codeg

/// Renders the media cards (a picture and a video poster at their inline
/// height, an audio file playing, a document, a file that is gone, a format
/// the iPhone can't play) and the compact row several files fold into
/// (closed, open, right to left, with a message's attached video in its
/// card) in light and dark, through the window capture of
/// ``SessionListScreenshotTests``. Nothing reaches a server: the pictures are
/// put in the disk cache and the videos' previews are seeded.
///
/// The files go to `$COMPOSE_SHOTS_DIR` as `media-cards-*.png` and
/// `media-compact*-*.png`.
@MainActor
final class MediaScreenshotTests: XCTestCase {
    private let client = CodegClient(baseURL: URL(string: "http://127.0.0.1:9")!, token: "media-shots")

    private func ref(_ path: String, scope: String = "shots") -> MediaRef {
        MediaRef(path: path, format: MediaFormats.format(forPath: path)!, origin: .link, scope: scope)
    }

    /// A chart-like picture, drawn here.
    private func picture(_ size: CGSize, hue: CGFloat) -> UIImage {
        UIGraphicsImageRenderer(size: size).image { context in
            let colors = [UIColor(hue: hue, saturation: 0.55, brightness: 0.95, alpha: 1).cgColor,
                          UIColor(hue: hue + 0.12, saturation: 0.75, brightness: 0.55, alpha: 1).cgColor]
            let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors as CFArray,
                                      locations: [0, 1])!
            context.cgContext.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: size.width, y: size.height),
                                                 options: [])
            UIColor.white.withAlphaComponent(0.85).setFill()
            for index in 0..<8 {
                let height = size.height * (0.2 + 0.08 * CGFloat((index * 5) % 7))
                UIBezierPath(roundedRect: CGRect(x: 24 + CGFloat(index) * (size.width - 48) / 8,
                                                 y: size.height - 20 - height,
                                                 width: (size.width - 48) / 8 - 10, height: height),
                             cornerRadius: 4).fill()
            }
        }
    }

    func testAReplysMediaCards() async throws {
        let library = MediaLibrary(client: client)
        let chart = ref("/Users/j/proj/out/chart.png")
        let disk = MediaDiskCache.shared
        _ = try disk.store(try XCTUnwrap(picture(CGSize(width: 900, height: 520), hue: 0.55).pngData()),
                           key: library.fileKey(for: chart), ext: "png")
        // The picture's whole path, from the cached file to a scaled-down
        // decode; the card then draws it from memory at once.
        let thumbnail = try await library.image(for: chart, maxPixelSize: 600)
        XCTAssertEqual(max(thumbnail.size.width * thumbnail.scale, thumbnail.size.height * thumbnail.scale), 600)
        _ = try await library.image(for: chart, maxPixelSize: 1200)
        let video = ref("/Users/j/proj/out/demo.mp4")
        library.seedPreview(VideoPreview(poster: picture(CGSize(width: 1280, height: 720), hue: 0.08),
                                         duration: 94, size: 18_400_000), for: video)

        // The audio file, playing a minute in.
        let center = MediaPlaybackCenter(owner: AudioSessionOwner(driver: FakeAudioSession(), retryDelay: 0) { _ in },
                                         stopReadAloud: {})
        let engine = FakePlaybackEngine()
        let audio = MediaPlayerModel(ref: ref("/Users/j/proj/out/voice over.m4a"), provider: FakeMediaProvider(),
                                     engine: engine, center: center)
        await audio.playAndWait()
        engine.onReady?(185)
        engine.onTime?(62)
        defer { audio.stop() }

        for style in [UIUserInterfaceStyle.light, .dark] {
            try Shot.capture("media-cards", style, in: Shot.composeDirectory, settle: 1.5) {
                ZStack {
                    CodegBackground()
                    ScrollView {
                        VStack(alignment: .leading, spacing: 12) {
                            Text(verbatim: "Rendered the demo and the chart; the voice-over is next to them.")
                                .font(Theme.Typography.messageBody)
                                .foregroundStyle(Theme.textPrimary)
                            MediaCard(ref: chart, library: library, compact: true)
                            MediaCard(ref: video, library: library, compact: true)
                            AudioMediaCard(model: audio)
                            MediaCard(ref: ref("/Users/j/proj/docs/report.pdf"), library: library)
                            MediaNoteRow(ref: ref("/Users/j/proj/out/old.mov"),
                                         message: MediaError.missing.errorDescription ?? "")
                            MediaCard(ref: ref("/Users/j/proj/out/capture.avi"), library: library)
                        }
                        .padding(.horizontal, Theme.Layout.screenHMargin)
                        .padding(.top, 70)
                    }
                }
                .environment(\.codegMedia, MediaEnvironment(library: library,
                                                            context: MediaPathContext(folderPath: "/Users/j/proj")))
            }
        }
        if let cached = disk.lookup(library.fileKey(for: chart), ext: "png") {
            try? FileManager.default.removeItem(at: cached)
        }
    }

    /// A reply's several files folded into one row, closed and open; a reply
    /// with one picture inline; a message with an attached video in its card;
    /// and the same in Hebrew, right to left.
    func testTheCompactMediaRow() async throws {
        let library = MediaLibrary(client: client)
        let disk = MediaDiskCache.shared
        let pictures = [
            (ref("/Users/j/proj/out/chart.png"), 0.55), (ref("/Users/j/proj/out/signin-en.png"), 0.72),
            (ref("/Users/j/proj/out/listing.png"), 0.33),
        ]
        for (picture, hue) in pictures {
            _ = try disk.store(try XCTUnwrap(self.picture(CGSize(width: 900, height: 600), hue: hue).pngData()),
                               key: library.fileKey(for: picture), ext: "png")
            // Decode the thumbnails (26 pt and 36 pt at 3x) and the inline
            // picture up front, so the cards draw them from memory at once.
            for size in [78, 108, 1200] { _ = try await library.image(for: picture, maxPixelSize: size) }
        }
        let demo = ref("/Users/j/proj/out/demo.mp4")
        library.seedPreview(VideoPreview(poster: picture(CGSize(width: 1280, height: 720), hue: 0.08),
                                         duration: 94, size: 18_400_000), for: demo)
        let attached = MediaRef(path: "/srv/uploads/conv-1-claude_code-7/take 2.mp4",
                                format: MediaFormats.format(forPath: "x.mp4")!, origin: .link, scope: "u-1")
        library.seedPreview(VideoPreview(poster: picture(CGSize(width: 720, height: 1280), hue: 0.9),
                                         duration: 12, size: 6_100_000), for: attached)

        let group = MediaGroup(items: [
            MediaItem(ref: pictures[0].0, size: 182_000), MediaItem(ref: pictures[1].0, size: 96_400),
            MediaItem(ref: pictures[2].0, size: 27_700), MediaItem(ref: ref("/Users/j/proj/out/guide-HE.pdf"), size: 517_421),
            MediaItem(ref: demo, size: 18_400_000),
            MediaItem(ref: ref("/Users/j/proj/out/old-shot.png"), isDeleted: true),
        ])
        let single = MediaGroup(items: [MediaItem(ref: pictures[0].0, size: 182_000)])
        let message = MessageTurn(id: "u-1", role: .user, blocks: [
            .text("What happens at 0:08?"),
            .text(MediaAttachmentText.marker(name: "take 2.mp4", path: attached.path)),
        ], timestamp: Date())
        var userNode = TimelineNode(id: "u-1", content: .user(message), agent: .claudeCode)
        userNode.attachedMedia = MediaGroup(refs: [attached])
        let environment = MediaEnvironment(library: library, context: MediaPathContext(folderPath: "/Users/j/proj"))

        func screen(open: Bool, hebrew: Bool) -> some View {
            ZStack {
                CodegBackground()
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        NodeBody(node: userNode)
                        Text(verbatim: hebrew ? "חתכתי את הצילומים ובניתי מחדש את המדריך. הקבצים:"
                                              : "Cropped the shots and rebuilt the guide. The files:")
                            .font(Theme.Typography.messageBody)
                            .foregroundStyle(Theme.textPrimary)
                        MediaGroupDisclosure(group: group, library: library, expanded: open)
                        Text(verbatim: hebrew ? "והגרף לבד:" : "And the chart on its own:")
                            .font(Theme.Typography.messageBody)
                            .foregroundStyle(Theme.textPrimary)
                        MediaGroupView(group: single)
                    }
                    .padding(.horizontal, Theme.Layout.screenHMargin)
                    .padding(.top, 70)
                }
            }
            .environment(\.codegMedia, environment)
            .environment(\.layoutDirection, hebrew ? .rightToLeft : .leftToRight)
        }

        for style in [UIUserInterfaceStyle.light, .dark] {
            try Shot.capture("media-compact", style, in: Shot.composeDirectory, settle: 1.5) { screen(open: false, hebrew: false) }
            try Shot.capture("media-compact-open", style, in: Shot.composeDirectory, settle: 1.5) { screen(open: true, hebrew: false) }
        }
        try Shot.capture("media-compact-rtl", .light, in: Shot.composeDirectory, settle: 1.5) { screen(open: true, hebrew: true) }
        for (picture, _) in pictures {
            if let cached = disk.lookup(library.fileKey(for: picture), ext: "png") {
                try? FileManager.default.removeItem(at: cached)
            }
        }
    }
}
