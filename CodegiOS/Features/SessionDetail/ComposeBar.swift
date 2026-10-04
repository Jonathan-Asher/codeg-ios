import SwiftUI
import PhotosUI

/// The pinned bottom compose bar. A leading "+" sits to the left of a growing
/// multiline field; a send button (which becomes Stop while a turn streams) sits
/// on the right. Attached-image thumbnails appear above the field. The "agent is
/// working" state is shown as a node at the tail of the transcript timeline (a
/// thinking tick, a running tool, a streaming reply) — not as a status line here.
///
/// The "+" owns the attachment pickers (Photo Library / Camera / Files) because
/// `PhotosPicker` / `.fileImporter` must be hosted on a view in the bar. (The
/// agent avatar lives in the session's navigation bar, not here.)
struct ComposeBar: View {
    @Binding var text: String
    let isInFlight: Bool
    let notice: String?
    let attachments: [Attachment]
    let canAttachMore: Bool
    let onAddAttachments: ([Attachment]) -> Void
    let onRemoveAttachment: (UUID) -> Void
    let onNotice: (String) -> Void
    let onSend: () -> Void
    let onStop: () -> Void
    /// What a send can do while a turn runs (codeg fork native steering).
    var steering = ComposeSteering()
    /// Deliver the draft into the running turn ("Insert into current turn").
    var onInsert: () -> Void = {}
    /// Park the draft until the running turn ends.
    var onQueue: () -> Void = {}
    let onDismissNotice: () -> Void
    /// Backs the "+" menu's text-insert pickers (quick messages / experts / commands).
    let insertModel: ComposeInsertModel
    /// Folder and session title, passed to whisper to bias voice typing.
    var dictationContext = DictationContext()
    /// The session's codeg server, which cleans up or translates dictation.
    var dictationRefiner: (any DictationRefineTransport)? = nil
    /// The field gained or lost focus (the bar widens while typing), so the
    /// boxes above it can match its width.
    var onFocusChange: (Bool) -> Void = { _ in }
    /// Tests and previews: the id this composer's dictation runs under,
    /// shared with ``DictationController`` and ``CameraTalkController``.
    var dictationOwnerOverride: UUID? = nil

    @FocusState private var focused: Bool
    /// Bumped on each send tap to fire a light "sent" impact immediately (rather
    /// than waiting for the turn to start streaming).
    @State private var sendHaptic = 0
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var showPhotoPicker = false
    @State private var showFileImporter = false
    @State private var showCamera = false
    @State private var presentedInsert: ComposeInsertModel.Source?
    /// The field's cursor / selection, so dictated text lands at the cursor.
    @State private var selection: TextSelection?
    /// Identifies this composer's dictation to the shared controller.
    @State private var generatedOwner = UUID()
    private var dictationOwner: UUID { dictationOwnerOverride ?? generatedOwner }
    /// The Camera Control pill is open in full; otherwise it is folded into
    /// the mic's badge (unless the camera is paused or failed).
    @State private var cameraPillOpen = false
    @State private var cameraPillTask: Task<Void, Never>?
    /// The last notice this composer's dictation posted, cleared once a
    /// recording starts fine.
    @State private var dictationNotice: String?
    /// The speech model the download alert offers.
    @State private var modelToDownload: SpeechModelManifest.Model?
    /// Between `onAppear` and `onDisappear`: Camera Control to talk runs only
    /// while a session's composer is on screen.
    @State private var isOnScreen = false
    @State private var cameraPress = CameraTalkPress()
    @State private var cameraPressHaptic = 0
    @State private var cameraReleaseHaptic = 0
    @Environment(\.scenePhase) private var scenePhase

    private var dictation: DictationController { DictationController.shared }
    private var isMyDictation: Bool { dictation.owner == dictationOwner && dictation.isBusy }
    /// This composer is recording: the mic is the one control that ends it,
    /// and the send and agent-stop buttons stand aside.
    private var isRecordingHere: Bool { isMyDictation && dictation.phase == .recording }
    private var cameraTalk: CameraTalkController { CameraTalkController.shared }
    /// This composer gets the Camera Control and volume buttons now.
    private var cameraTalkLive: Bool { cameraTalk.isLive(owner: dictationOwner) }
    /// The running dictation was started by this composer's Camera Control.
    private var ownsCameraDictation: Bool {
        dictation.owner == dictationOwner && dictation.source == .cameraControl && dictation.isBusy
    }
    /// Camera Control to talk is on for this session's screen.
    private var isCameraOwner: Bool { cameraTalk.isActiveOwner(dictationOwner) }
    /// The pill in full: just turned on or opened, or something to report.
    private var showsCameraPill: Bool {
        guard isCameraOwner, !isMyDictation else { return false }
        switch cameraTalk.status {
        case .interrupted, .failed: return true
        case .off, .starting, .running: return cameraPillOpen
        }
    }
    /// The pill folded: a badge on the mic.
    private var cameraBadge: CameraTalkBadge? {
        guard isCameraOwner, !isMyDictation, !showsCameraPill else { return nil }
        return cameraTalk.status == .running ? .running : .starting
    }

    private var hasText: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    private var canSend: Bool {
        (hasText || !attachments.isEmpty) && !isInFlight
    }
    /// Something typed while a turn runs: it can be queued or inserted.
    private var hasDraftWhileBusy: Bool {
        (hasText || !attachments.isEmpty) && isInFlight
    }
    private var remainingSlots: Int {
        max(0, AttachmentPrep.maxCount - attachments.count)
    }

    var body: some View {
        withCameraTalk(composer)
    }

    private var composer: some View {
        VStack(spacing: 8) {
            if let notice {
                NoticeBanner(message: notice, onDismiss: onDismissNotice)
            }

            if !attachments.isEmpty {
                AttachmentChipsView(attachments: attachments, onRemove: onRemoveAttachment)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }

            if showsCameraPill {
                CameraTalkIndicator(
                    status: cameraTalk.status,
                    showPreview: cameraTalk.showPreview,
                    session: cameraTalk.capture.session,
                    explain: !CameraTalkPrefs.pillExplained,
                    onTurnOff: { cameraTalk.setEnabled(false) }
                )
                .transition(CameraTalkPill.transition)
            }

            if isMyDictation {
                DictationStrip(
                    phase: dictation.phase,
                    levels: dictation.levels,
                    elapsed: dictation.elapsed,
                    source: dictation.source,
                    autoSend: Binding(get: { dictation.sendThisTime }, set: { send in
                        dictation.sendThisTime = send
                        // The mic's switch is the "Send" setting; the Camera
                        // Control always sends unless switched off for this one.
                        if dictation.source == .mic { dictation.autoSend = send }
                    }),
                    // Sticky: the chip is the "After transcribing" setting.
                    refineMode: dictation.refineOffered == false || dictationRefiner == nil ? nil : Binding(
                        get: { dictation.refineThisTime },
                        set: { dictation.chooseRefineMode($0) }
                    ),
                    // This message only.
                    language: Binding(
                        get: { dictation.languageThisTime },
                        set: { dictation.chooseLanguage($0) }
                    ),
                    languageDefault: dictation.languageDefault,
                    onCancel: { dictation.cancel() }
                )
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            }

            GlassEffectContainer(spacing: 8) {
                HStack(alignment: .bottom, spacing: 8) {
                    addButton
                    TextField("Message", text: $text, selection: $selection, axis: .vertical)
                        .textInputAutocapitalization(.sentences)
                        .lineLimit(1...6)
                        // Match the transcript body so the text you type reads at
                        // the same size as the reply it produces (was `.callout`,
                        // visibly smaller than the messages).
                        .font(Theme.Typography.messageBody)
                        .foregroundStyle(Theme.textPrimary)
                        .tint(Theme.accent)
                        .focused($focused)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        // `xl` radius clamps to a capsule while the field is one
                        // line (rhyming with the round +/send buttons) and relaxes
                        // to a rounded rect as it grows — no hard switch needed.
                        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: Theme.Radius.xl, style: .continuous))
                        .hairlineBorder(Theme.Radius.xl)

                    DictationMicButton(
                        owner: dictationOwner,
                        isRecording: isRecordingHere,
                        isTranscribing: isMyDictation && (dictation.phase == .transcribing || dictation.phase == .refining),
                        isDisabled: dictation.isBusy && !isMyDictation,
                        sendOnFinish: dictation.sendThisTime,
                        cameraBadge: cameraBadge,
                        onStart: { startDictation() },
                        onStop: { dictation.stop() }
                    )

                    actionButton
                }
            }
        }
        // Idle, the bar floats as a narrower pill (36pt side margins) so it reads
        // as a compact resting affordance. Focusing the field (keyboard up) widens
        // it to the transcript's 16pt gutter, so typing gets the same width as the
        // messages it answers. The change animates with the focus transition below.
        .padding(.horizontal, Self.sideMargin(focused: focused))
        .padding(.top, 8)
        // Hosted in a bottom `safeAreaInset`. Keyboard DOWN: float a full
        // home-indicator inset (~34pt) above the edge; a small negative bottom
        // padding dips the idle bar lower while staying clear of the indicator
        // line. Keyboard UP: the inset rides just above the keyboard, so a positive
        // gap is required — the old negative pad tucked the bar *under* the
        // keyboard's top edge (part of it was obscured).
        .padding(.bottom, focused ? 8 : -10)
        .photosPicker(
            isPresented: $showPhotoPicker,
            selection: $photoItems,
            maxSelectionCount: max(1, remainingSlots),
            matching: .images,
            photoLibrary: .shared()
        )
        .onChange(of: photoItems) { _, items in handlePhotoItems(items) }
        .fullScreenCover(isPresented: $showCamera) {
            CameraPicker { image in addCaptured(image) }
                .ignoresSafeArea()
        }
        .fileImporter(
            isPresented: $showFileImporter,
            allowedContentTypes: [.image],
            allowsMultipleSelection: true
        ) { result in handleFiles(result) }
        .sheet(item: $presentedInsert) { source in
            ComposeInsertSheet(source: source, model: insertModel) { transform in
                text = transform(text)
            }
        }
        .animation(Theme.Motion.expand, value: isInFlight)
        .animation(Theme.Motion.expand, value: notice)
        .animation(Theme.Motion.expand, value: attachments)
        .animation(Theme.Motion.expand, value: isMyDictation)
        .animation(CameraTalkPill.fold, value: showsCameraPill)
        .onChange(of: isRecordingHere) { _, recording in
            guard recording else { return }
            // The microphone works now, so an earlier dictation error or
            // "No speech detected" is stale.
            if let dictationNotice, notice == dictationNotice { onDismissNotice() }
            dictationNotice = nil
        }
        .alert(
            "Download the speech model?",
            isPresented: Binding(get: { modelToDownload != nil }, set: { if !$0 { modelToDownload = nil } }),
            presenting: modelToDownload
        ) { model in
            Button("Download \(Self.megabytes(model.totalBytes))") {
                SpeechModelStores.store(for: model).start()
            }
            Button("Not Now", role: .cancel) {}
        } message: { model in
            Text("Voice typing runs on this iPhone with \(model.title), a one-time \(Self.megabytes(model.totalBytes)) download that continues in the background. Until it is ready, use the mic key on the iOS keyboard. You can manage it in Settings › Voice.")
        }
        // Width + keyboard-gap shift on focus change, kept just slightly slower
        // than the keyboard's own animation so the bar settles into place.
        .animation(.snappy(duration: 0.26), value: focused)
        .onChange(of: focused) { _, isFocused in onFocusChange(isFocused) }
        .sensoryFeedback(.impact(weight: .light, intensity: 0.7), trigger: sendHaptic)
    }

    // MARK: - Buttons

    @ViewBuilder
    private var addButton: some View {
        Menu {
            // Attach images. Disabled per-item when the attachment budget is full,
            // so the insert actions below stay reachable.
            Section("Attach") {
                Button { showPhotoPicker = true } label: {
                    Label("Photo Library", systemImage: "photo.on.rectangle")
                }
                .disabled(!canAttachMore)
                if isCameraAvailable {
                    Button { showCamera = true } label: {
                        Label("Camera", systemImage: "camera")
                    }
                    .disabled(!canAttachMore)
                }
                Button { showFileImporter = true } label: {
                    Label("Files", systemImage: "folder")
                }
                .disabled(!canAttachMore)
            }
            // Insert text: quick messages, expert mentions, slash commands.
            Section("Insert") {
                ForEach(ComposeInsertModel.Source.allCases) { source in
                    Button { presentedInsert = source } label: {
                        Label(source.title, systemImage: source.systemImage)
                    }
                }
            }
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 16, weight: .semibold))
                .frame(width: 26, height: 26)
        }
        .buttonStyle(.glass)
        .clipShape(Circle())
        .tint(Theme.textSecondary)
        .accessibilityLabel("Add or insert")
    }

    /// Send, or the agent's Stop while a turn runs. While this composer
    /// records, both stand aside (dimmed, inactive): the mic is the one
    /// control that ends the recording, so a reach for "stop" can't stop the
    /// agent by mistake.
    @ViewBuilder
    private var actionButton: some View {
        if hasDraftWhileBusy, !isRecordingHere {
            busySendButton
        }
        if isInFlight {
            Button(action: onStop) {
                Image(systemName: "stop.fill")
                    .font(.system(size: 16, weight: .bold))
                    .frame(width: 26, height: 26)
            }
            .buttonStyle(.glassProminent)
            .tint(Theme.danger)
            .clipShape(Circle())
            .disabled(isRecordingHere)
            .opacity(isRecordingHere ? 0.3 : 1)
            .transition(.scale.combined(with: .opacity))
            .accessibilityLabel("Stop the agent")
            .accessibilityHint(isRecordingHere ? Text("Finish or cancel the dictation first.") : Text(verbatim: ""))
        } else {
            Button(action: send) {
                Image(systemName: "arrow.up")
                    .font(.system(size: 16, weight: .bold))
                    .frame(width: 26, height: 26)
            }
            .buttonStyle(.glassProminent)
            .tint(Theme.accent)
            .clipShape(Circle())
            .disabled(!canSend || isRecordingHere)
            .opacity(isRecordingHere ? 0.3 : (canSend ? 1 : 0.5))
            .transition(.scale.combined(with: .opacity))
            .accessibilityLabel("Send")
        }
    }

    private func send() {
        guard canSend else { return }
        sendHaptic &+= 1
        onSend()
    }

    /// The send control while a turn runs. Held for background work: send
    /// delivers at once. With native steering: a menu to insert into the
    /// current turn or queue for its end. Otherwise: queue.
    @ViewBuilder
    private var busySendButton: some View {
        if steering.deliverNow {
            Button {
                sendHaptic &+= 1
                onInsert()
            } label: {
                Image(systemName: "arrow.up")
                    .font(.system(size: 16, weight: .bold))
                    .frame(width: 26, height: 26)
            }
            .buttonStyle(.glassProminent)
            .tint(Theme.accent)
            .clipShape(Circle())
            .transition(.scale.combined(with: .opacity))
            .accessibilityLabel("Send now")
        } else if steering.canInsert {
            Menu {
                Button {
                    sendHaptic &+= 1
                    onInsert()
                } label: {
                    Label("Insert into current turn", systemImage: "arrow.turn.down.right")
                }
                Button {
                    sendHaptic &+= 1
                    onQueue()
                } label: {
                    Label("Send when this turn ends", systemImage: "clock")
                }
            } label: {
                Image(systemName: "arrow.up")
                    .font(.system(size: 16, weight: .bold))
                    .frame(width: 26, height: 26)
            }
            .buttonStyle(.glassProminent)
            .tint(Theme.accent)
            .clipShape(Circle())
            .transition(.scale.combined(with: .opacity))
            .accessibilityLabel("Send options")
        } else {
            Button {
                sendHaptic &+= 1
                onQueue()
            } label: {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 15, weight: .bold))
                    .frame(width: 26, height: 26)
            }
            .buttonStyle(.glassProminent)
            .tint(Theme.accent)
            .clipShape(Circle())
            .transition(.scale.combined(with: .opacity))
            .accessibilityLabel("Send when this turn ends")
        }
    }

    // MARK: - Dictation

    private func startDictation(source: DictationSource = .mic, pressUptime: TimeInterval? = nil) {
        switch dictation.availability() {
        case .needsModel(let id):
            guard let model = SpeechModelCatalog.model(id: id) else {
                onNotice("Voice typing isn't available in this build.")
                return
            }
            let store = SpeechModelStores.store(for: model)
            switch store.state {
            case .downloading, .verifying:
                dictationSays("The speech model is downloading (\(Int(store.progress * 100))%). Until it is ready, use the mic key on the iOS keyboard.")
            default:
                modelToDownload = model
            }
        case .microphoneDenied:
            dictationSays("Microphone access is off for \(AppIdentity.displayName). Turn it on in the Settings app, or use the mic key on the iOS keyboard.")
        case .ready:
            guard !dictation.isBusy else {
                if source == .cameraControl, !isMyDictation || dictation.phase != .recording {
                    dictationSays("Still working on the last dictation. Try again in a moment.")
                }
                return
            }
            let owner = dictationOwner
            let postProcessor = dictationRefiner.map { TranscriptPostProcessor(transport: $0) }
            Task {
                await dictation.start(owner: owner, source: source, context: dictationContext,
                                      postProcessor: postProcessor, pressUptime: pressUptime) { outcome in
                    applyDictation(outcome)
                }
                // The button came up while the recording was still starting.
                if source == .cameraControl, !cameraPress.isHolding, dictation.owner == owner,
                   dictation.source == .cameraControl, dictation.phase == .recording {
                    CameraTalkController.log.info("Released before the recording started; discarded")
                    dictation.cancel()
                }
            }
        }
    }

    private func applyDictation(_ outcome: DictationOutcome) {
        switch outcome {
        case .text(let words, let sendNow, let notice):
            let result = DictationText.insert(words, into: text, selection: DictationText.utf16Range(of: selection, in: text))
            text = result.text
            selection = TextSelection(insertionPoint: String.Index(utf16Offset: result.cursor, in: result.text))
            if sendNow { sendAfterDictation() }
            // After the send, which clears the previous notice.
            if let notice { onNotice(notice) }
        case .nothing(let reason), .failed(let reason):
            dictationSays(reason)
        }
    }

    /// A notice from voice typing, remembered so a recording that then
    /// starts fine can clear it.
    private func dictationSays(_ message: String) {
        dictationNotice = message
        onNotice(message)
    }

    /// "Send right after transcribing": what the send button does now. The
    /// session decides between a plain send, delivering into a held turn and
    /// queueing, from its current state (this view's copy may be stale by the
    /// time a transcript arrives).
    private func sendAfterDictation() {
        guard hasText || !attachments.isEmpty else { return }
        sendHaptic &+= 1
        onSend()
    }

    // MARK: - Camera Control to talk

    /// The hardware buttons, while Camera Control to talk is on for this
    /// session (an invisible view behind the bar that never takes a touch),
    /// and the reports that decide when the camera runs.
    private func withCameraTalk<Content: View>(_ content: Content) -> some View {
        content
            .animation(Theme.Motion.expand, value: cameraTalk.isActiveOwner(dictationOwner))
            .background {
                CameraTalkEventHost(isEnabled: cameraTalkLive) { phase, source in
                    handleCameraEvent(phase, from: source)
                }
            }
            .onAppear {
                isOnScreen = true
                reportCameraPresence(visible: true)
            }
            .onDisappear {
                isOnScreen = false
                closeCameraPill()
                abandonCameraPress()
                cameraTalk.remove(owner: dictationOwner)
            }
            .onChange(of: scenePhase) { _, phase in
                if phase != .active { abandonCameraPress() }
                reportCameraPresence()
            }
            .onChange(of: showCamera) { _, _ in reportCameraPresence() }
            .onChange(of: isCameraOwner, initial: true) { _, owner in
                if owner { openCameraPill() } else { closeCameraPill() }
            }
            .onChange(of: cameraTalkLive) { _, live in
                // The camera stopped under a held button (an interruption, the
                // mode turned off): keep what was said, don't send it.
                if !live { abandonCameraPress() }
            }
            .sensoryFeedback(.impact(weight: .medium, intensity: 0.9), trigger: cameraPressHaptic)
            .sensoryFeedback(.impact(weight: .light, intensity: 0.7), trigger: cameraReleaseHaptic)
    }

    /// Open the pill in full for a few seconds (longer the first time),
    /// then fold it into the mic's badge.
    private func openCameraPill() {
        cameraPillTask?.cancel()
        let first = !CameraTalkPrefs.pillExplained
        cameraPillOpen = true
        cameraPillTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(first ? CameraTalkPill.firstSeconds : CameraTalkPill.seconds))
            guard !Task.isCancelled else { return }
            if first { CameraTalkPrefs.pillExplained = true }
            withAnimation(CameraTalkPill.fold) { cameraPillOpen = false }
        }
    }

    private func closeCameraPill() {
        cameraPillTask?.cancel()
        cameraPillTask = nil
        cameraPillOpen = false
    }

    private func reportCameraPresence(visible: Bool? = nil) {
        cameraTalk.update(owner: dictationOwner, presence: CameraTalkGate.Presence(
            visible: visible ?? isOnScreen,
            sceneActive: scenePhase == .active,
            suspended: showCamera
        ))
    }

    /// Press: record. Release: transcribe, clean up and send. A click, a
    /// cancelled press, or the other button pressed meanwhile: throw it away.
    private func handleCameraEvent(_ phase: CameraTalkPress.Phase, from source: CameraTalkPress.Source) {
        let now = ProcessInfo.processInfo.systemUptime
        let action = cameraPress.handle(phase, from: source, at: now)
        if action != .none {
            CameraTalkController.log.info("Camera Control \(phase.rawValue, privacy: .public) (\(source.rawValue, privacy: .public)) -> \(String(describing: action), privacy: .public)")
        }
        switch action {
        case .none:
            break
        case .start:
            cameraPressHaptic &+= 1
            startDictation(source: .cameraControl, pressUptime: now)
        case .finish:
            guard ownsCameraDictation, dictation.phase == .recording else { return }
            cameraReleaseHaptic &+= 1
            dictation.stop()
        case .discard(let reason):
            guard ownsCameraDictation, dictation.phase == .recording else { return }
            dictation.cancel()
            cameraReleaseHaptic &+= 1
            switch reason {
            case .tooShort: dictationSays("Hold the Camera Control while you speak, then let go to send.")
            case .otherButton: dictationSays("Recording thrown away.")
            case .cancelled: break
            }
        }
    }

    /// The press can't finish normally (the scene went inactive, the camera
    /// stopped, the screen closed): keep the words in the composer, unsent.
    private func abandonCameraPress() {
        guard cameraPress.isHolding else { return }
        cameraPress.reset()
        CameraTalkController.log.notice("Camera Control press abandoned while held")
        if ownsCameraDictation, dictation.phase == .recording {
            dictation.stop(keepUnsent: "The Camera Control was interrupted, so the message wasn't sent.")
        }
    }

    /// The bar's side margins: a narrower resting pill, the transcript's
    /// gutter while typing. The queued and inserted boxes above it use the
    /// same, so their edges line up.
    static func sideMargin(focused: Bool) -> CGFloat { focused ? 16 : 36 }

    private static func megabytes(_ bytes: Int64) -> String {
        "\(Int((Double(bytes) / 1_000_000).rounded())) MB"
    }

    // MARK: - Attachment intake

    private func handlePhotoItems(_ items: [PhotosPickerItem]) {
        guard !items.isEmpty else { return }
        let slots = remainingSlots
        let attempted = items.count
        Task { @MainActor in
            var prepared: [Attachment] = []
            for item in items.prefix(slots) {
                guard let data = try? await item.loadTransferable(type: Data.self) else { continue }
                if let attachment = await Task.detached(priority: .userInitiated, operation: {
                    AttachmentPrep.make(fromImageData: data, name: "image")
                }).value {
                    prepared.append(attachment)
                }
            }
            // Notice first so the view model's more specific size/count notice (if
            // any) wins when it also drops some during add.
            if prepared.count < attempted { onNotice("Some images couldn't be added.") }
            if !prepared.isEmpty { onAddAttachments(prepared) }
            photoItems = []
        }
    }

    private func handleFiles(_ result: Result<[URL], Error>) {
        guard case .success(let urls) = result, !urls.isEmpty else { return }
        let slots = remainingSlots
        let attempted = urls.count
        Task { @MainActor in
            var prepared: [Attachment] = []
            for url in urls.prefix(slots) {
                if let attachment = await Task.detached(priority: .userInitiated, operation: {
                    AttachmentPrep.make(fromFile: url)
                }).value {
                    prepared.append(attachment)
                }
            }
            if prepared.count < attempted { onNotice("Some images couldn't be added.") }
            if !prepared.isEmpty { onAddAttachments(prepared) }
        }
    }

    /// Camera capture is a single image and small enough to prep inline on the
    /// main actor (avoids sending a non-Sendable `UIImage` across a task boundary).
    private func addCaptured(_ image: UIImage) {
        guard remainingSlots > 0, let attachment = AttachmentPrep.make(from: image, name: "camera") else { return }
        onAddAttachments([attachment])
    }
}

/// A dismissible non-fatal notice (e.g. "a turn is already running").
private struct NoticeBanner: View {
    let message: String
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "info.circle.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.accent)
            Text(message)
                .font(.caption)
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Theme.textTertiary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous))
        .hairlineBorder(Theme.Radius.md, color: Theme.accent.opacity(0.35))
        .transition(.opacity.combined(with: .move(edge: .bottom)))
    }
}
