import AVKit
import QuickLook
import SwiftUI
import UIKit

/// Shows media full screen from wherever it was tapped (a card, a link in a
/// reply, an inline picture): the system video player, the picture viewer,
/// Quick Look. Presented from the top view controller in UIKit, so the video
/// player's Picture in Picture can dismiss it and bring it back.
@MainActor
final class MediaPresenter {
    static let shared = MediaPresenter()

    private var videoSessions: [VideoPlayerSession] = []
    private var previewSources: [QuickLookSource] = []

    private init() {}

    // MARK: Video

    /// Play `model`'s clip in the system player: full screen, AirPlay, and
    /// Picture in Picture. Closing the player stops the clip.
    func playVideo(_ model: MediaPlayerModel) {
        guard let engine = model.engine as? AVPlayerEngine else { return }
        let controller = AVPlayerViewController()
        controller.player = engine.player
        controller.allowsPictureInPicturePlayback = true
        controller.canStartPictureInPictureAutomaticallyFromInline = true
        // Now Playing and the lock-screen controls are the model's.
        controller.updatesNowPlayingInfoCenter = false
        controller.modalPresentationStyle = .fullScreen
        let session = VideoPlayerSession(model: model, controller: controller) { [weak self] session in
            self?.videoSessions.removeAll { $0 === session }
        }
        controller.delegate = session
        videoSessions.append(session)
        present(controller) {
            session.watch()
        }
        model.play()
    }

    // MARK: Pictures

    /// A picture from the session, full screen: zoom, share, save to Photos.
    func showImage(_ item: MediaImageItem) {
        let holder = PresentedController()
        let viewer = UIHostingController(rootView: MediaImageViewer(item: item) {
            holder.controller?.dismiss(animated: true)
        })
        holder.controller = viewer
        viewer.modalPresentationStyle = .overFullScreen
        viewer.modalTransitionStyle = .crossDissolve
        viewer.view.backgroundColor = .clear
        present(viewer)
    }

    /// An SVG, drawn by WebKit with scripts off.
    func showVector(fileURL: URL, name: String) {
        let holder = PresentedController()
        let viewer = UIHostingController(rootView: VectorImageViewer(fileURL: fileURL, name: name) {
            holder.controller?.dismiss(animated: true)
        })
        holder.controller = viewer
        viewer.modalPresentationStyle = .overFullScreen
        viewer.modalTransitionStyle = .crossDissolve
        present(viewer)
    }

    // MARK: Documents

    /// A downloaded file in Quick Look (PDF, office files, and pictures or
    /// audio as a fallback).
    func showDocument(fileURL: URL, name: String) {
        let source = QuickLookSource(item: QuickLookItem(url: fileURL, title: name))
        let controller = QLPreviewController()
        controller.dataSource = source
        source.onDismiss = { [weak self, weak source] in
            self?.previewSources.removeAll { $0 === source }
        }
        controller.delegate = source
        previewSources.append(source)
        present(controller)
    }

    // MARK: Errors

    /// Why a file couldn't be opened, as an alert.
    func showError(title: String, message: String) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert)
    }

    // MARK: Presenting

    func present(_ controller: UIViewController, completion: (() -> Void)? = nil) {
        guard let top = Self.topViewController() else { return }
        top.present(controller, animated: true, completion: completion)
    }

    /// The front-most view controller of the foreground window.
    static func topViewController() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
        var top = scene?.keyWindow?.rootViewController ?? scene?.windows.first?.rootViewController
        while let presented = top?.presentedViewController, !presented.isBeingDismissed {
            top = presented
        }
        return top
    }
}

/// The controller a SwiftUI viewer closes: UIKit presented it, so SwiftUI's
/// own dismiss doesn't reach it.
@MainActor
private final class PresentedController {
    weak var controller: UIViewController?
}

// MARK: - Video session

/// One presented video: brings the player back when Picture in Picture ends,
/// and stops the clip once the player is gone (closed with its X, swiped
/// down, or Picture in Picture closed).
@MainActor
private final class VideoPlayerSession: NSObject, AVPlayerViewControllerDelegate {
    let model: MediaPlayerModel
    let controller: AVPlayerViewController
    private let onFinish: (VideoPlayerSession) -> Void
    private var pictureInPicture = false
    private var timer: Timer?
    private var finished = false

    init(model: MediaPlayerModel, controller: AVPlayerViewController, onFinish: @escaping (VideoPlayerSession) -> Void) {
        self.model = model
        self.controller = controller
        self.onFinish = onFinish
    }

    /// AVKit doesn't say when a presented player closes, so look once a
    /// second: no window, no Picture in Picture, means it's gone.
    func watch() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.check() }
        }
    }

    private func check() {
        guard !finished else { return }
        // The system player shows only a crossed-out play button for a file
        // that won't play; close it and say why.
        if let failure = model.failure {
            let name = model.ref.name
            finish()
            if controller.presentingViewController != nil {
                controller.dismiss(animated: true) {
                    MediaPresenter.shared.showError(title: name, message: failure)
                }
            } else {
                MediaPresenter.shared.showError(title: name, message: failure)
            }
            return
        }
        guard !pictureInPicture else { return }
        if controller.viewIfLoaded?.window == nil, !controller.isBeingPresented { finish() }
    }

    private func finish() {
        guard !finished else { return }
        finished = true
        timer?.invalidate()
        timer = nil
        model.stop()
        controller.player = nil
        onFinish(self)
    }

    nonisolated func playerViewController(_ playerViewController: AVPlayerViewController,
                                          willEndFullScreenPresentationWithAnimationCoordinator coordinator: UIViewControllerTransitionCoordinator) {
        MainActor.assumeIsolated {
            coordinator.animate(alongsideTransition: nil) { [weak self] context in
                guard !context.isCancelled else { return }
                MainActor.assumeIsolated { self?.check() }
            }
        }
    }

    nonisolated func playerViewControllerShouldAutomaticallyDismissAtPictureInPictureStart(_ playerViewController: AVPlayerViewController) -> Bool {
        true
    }

    nonisolated func playerViewControllerWillStartPictureInPicture(_ playerViewController: AVPlayerViewController) {
        MainActor.assumeIsolated { pictureInPicture = true }
    }

    nonisolated func playerViewControllerDidStopPictureInPicture(_ playerViewController: AVPlayerViewController) {
        MainActor.assumeIsolated {
            pictureInPicture = false
            // Closed from the Picture in Picture window rather than brought back.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                MainActor.assumeIsolated { self?.check() }
            }
        }
    }

    nonisolated func playerViewController(_ playerViewController: AVPlayerViewController,
                                          failedToStartPictureInPictureWithError error: Error) {
        MainActor.assumeIsolated { pictureInPicture = false }
    }

    nonisolated func playerViewController(_ playerViewController: AVPlayerViewController,
                                          restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void) {
        MainActor.assumeIsolated {
            guard !finished, controller.presentingViewController == nil,
                  let top = MediaPresenter.topViewController() else {
                completionHandler(true)
                return
            }
            top.present(controller, animated: true) { completionHandler(true) }
        }
    }
}

// MARK: - Quick Look

private final class QuickLookItem: NSObject, QLPreviewItem {
    let url: URL
    let title: String

    init(url: URL, title: String) {
        self.url = url
        self.title = title
    }

    var previewItemURL: URL? { url }
    var previewItemTitle: String? { title }
}

private final class QuickLookSource: NSObject, QLPreviewControllerDataSource, QLPreviewControllerDelegate {
    let item: QuickLookItem
    var onDismiss: (() -> Void)?

    init(item: QuickLookItem) {
        self.item = item
    }

    func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }

    func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem { item }

    func previewControllerDidDismiss(_ controller: QLPreviewController) {
        onDismiss?()
    }
}
