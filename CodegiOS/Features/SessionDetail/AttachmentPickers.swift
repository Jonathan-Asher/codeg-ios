import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Whether this device has a usable camera. Always false on the simulator, so
/// the "+" menu hides the Camera item there.
var isCameraAvailable: Bool {
    UIImagePickerController.isSourceTypeAvailable(.camera)
}

/// A thin SwiftUI wrapper over `UIImagePickerController` in camera mode, for a
/// photo or a video. Returns a photo via `onCapture`, a recording (copied into
/// the app's own folder) via `onRecord`, then dismisses itself. Presented in a
/// full-screen cover by the compose bar.
struct CameraPicker: UIViewControllerRepresentable {
    var onCapture: (UIImage) -> Void
    var onRecord: (URL) -> Void = { _ in }
    @Environment(\.dismiss) private var dismiss

    /// The longest recording the camera offers; it is compressed to fit codeg's limit.
    static let maxRecording: TimeInterval = 5 * 60

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        let available = UIImagePickerController.availableMediaTypes(for: .camera) ?? []
        picker.mediaTypes = [UTType.image.identifier, UTType.movie.identifier].filter(available.contains)
        picker.videoQuality = .typeHigh
        picker.videoMaximumDuration = Self.maxRecording
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        private let parent: CameraPicker
        init(_ parent: CameraPicker) { self.parent = parent }

        func imagePickerController(
            _ picker: UIImagePickerController,
            didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
        ) {
            if let movie = info[.mediaURL] as? URL {
                // The picker deletes its file once it is dismissed: keep a copy.
                if let kept = try? VideoAttachmentPrep.keep(movie) { parent.onRecord(kept) }
            } else if let image = info[.originalImage] as? UIImage {
                parent.onCapture(image)
            }
            parent.dismiss()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.dismiss()
        }
    }
}
