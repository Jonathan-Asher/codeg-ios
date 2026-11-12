import Foundation
import Observation

/// The one Talk the app runs at a time, and how it starts: the models it
/// needs (the first-run download sheet), the microphone permission, then a
/// ``TalkController`` bound to the session's model. It outlives the session
/// screen, so Talk goes on with the screen locked or another screen open.
@MainActor
@Observable
final class TalkCenter {
    static let shared = TalkCenter()

    /// The Talk running now.
    private(set) var controller: TalkController?
    /// A session asked for Talk while required models are missing: its
    /// screen shows the download sheet.
    var modelsRequestedFor: Int?
    /// Why the last start didn't happen (no microphone, no conversation).
    private(set) var problem: String?

    /// What waits on the user on the selected server (the sub-agents'
    /// questions and permissions), bound by the app's model.
    @ObservationIgnored weak var pendingItems: PendingItemsStore?
    /// The start waiting for the models.
    @ObservationIgnored private var waitingStart: (() -> Void)?

    /// Talk runs for this conversation.
    func isActive(_ conversationID: Int?) -> Bool {
        guard let conversationID, let controller else { return false }
        return controller.conversationID == conversationID && controller.isActive
    }

    /// The controller of this conversation's Talk, while it runs.
    func controller(for conversationID: Int?) -> TalkController? {
        isActive(conversationID) ? controller : nil
    }

    /// Start Talk on the session `model` shows. Missing models open the
    /// download sheet first; a Talk on another session ends.
    func start(model: SessionDetailViewModel, client: CodegClient, serverProfileID: UUID?, lease: SessionLease?) {
        problem = nil
        guard let conversationID = model.conversationID else {
            problem = "Send a first message, then start Talk."
            return
        }
        if isActive(conversationID) { return }
        // The agent no longer has this session's history: nothing can be said to it.
        guard !model.isReadOnly else {
            problem = String(localized: "This session’s history is gone, so Talk can’t continue it.")
            return
        }
        guard TalkModels.missingRequired.isEmpty else {
            waitingStart = { [weak self, weak model] in
                guard let self, let model else { return }
                self.start(model: model, client: client, serverProfileID: serverProfileID, lease: lease)
            }
            modelsRequestedFor = conversationID
            return
        }
        Task { @MainActor in
            if DictationRecorder.permission != .granted {
                guard await DictationRecorder.requestPermission() else {
                    self.problem = "Allow the microphone for \(AppIdentity.displayName) in the Settings app to use Talk."
                    return
                }
            }
            self.begin(model: model, conversationID: conversationID, client: client,
                       serverProfileID: serverProfileID, lease: lease)
        }
    }

    /// The download sheet's Start: the models are in, go on with the start.
    func modelsReady() {
        modelsRequestedFor = nil
        let start = waitingStart
        waitingStart = nil
        start?()
    }

    func modelsCancelled() {
        modelsRequestedFor = nil
        waitingStart = nil
    }

    func end() {
        controller?.end()
    }

    func clearProblem() {
        problem = nil
    }

    private func begin(model: SessionDetailViewModel, conversationID: Int, client: CodegClient,
                       serverProfileID: UUID?, lease: SessionLease?) {
        if let running = controller, running.isActive { running.end() }
        let title = model.summary?.trimmedTitle
        let dependencies = TalkDependencies(
            audio: TalkAudioEngine(owner: .shared),
            system: LiveTalkSystem(folder: model.folder?.name, session: model.summary?.title),
            backend: LiveTalkBackend(client: client, conversationID: conversationID,
                                     serverProfileID: serverProfileID, lease: lease, pending: pendingItems))
        let talk = TalkController(conversationID: conversationID, title: title, port: model, dependencies: dependencies)
        talk.onEnded = { [weak self, weak talk] in
            guard let self, let talk, self.controller === talk else { return }
            // Kept a moment so the sheet can show how it ended.
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(talk.errorMessage == nil ? 0.3 : 4))
                guard let self, self.controller === talk else { return }
                self.controller = nil
            }
        }
        controller = talk
        Breadcrumbs.add("talk.start")
        talk.start()
    }

    /// A press of the Camera Control while this conversation's Talk runs;
    /// false when Talk doesn't take it.
    func cameraPress(_ action: CameraTalkPress.Action, conversationID: Int?) -> Bool {
        guard let talk = controller(for: conversationID) else { return false }
        switch action {
        case .none:
            break
        case .start:
            talk.press(true)
        case .finish, .discard(.tooShort):
            talk.press(false)
        case .discard:
            talk.cancelPress()
        }
        return true
    }
}
