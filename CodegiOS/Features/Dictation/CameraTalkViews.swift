import AVFoundation
import AVKit
import SwiftUI
import UIKit

/// Hosts the `AVCaptureEventInteraction` that receives the Camera Control and
/// volume buttons. Sits behind the composer, invisible and never hit by
/// touches. The interaction is created the first time it is enabled, and
/// enabled only while this composer owns a running capture session; disabled,
/// the buttons do what they normally do.
struct CameraTalkEventHost: UIViewRepresentable {
    let isEnabled: Bool
    let onEvent: (CameraTalkPress.Phase, CameraTalkPress.Source) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> HostView {
        let view = HostView()
        view.isOpaque = false
        view.backgroundColor = .clear
        return view
    }

    func updateUIView(_ view: HostView, context: Context) {
        let coordinator = context.coordinator
        coordinator.onEvent = onEvent
        if isEnabled, coordinator.interaction == nil {
            let interaction = AVCaptureEventInteraction(
                primary: { event in coordinator.receive(event.phase, from: .primary) },
                secondary: { event in coordinator.receive(event.phase, from: .secondary) })
            view.addInteraction(interaction)
            coordinator.interaction = interaction
            CameraTalkController.log.info("Capture event interaction installed (in a window: \(view.window != nil))")
        }
        if let interaction = coordinator.interaction, interaction.isEnabled != isEnabled {
            interaction.isEnabled = isEnabled
            CameraTalkController.log.info("Capture event interaction \(isEnabled ? "enabled" : "disabled", privacy: .public)")
        }
    }

    @MainActor
    final class Coordinator {
        var interaction: AVCaptureEventInteraction?
        var onEvent: ((CameraTalkPress.Phase, CameraTalkPress.Source) -> Void)?

        func receive(_ phase: AVCaptureEventPhase, from source: CameraTalkPress.Source) {
            let mapped: CameraTalkPress.Phase
            switch phase {
            case .began: mapped = .began
            case .ended: mapped = .ended
            case .cancelled: mapped = .cancelled
            @unknown default:
                CameraTalkController.log.notice("Capture event with an unknown phase \(phase.rawValue) from \(source.rawValue, privacy: .public)")
                return
            }
            CameraTalkController.log.info("Capture event \(mapped.rawValue, privacy: .public) from \(source.rawValue, privacy: .public)")
            onEvent?(mapped, source)
        }
    }

    /// Never takes a touch: everything passes through to the composer.
    final class HostView: UIView {
        override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? { nil }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            if !interactions.isEmpty {
                CameraTalkController.log.info("Capture event host \(self.window == nil ? "left its window" : "is in a window", privacy: .public)")
            }
        }
    }
}

/// A small live view of the capture session (Settings › Voice › "Show the
/// camera in the indicator").
struct CameraTalkPreview: UIViewRepresentable {
    let session: AVCaptureSession

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.previewLayer.videoGravity = .resizeAspectFill
        view.previewLayer.session = session
        CameraTalkController.log.info("Camera preview shown")
        return view
    }

    func updateUIView(_ view: PreviewView, context: Context) {}

    static func dismantleUIView(_ view: PreviewView, coordinator: ()) {
        view.previewLayer.session = nil
        CameraTalkController.log.info("Camera preview removed")
    }

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        // swiftlint:disable:next force_cast
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }
}

/// The SF Symbols for the mode, with a fallback where the Camera Control
/// glyph doesn't exist.
enum CameraTalkSymbols {
    static let on = resolve("camera.shutter.button.fill", fallback: "camera.aperture")
    static let off = resolve("camera.shutter.button", fallback: "camera.aperture")

    private static func resolve(_ name: String, fallback: String) -> String {
        UIImage(systemName: name) != nil ? name : fallback
    }
}

/// How long the Camera Control pill stays open before it folds into the
/// mic's badge.
enum CameraTalkPill {
    /// When the mode turns on, or a session screen opens with it on.
    static var seconds: Double = 4
    /// The first time ever, with the longer explanation.
    static var firstSeconds: Double = 8
    /// The fold: the pill shrinks toward the mic while the badge appears.
    static let fold = Animation.smooth(duration: 0.45)
    static let transition: AnyTransition = .asymmetric(
        insertion: .opacity.combined(with: .move(edge: .bottom)),
        removal: .scale(scale: 0.5, anchor: .bottomTrailing).combined(with: .opacity)
    )
}

/// The folded state of the Camera Control pill: a small shutter badge on the
/// mic button. The mode is still on; the toolbar button turns it off.
enum CameraTalkBadge: Equatable {
    /// The camera is starting.
    case starting
    /// The Camera Control talks to this session.
    case running
}

struct CameraTalkBadgeView: View {
    let badge: CameraTalkBadge

    var body: some View {
        Image(systemName: CameraTalkSymbols.on)
            .font(.system(size: 8, weight: .bold))
            .foregroundStyle(Theme.onAccent)
            .frame(width: 16, height: 16)
            .background(Circle().fill(badge == .running ? Theme.accent : Theme.textTertiary))
            .overlay(Circle().strokeBorder(Theme.bg, lineWidth: 1.5))
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

/// Above the composer, in full, while there is something to say about the
/// mode: for a few seconds when it turns on or the session opens with it on
/// (with a longer explanation the first time), and while the camera is
/// paused or failed, with the reason. Otherwise it folds into the mic's
/// badge. Its ✕ turns the mode off.
struct CameraTalkIndicator: View {
    let status: CameraTalkController.Status
    let showPreview: Bool
    let session: AVCaptureSession
    /// The first time: say how it works, not just that it's on.
    var explain = false
    let onTurnOff: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: CameraTalkSymbols.on)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(tint)
            Text(verbatim: label)
                .font(.caption.weight(.medium))
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(2)
                .truncationMode(.tail)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            if showPreview, status == .running {
                CameraTalkPreview(session: session)
                    .frame(width: 22, height: 22)
                    .clipShape(Circle())
                    .overlay(Circle().strokeBorder(Theme.hairline))
                    .accessibilityHidden(true)
            }
            Button(action: onTurnOff) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Theme.textTertiary)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Turn off Camera Control to talk"))
        }
        .padding(.leading, 12)
        .padding(.trailing, 6)
        .padding(.vertical, 4)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: Theme.Radius.lg, style: .continuous))
        .hairlineBorder(Theme.Radius.lg, color: tint.opacity(status == .running ? 0.35 : 0.15))
        .accessibilityElement(children: .combine)
    }

    private var label: String {
        switch status {
        case .off, .starting: "Starting the camera for the Camera Control…"
        case .running:
            explain ? "Hold the Camera Control or a volume button, talk, and let go to send"
                : "Hold the Camera Control to talk"
        case .interrupted(let reason): "Camera Control paused: \(reason)"
        case .failed(let message): "Camera Control isn't available: \(message)"
        }
    }

    private var tint: Color {
        switch status {
        case .running: Theme.accent
        case .interrupted, .failed: Theme.warning
        case .off, .starting: Theme.textTertiary
        }
    }
}

/// The session toolbar's switch for the mode.
struct CameraTalkToolbarButton: View {
    let isOn: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: isOn ? CameraTalkSymbols.on : CameraTalkSymbols.off)
                .foregroundStyle(isOn ? Theme.accent : Theme.textSecondary)
                .contentTransition(.symbolEffect(.replace))
        }
        .accessibilityLabel(Text("Camera Control to talk"))
        .accessibilityValue(isOn ? Text("On") : Text("Off"))
        .accessibilityHint(Text("While on, hold the Camera Control to talk to this session's agent."))
    }
}
