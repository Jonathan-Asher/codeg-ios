import SwiftUI
import UIKit
import XCTest
@testable import Codeg

/// Renders a reply's media cards (a picture, a video poster, an audio file
/// playing, a document, a file that is gone, a format the iPhone can't play)
/// in light and dark, through the window capture of
/// ``SessionListScreenshotTests``. Nothing reaches a server: the picture is
/// put in the disk cache and the video's preview is seeded.
///
/// The files go to `$COMPOSE_SHOTS_DIR` as `media-cards-*.png`.
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

        let refs = [chart, video]
        for style in [UIUserInterfaceStyle.light, .dark] {
            try Shot.capture("media-cards", style, in: Shot.composeDirectory, settle: 1.5) {
                ZStack {
                    CodegBackground()
                    ScrollView {
                        VStack(alignment: .leading, spacing: 12) {
                            Text(verbatim: "Rendered the demo and the chart; the voice-over is next to them.")
                                .font(Theme.Typography.messageBody)
                                .foregroundStyle(Theme.textPrimary)
                            MediaCardsView(refs: refs)
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
}
