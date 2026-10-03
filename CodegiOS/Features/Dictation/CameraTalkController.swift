import AVFoundation
import Observation
import UIKit
import os

/// Runs Camera Control to talk: decides from ``CameraTalkGate`` when the
/// capture session runs, and tracks its state for the indicator. One shared
/// instance, because there is one camera.
///
/// The capture session exists only so that iOS delivers the hardware buttons
/// to the app: it has no audio input, doesn't touch the app's audio session
/// (dictation's `.playAndRecord`), runs the back camera at the lowest preset
/// and frame rate, and drops every frame.
@MainActor
@Observable
final class CameraTalkController {
    static let shared = CameraTalkController()

    nonisolated static let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "codeg", category: "camera-talk")

    enum Status: Equatable {
        case off
        case starting
        case running
        /// iOS paused the camera (a call, another app, heat); it resumes by itself.
        case interrupted(String)
        case failed(String)
    }

    private(set) var status: Status = .off
    private(set) var gate = CameraTalkGate()

    /// Show a small live preview in the indicator (Settings › Voice).
    var showPreview: Bool = CameraTalkPrefs.showPreview {
        didSet { CameraTalkPrefs.showPreview = showPreview }
    }

    let capture = CameraTalkCapture()
    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    /// The device has a camera at all (not the simulator).
    static let isSupported: Bool = AVCaptureDevice.default(for: .video) != nil

    private init() {
        gate.enabled = CameraTalkPrefs.enabled
        gate.cameraAuthorized = Self.cameraAuthorized
        gate.appActive = UIApplication.shared.applicationState == .active
        capture.onEvent = { [weak self] event in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.captureChanged(event) }
            }
        }
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: UIApplication.willResignActiveNotification, object: nil,
                                            queue: .main) { [weak self] _ in
            Task { @MainActor in self?.setAppActive(false) }
        })
        observers.append(center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil,
                                            queue: .main) { [weak self] _ in
            Task { @MainActor in self?.setAppActive(false) }
        })
        observers.append(center.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil,
                                            queue: .main) { [weak self] _ in
            Task { @MainActor in self?.setAppActive(true) }
        })
    }

    var isEnabled: Bool { gate.enabled }

    /// `owner` receives the hardware buttons now.
    func isLive(owner: UUID) -> Bool {
        status == .running && gate.isLive(owner)
    }

    /// `owner` is the session screen the mode is for (shows the indicator).
    func isActiveOwner(_ owner: UUID) -> Bool {
        gate.enabled && gate.activeOwner == owner
    }

    private static let cameraOffMessage = "allow the camera for \(AppIdentity.displayName) in the Settings app"

    private static var cameraAuthorized: Bool {
        AVCaptureDevice.authorizationStatus(for: .video) == .authorized
    }

    /// Turning it on explains the camera first, once, and before iOS asks.
    var needsIntro: Bool {
        !CameraTalkPrefs.introShown || AVCaptureDevice.authorizationStatus(for: .video) == .notDetermined
    }

    // MARK: - On / off

    enum EnableResult: Equatable {
        case enabled
        case cameraDenied
        case noCamera
    }

    /// Turn the mode on: asks for the camera, and for the microphone so the
    /// first press doesn't stop at a permission prompt.
    func enable() async -> EnableResult {
        guard Self.isSupported else { return .noCamera }
        CameraTalkPrefs.introShown = true
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            break
        case .notDetermined:
            let granted = await AVCaptureDevice.requestAccess(for: .video)
            Self.log.info("Camera permission \(granted ? "granted" : "denied", privacy: .public)")
            guard granted else { return .cameraDenied }
        default:
            Self.log.info("Camera permission is denied or restricted")
            return .cameraDenied
        }
        if DictationRecorder.permission == .undetermined {
            _ = await DictationRecorder.requestPermission()
        }
        setEnabled(true)
        return .enabled
    }

    func setEnabled(_ on: Bool) {
        guard gate.enabled != on else { return }
        CameraTalkPrefs.enabled = on
        gate.enabled = on
        Self.log.info("Mode \(on ? "on" : "off", privacy: .public)")
        apply()
    }

    // MARK: - Session screens

    /// A session screen's composer reports whether it is visible, its scene
    /// active, and whether it uses the camera itself.
    func update(owner: UUID, presence: CameraTalkGate.Presence) {
        guard gate.presences[owner] != presence else { return }
        gate.update(owner, presence)
        apply()
    }

    func remove(owner: UUID) {
        guard gate.presences[owner] != nil else { return }
        gate.remove(owner)
        apply()
    }

    private func setAppActive(_ active: Bool) {
        guard gate.appActive != active else { return }
        gate.appActive = active
        apply()
    }

    // MARK: - Running the session

    private func apply() {
        gate.cameraAuthorized = Self.cameraAuthorized
        if gate.enabled, !gate.cameraAuthorized, gate.activeOwner != nil {
            // Camera access was turned off in the Settings app.
            switch status {
            case .starting, .running, .interrupted: capture.stop()
            case .off, .failed: break
            }
            if status != .failed(Self.cameraOffMessage) {
                Self.log.notice("Camera access is off; the mode can't run")
                status = .failed(Self.cameraOffMessage)
            }
            return
        }
        let run = gate.shouldRun && Self.isSupported
        switch (run, status) {
        case (true, .off), (true, .failed):
            Self.log.info("Starting the capture session (\(self.gate.summary, privacy: .public))")
            status = .starting
            capture.start()
        case (false, .starting), (false, .running), (false, .interrupted):
            Self.log.info("Stopping the capture session (\(self.gate.summary, privacy: .public))")
            status = .off
            capture.stop()
        case (false, .failed):
            status = .off
        default:
            break
        }
    }

    private func captureChanged(_ event: CameraTalkCapture.Event) {
        switch event {
        case .running:
            if gate.shouldRun {
                status = .running
            } else {
                // Turned off while it was starting.
                capture.stop()
            }
        case .stopped:
            switch status {
            case .starting, .running:
                status = gate.shouldRun ? .failed("The camera stopped.") : .off
            case .off, .interrupted, .failed:
                break
            }
        case .interrupted(let reason):
            if status != .off { status = .interrupted(reason) }
        case .interruptionEnded:
            if status != .off { status = .running }
        case .failed(let message):
            if status != .off { status = .failed(message) }
        case .mediaServicesReset:
            if status != .off {
                status = .off
                apply()
            }
        }
    }
}

/// The capture session itself, configured and run on its own serial queue.
final class CameraTalkCapture: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    enum Event: Equatable, Sendable {
        case running
        case stopped
        case interrupted(String)
        case interruptionEnded
        case failed(String)
        case mediaServicesReset
    }

    let session = AVCaptureSession()
    /// Called on the session queue or a notification queue.
    var onEvent: (@Sendable (Event) -> Void)?

    private let queue = DispatchQueue(label: "codeg.camera-talk.session", qos: .userInitiated)
    private let frameQueue = DispatchQueue(label: "codeg.camera-talk.frames", qos: .utility)
    /// Touched only on `queue`.
    private var configured = false
    private let frameLock = NSLock()
    private var awaitingFirstFrame = false
    private var observers: [NSObjectProtocol] = []
    private var log: Logger { CameraTalkController.log }

    /// The frame rate the camera is asked for; nothing looks at the frames.
    private static let framesPerSecond: Int32 = 10

    override init() {
        super.init()
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: AVCaptureSession.didStartRunningNotification, object: session,
                                            queue: nil) { [weak self] _ in
            self?.log.info("Capture session running")
            self?.emit(.running)
        })
        observers.append(center.addObserver(forName: AVCaptureSession.didStopRunningNotification, object: session,
                                            queue: nil) { [weak self] _ in
            self?.log.info("Capture session stopped")
            self?.emit(.stopped)
        })
        observers.append(center.addObserver(forName: AVCaptureSession.wasInterruptedNotification, object: session,
                                            queue: nil) { [weak self] note in
            let raw = (note.userInfo?[AVCaptureSessionInterruptionReasonKey] as? NSNumber)?.intValue
            let reason = raw.flatMap(AVCaptureSession.InterruptionReason.init(rawValue:))
            let text = Self.describe(reason)
            self?.log.notice("Capture session interrupted: \(raw ?? -1) (\(text, privacy: .public))")
            self?.emit(.interrupted(text))
        })
        observers.append(center.addObserver(forName: AVCaptureSession.interruptionEndedNotification, object: session,
                                            queue: nil) { [weak self] _ in
            self?.log.info("Capture session interruption ended")
            self?.emit(.interruptionEnded)
        })
        observers.append(center.addObserver(forName: AVCaptureSession.runtimeErrorNotification, object: session,
                                            queue: nil) { [weak self] note in
            let error = note.userInfo?[AVCaptureSessionErrorKey] as? AVError
            self?.log.error("Capture session runtime error: \(error?.code.rawValue ?? 0) \(error?.localizedDescription ?? "unknown", privacy: .public)")
            if error?.code == .mediaServicesWereReset {
                self?.emit(.mediaServicesReset)
            } else {
                self?.emit(.failed(error?.localizedDescription ?? "The camera stopped with an error."))
            }
        })
    }

    deinit {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
    }

    private func emit(_ event: Event) { onEvent?(event) }

    func start() {
        queue.async { [self] in
            if !configured {
                if let problem = configure() {
                    log.error("Capture session not configured: \(problem, privacy: .public)")
                    emit(.failed(problem))
                    return
                }
            }
            guard !session.isRunning else {
                emit(.running)
                return
            }
            frameLock.lock()
            awaitingFirstFrame = true
            frameLock.unlock()
            session.startRunning()
            if !session.isRunning, !session.isInterrupted {
                log.error("startRunning returned without the session running")
            }
        }
    }

    func stop() {
        queue.async { [self] in
            guard session.isRunning else {
                emit(.stopped)
                return
            }
            session.stopRunning()
        }
    }

    /// The minimal session: back wide camera, lowest preset, a video data
    /// output that drops every frame, no audio. Returns a problem, or nil.
    private func configure() -> String? {
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)
                ?? AVCaptureDevice.default(for: .video) else {
            return "This device has no camera."
        }
        let input: AVCaptureDeviceInput
        do {
            input = try AVCaptureDeviceInput(device: device)
        } catch {
            return error.localizedDescription
        }

        session.beginConfiguration()
        // Dictation owns the audio session (.playAndRecord while recording).
        session.automaticallyConfiguresApplicationAudioSession = false
        if session.canSetSessionPreset(.low) { session.sessionPreset = .low }
        guard session.canAddInput(input) else {
            session.commitConfiguration()
            return "The camera can't be used right now."
        }
        session.addInput(input)
        let output = AVCaptureVideoDataOutput()
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: frameQueue)
        if session.canAddOutput(output) {
            session.addOutput(output)
        } else {
            log.notice("Video data output not added; the session runs with the input only")
        }
        session.commitConfiguration()
        lowerFrameRate(device)
        configured = true
        log.info("Capture session configured: \(device.localizedName, privacy: .public), preset \(self.session.sessionPreset.rawValue, privacy: .public)")
        return nil
    }

    private func lowerFrameRate(_ device: AVCaptureDevice) {
        let fps = Double(Self.framesPerSecond)
        guard device.activeFormat.videoSupportedFrameRateRanges.contains(where: {
            $0.minFrameRate <= fps && fps <= $0.maxFrameRate
        }) else { return }
        do {
            try device.lockForConfiguration()
            let duration = CMTime(value: 1, timescale: Self.framesPerSecond)
            device.activeVideoMinFrameDuration = duration
            device.activeVideoMaxFrameDuration = duration
            device.unlockForConfiguration()
        } catch {
            log.notice("Couldn't lower the frame rate: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: AVCaptureVideoDataOutputSampleBufferDelegate

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        frameLock.lock()
        let first = awaitingFirstFrame
        awaitingFirstFrame = false
        frameLock.unlock()
        if first { log.info("First camera frame arrived") }
    }

    private static func describe(_ reason: AVCaptureSession.InterruptionReason?) -> String {
        switch reason {
        case .videoDeviceNotAvailableInBackground?: "the app is in the background"
        case .videoDeviceInUseByAnotherClient?: "another app is using the camera"
        case .videoDeviceNotAvailableWithMultipleForegroundApps?: "the camera isn't available with several apps on screen"
        case .videoDeviceNotAvailableDueToSystemPressure?: "the iPhone is too warm"
        case .audioDeviceInUseByAnotherClient?: "the audio device is in use"
        default: "the camera is in use elsewhere"
        }
    }
}
