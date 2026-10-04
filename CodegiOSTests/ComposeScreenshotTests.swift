import SwiftUI
import UIKit
import XCTest
@testable import Codeg

/// Renders the session's compose area (queued messages, Continue, the notice,
/// the Camera Control pill, the dictation strip and the message bar) in each
/// dictation state, in light and dark and at large text sizes, through the
/// same window capture as ``SessionListScreenshotTests``. The dictation and
/// Camera Control states are set through their screenshot hooks; nothing
/// records or opens the camera.
///
/// The files go to `$COMPOSE_SHOTS_DIR` (CI sets
/// `TEST_RUNNER_COMPOSE_SHOTS_DIR`), or to `build/compose-shots/`.
@MainActor
final class ComposeScreenshotTests: XCTestCase {
    /// A fresh id per render: a window that is torn down late reports its
    /// composer gone, which must not touch the next render's state.
    private var owner = UUID()
    private let client = CodegClient(baseURL: URL(string: "http://127.0.0.1:9")!, token: "screenshots")
    private var savedPill: (Double, Double) = (4, 8)
    private var savedExplained = false

    /// A level meter in mid-sentence.
    private static let levels: [Float] = (0..<64).map { index in
        let wave = (sin(Double(index) * 0.9) + 1) / 2
        return Float(0.18 + 0.7 * wave * (index > 4 ? 1 : 0.3))
    }

    override func setUp() async throws {
        savedPill = (CameraTalkPill.seconds, CameraTalkPill.firstSeconds)
        savedExplained = CameraTalkPrefs.pillExplained
        CameraTalkPrefs.pillExplained = true
    }

    override func tearDown() async throws {
        (CameraTalkPill.seconds, CameraTalkPill.firstSeconds) = savedPill
        CameraTalkPrefs.pillExplained = savedExplained
        reset()
    }

    private func reset() {
        DictationController.shared.showForScreenshot(.idle, owner: owner)
        CameraTalkController.shared.showForScreenshot(nil, owner: owner)
    }

    // MARK: - States

    func testIdle() throws {
        try shoot("idle", continueChip: true)
    }

    func testRecordingFromTheMic() throws {
        try shoot("recording-mic", inFlight: true) {
            DictationController.shared.showForScreenshot(
                .recording, owner: self.owner, source: .mic, elapsed: 1.4, levels: Self.levels, send: true)
        }
        // Jonathan's text size, and an accessibility size.
        try shoot("recording-mic-xxxl", styles: [.light], dynamicType: .xxxLarge, inFlight: true) {
            DictationController.shared.showForScreenshot(
                .recording, owner: self.owner, source: .mic, elapsed: 1.4, levels: Self.levels, send: true)
        }
        try shoot("recording-mic-ax-xl", styles: [.light, .dark], dynamicType: .accessibility3, inFlight: true) {
            DictationController.shared.showForScreenshot(
                .recording, owner: self.owner, source: .mic, elapsed: 1.4, levels: Self.levels, send: true,
                refine: .cleanUp, language: .english, languageDefault: .automatic)
        }
    }

    func testRecordingFromTheCameraControl() throws {
        try shoot("recording-camera") {
            CameraTalkController.shared.showForScreenshot(.running, owner: self.owner)
            DictationController.shared.showForScreenshot(
                .recording, owner: self.owner, source: .cameraControl, elapsed: 3.2, levels: Self.levels,
                send: true, refine: .translate)
        }
    }

    func testTranslating() throws {
        try shoot("translating", inFlight: true) {
            DictationController.shared.showForScreenshot(
                .refining, owner: self.owner, source: .mic, send: true, refine: .translate)
        }
        try shoot("translating-ax-xl", styles: [.light], dynamicType: .accessibility3, inFlight: true) {
            DictationController.shared.showForScreenshot(
                .refining, owner: self.owner, source: .mic, send: true, refine: .translate)
        }
    }

    func testTranscribing() throws {
        try shoot("transcribing") {
            DictationController.shared.showForScreenshot(
                .transcribing, owner: self.owner, source: .mic, send: false, refine: .cleanUp)
        }
    }

    func testError() throws {
        let error = NSError(domain: NSOSStatusErrorDomain, code: 561_017_449,
                            userInfo: [NSLocalizedDescriptionKey: "Session activation failed"])
        try shoot("error", notice: AudioErrorText(error).message("Couldn't start the microphone"))
    }

    func testQueuedMessage() throws {
        let queued = [
            SessionDetailViewModel.QueuedMessage(
                id: UUID(), text: "When that's done, run the e2e suite and send me the failures",
                attachments: [], holdUntilTurnEnd: true),
            SessionDetailViewModel.QueuedMessage(
                id: UUID(), text: "Also bump the version", attachments: [], holdUntilTurnEnd: false),
        ]
        try shoot("queued", inFlight: true, queued: queued, draft: "and check the logs")
    }

    func testCameraControlPill() throws {
        // Just turned on: the pill in full.
        try shoot("camera-pill") {
            CameraTalkController.shared.showForScreenshot(.running, owner: self.owner)
        }
        // A few seconds later: folded into the mic's badge.
        CameraTalkPill.seconds = 0
        CameraTalkPill.firstSeconds = 0
        try shoot("camera-folded", settle: 2) {
            CameraTalkController.shared.showForScreenshot(.running, owner: self.owner)
        }
        // Paused: the pill again, with the reason.
        try shoot("camera-paused") {
            CameraTalkController.shared.showForScreenshot(.interrupted("another app is using the camera"),
                                                          owner: self.owner)
        }
    }

    // MARK: - Rendering

    private func shoot(
        _ name: String,
        styles: [UIUserInterfaceStyle] = Shot.styles,
        dynamicType: DynamicTypeSize = .large,
        settle: TimeInterval = 1.2,
        inFlight: Bool = false,
        notice: String? = nil,
        continueChip: Bool = false,
        queued: [SessionDetailViewModel.QueuedMessage] = [],
        draft: String = "",
        prepare: () -> Void = {}
    ) throws {
        for style in styles {
            reset()
            owner = UUID()
            prepare()
            try Shot.capture(name, style, dynamicType: dynamicType, in: Shot.composeDirectory, settle: settle) {
                screen(inFlight: inFlight, notice: notice, continueChip: continueChip, queued: queued, draft: draft)
            }
        }
        reset()
    }

    private func screen(inFlight: Bool, notice: String?, continueChip: Bool,
                        queued: [SessionDetailViewModel.QueuedMessage], draft: String) -> some View {
        ZStack {
            CodegBackground()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text(verbatim: "Opened the product page in agent-browser and checked the cart. The tabs live in that browser.")
                        .font(Theme.Typography.messageBody)
                        .foregroundStyle(Theme.textPrimary)
                    Text(verbatim: "cd /tmp && agent-browser --cdp 9222 tab new")
                        .font(Theme.Typography.code)
                        .foregroundStyle(Theme.textSecondary)
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Theme.codeSurface, in: RoundedRectangle(cornerRadius: Theme.Radius.sm))
                }
                .padding(.horizontal, Theme.Layout.screenHMargin)
                .padding(.top, 80)
            }
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 0) {
                    if !queued.isEmpty {
                        QueuedMessagesView(items: queued, canSendNow: true, onSendNow: { _ in },
                                           onEdit: { _ in }, onRemove: { _ in })
                            .padding(.horizontal, ComposeBar.sideMargin(focused: false))
                    }
                    if continueChip {
                        ContinueChip {}
                            .padding(.bottom, 2)
                    }
                    ComposeBar(
                        text: .constant(draft),
                        isInFlight: inFlight,
                        notice: notice,
                        attachments: [],
                        canAttachMore: true,
                        onAddAttachments: { _ in },
                        onRemoveAttachment: { _ in },
                        onNotice: { _ in },
                        onSend: {},
                        onStop: {},
                        steering: ComposeSteering(canInsert: true, deliverNow: false),
                        onInsert: {},
                        onQueue: {},
                        onDismissNotice: {},
                        insertModel: ComposeInsertModel(client: client),
                        dictationContext: DictationContext(),
                        dictationRefiner: client,
                        dictationOwnerOverride: owner
                    )
                }
            }
        }
    }
}
