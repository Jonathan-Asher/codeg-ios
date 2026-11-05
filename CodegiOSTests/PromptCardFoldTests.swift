import SwiftUI
import UIKit
import XCTest
@testable import Codeg

/// The pinned permission, question and plan cards fold down to a one-line
/// bar so the transcript behind them can be read (`PromptCardFold`): a new
/// request arrives unfolded, folding keeps what was chosen and typed (the
/// card never leaves the hierarchy), a focused field lets go of the keyboard,
/// the read-only replay in the transcript never folds, and a transcript at
/// the latest message stays there with the room the card gave up. Renders:
/// `prompt-fold-*.png` in `$COMPOSE_SHOTS_DIR`.
@MainActor
final class PromptCardFoldTests: XCTestCase {
    private var windows: [UIWindow] = []
    private var owner = UUID()
    private let client = CodegClient(baseURL: URL(string: "http://127.0.0.1:9")!, token: "screenshots")

    override func tearDown() async throws {
        windows.forEach {
            $0.isHidden = true
            $0.rootViewController = nil
        }
        windows = []
        DictationController.shared.showForScreenshot(.idle, owner: owner)
        CameraTalkController.shared.showForScreenshot(nil, owner: owner)
    }

    // MARK: - Fixtures

    private let database = QuestionSpec(
        id: "q0", question: "Which database should the **cache** use?", header: "Database", multiSelect: false,
        options: [QuestionOption(label: "Postgres (Recommended)", description: "Already runs in production"),
                  QuestionOption(label: "SQLite", description: "One file next to the service")])
    private let rollout = QuestionSpec(
        id: "q1", question: "Roll it out behind a flag?", header: "Rollout", multiSelect: false,
        options: [QuestionOption(label: "Yes", description: ""), QuestionOption(label: "No", description: "")])

    private let migrate = PendingPermission(requestId: "p1", toolCall: .object([
        "kind": .string("execute"), "title": .string("`npm run migrate`"),
        "rawInput": .object(["command": .string("npm run migrate"), "cwd": .string("/srv/app")]),
    ]), options: [PermissionOption(optionId: "allow", name: "Allow", kind: "allow_once"),
                  PermissionOption(optionId: "reject", name: "Reject", kind: "reject_once")])

    /// ExitPlanMode: a plan that comes as a permission.
    private let planPermission = PendingPermission(requestId: "p2", toolCall: .object([
        "kind": .string("switch_mode"), "title": .string("Ready to code?"),
        "rawInput": .object(["plan": .string("## Fold the prompt cards\n\n1. A chevron in the header")]),
    ]), options: [PermissionOption(optionId: "yes", name: "Yes", kind: "allow_once"),
                  PermissionOption(optionId: "no", name: "No, keep planning", kind: "reject_once")])

    private let approval = PendingPlanApproval(approvalId: "a1", toolCallId: "t1", planMarkdown: """
        # Fold the prompt cards

        1. A chevron at the right of the header folds the card.
        2. The bar opens it again.
        """)

    // MARK: - Fold state

    func testANewRequestArrivesUnfolded() {
        var fold = PromptFold()
        XCTAssertFalse(fold.isFolded("r1"))
        fold.fold("r1")
        XCTAssertTrue(fold.isFolded("r1"))
        XCTAssertFalse(fold.isFolded("r2"), "the next request arrives unfolded")
        fold.unfold()
        XCTAssertFalse(fold.isFolded("r1"))
        XCTAssertTrue(PromptFold(folded: "r1").isFolded("r1"))
    }

    func testASwipeMostlyDownFoldsAndMostlyUpOpens() {
        let down = CGSize(width: 6, height: 30)
        XCTAssertTrue(PromptFold.isSwipe(down, predicted: down, down: true))
        XCTAssertFalse(PromptFold.isSwipe(down, predicted: down, down: false))
        XCTAssertTrue(PromptFold.isSwipe(CGSize(width: 2, height: -14), predicted: CGSize(width: 2, height: -90),
                                         down: false), "a short flick up")
        XCTAssertFalse(PromptFold.isSwipe(CGSize(width: 40, height: 30), predicted: CGSize(width: 90, height: 70),
                                          down: true), "mostly sideways")
        XCTAssertFalse(PromptFold.isSwipe(CGSize(width: 0, height: 14), predicted: CGSize(width: 0, height: 20),
                                          down: true), "too short and too slow")
    }

    // MARK: - What the bar says

    func testThePreviewIsOneLineOfPlainWords() {
        XCTAssertEqual(PromptFoldSummary.oneLine("Which **database**\n  should the `cache` use?"),
                       "Which database should the cache use?")
        XCTAssertEqual(PromptFoldSummary.oneLine("Read [the guide](https://example.com/g) first"), "Read the guide first")
        XCTAssertEqual(PromptFoldSummary.oneLine(String(repeating: "word ", count: 100)).count,
                       PromptFoldSummary.previewLimit)
        XCTAssertEqual(PromptFoldSummary.firstLine(ofMarkdown: "\n\n# Plan: fold the cards\n\n1. A chevron"),
                       "Plan: fold the cards")
        XCTAssertEqual(PromptFoldSummary.firstLine(ofMarkdown: "---\n```swift\nlet x = 1\n```\n- [ ] **Add** the bar"),
                       "Add the bar")
        XCTAssertEqual(PromptFoldSummary.firstLine(ofMarkdown: "> 2) Keep `state`"), "Keep state")
        XCTAssertNil(PromptFoldSummary.firstLine(ofMarkdown: "  \n***\n"))
    }

    func testEachCardSaysWhatWaits() {
        let two = AskQuestionCard.foldSummary(for: PendingQuestion(questionId: "r", questions: [database, rollout]),
                                              answered: 1)
        XCTAssertEqual(two.icon, "bubble.left.and.text.bubble.right.fill")
        XCTAssertEqual(two.title, "Questions")
        XCTAssertEqual(two.preview, "Which database should the cache use?", "the first question")
        XCTAssertEqual(two.answered, 1)
        XCTAssertEqual(two.total, 2)
        XCTAssertEqual(two.hideLabel, "Hide question")
        XCTAssertEqual(two.showLabel, "Show question")
        XCTAssertEqual(AskQuestionCard.foldSummary(for: PendingQuestion(questionId: "r", questions: [rollout]),
                                                   answered: 0).title, "Question")

        let command = PermissionRequestCard.foldSummary(for: migrate)
        XCTAssertEqual(command.title, "Permission")
        XCTAssertEqual(command.preview, "npm run migrate", "the tool call's title")
        XCTAssertEqual(command.total, 0, "no count")
        XCTAssertEqual(command.hideLabel, "Hide permission request")
        XCTAssertEqual(command.showLabel, "Show permission request")

        let exitPlan = PermissionRequestCard.foldSummary(for: planPermission)
        XCTAssertEqual(exitPlan.title, "Plan")
        XCTAssertEqual(exitPlan.preview, "Fold the prompt cards", "the plan's first line")
        XCTAssertEqual(exitPlan.hideLabel, "Hide plan")
        XCTAssertEqual(exitPlan.showLabel, "Show plan")

        let plan = PlanApprovalCard.foldSummary(for: approval)
        XCTAssertEqual(plan.icon, "checklist")
        XCTAssertEqual(plan.title, "Plan")
        XCTAssertEqual(plan.preview, "Fold the prompt cards")
        XCTAssertEqual(PlanApprovalCard.foldSummary(for: PendingPlanApproval(approvalId: "a", toolCallId: "t",
                                                                             planMarkdown: " \n")).preview,
                       String(localized: "The agent didn’t include a plan."))
    }

    // MARK: - On the simulator

    func testFoldingKeepsTheAnswersChosenAndTyped() throws {
        let typed = "Redis, it already runs there"
        let driver = FoldDriver()
        let (window, card) = try host(QuestionCardHost(driver: driver, questions: [database, rollout], selections: [
            "q0": AskQuestionSelection(chosen: [], otherText: typed),
            "q1": AskQuestionSelection(chosen: ["Yes"], otherText: ""),
        ]))
        settle(0.6)
        let open = height(of: card, in: window)
        let field = try XCTUnwrap(input(showing: typed, in: window), "the Other answer as typed")

        driver.fold.fold("r1")
        settle(0.6)
        XCTAssertLessThan(height(of: card, in: window), 100, "folded to its bar")
        XCTAssertTrue(input(showing: typed, in: window) === field, "the card kept its field, hidden, while folded")

        driver.fold.unfold()
        settle(0.6)
        XCTAssertEqual(height(of: card, in: window), open, accuracy: 1, "open again, as it was")
        XCTAssertTrue(input(showing: typed, in: window) === field,
                      "the same field with the same answer: Other is still chosen and its text kept")
    }

    func testANewRequestIntoTheSameCardArrivesUnfolded() throws {
        let driver = FoldDriver()
        let (window, card) = try host(QuestionCardHost(driver: driver, questions: [database]))
        settle(0.5)
        let open = height(of: card, in: window)
        driver.fold.fold("r1")
        settle(0.5)
        XCTAssertLessThan(height(of: card, in: window), 100)
        driver.requestID = "r2"
        settle(0.5)
        XCTAssertEqual(height(of: card, in: window), open, accuracy: 1, "the next request arrives unfolded")
    }

    func testTheAnsweredRecordInTheTranscriptNeverFolds() throws {
        let driver = FoldDriver()
        driver.requestID = "result"
        driver.fold = PromptFold(folded: "result")
        let (window, card) = try host(QuestionCardHost(driver: driver, questions: [database], readOnly: true))
        settle(0.5)
        XCTAssertGreaterThan(height(of: card, in: window), 120, "the replay shows the question in full")
    }

    func testFoldingLetsGoOfTheKeyboard() throws {
        let typed = "Redis"
        let driver = FoldDriver()
        let (window, _) = try host(QuestionCardHost(driver: driver, questions: [database], selections: [
            "q0": AskQuestionSelection(chosen: [], otherText: typed),
        ]))
        window.makeKey()
        settle(0.6)
        let field = try XCTUnwrap(input(showing: typed, in: window))
        _ = field.becomeFirstResponder()
        settle(0.5)
        try XCTSkipUnless(field.isFirstResponder, "the simulator gave the field no keyboard focus")
        driver.fold.fold("r1")
        settle(0.6)
        XCTAssertFalse(field.isFirstResponder, "folding let go of the keyboard")
    }

    func testATranscriptAtTheLatestMessageStaysThereWithTheRoomTheCardGaveUp() throws {
        let driver = FoldDriver()
        var pinned: [Bool] = []
        let (window, _) = try host(TranscriptWithCard(driver: driver, turns: longTranscript(),
                                                      questions: [database, rollout],
                                                      onPinnedChange: { pinned.append($0) }))
        settle(1.5)
        let list = try XCTUnwrap(collectionView(in: window), "the transcript's list")
        let gap = gapBelowLatest(list)
        XCTAssertLessThan(gap, 80, "opened at the latest message")
        let visible = visibleHeight(list)
        let reports = pinned.count

        driver.fold.fold("r1")
        settle(1.0)
        XCTAssertGreaterThan(visibleHeight(list), visible + 150, "the transcript got the room the card gave up")
        XCTAssertEqual(gapBelowLatest(list), gap, accuracy: 4, "still at the latest message")
        XCTAssertFalse(pinned[reports...].contains(false), "never let go of the bottom")

        driver.fold.unfold()
        settle(1.0)
        XCTAssertEqual(visibleHeight(list), visible, accuracy: 4)
        XCTAssertEqual(gapBelowLatest(list), gap, accuracy: 4, "and still there with the card open again")
        XCTAssertFalse(pinned[reports...].contains(false))
    }

    // MARK: - How it looks

    /// The question card open and folded over the agent's explanation, and
    /// the three bars together, in light and dark, and the bars in Simplified
    /// Chinese: `prompt-fold-*.png` in `$COMPOSE_SHOTS_DIR`.
    func testHowTheCardsFold() throws {
        for style in Shot.styles {
            try shoot("prompt-fold-open", style) { screen(folded: false, allThree: false) }
            try shoot("prompt-fold-folded", style) { screen(folded: true, allThree: false) }
            try shoot("prompt-fold-bars", style) { screen(folded: true, allThree: true) }
        }
        try shoot("prompt-fold-bars-zh", .light) {
            screen(folded: true, allThree: true).environment(\.locale, Locale(identifier: "zh-Hans"))
        }
    }

    private func shoot<Content: View>(_ name: String, _ style: UIUserInterfaceStyle,
                                      @ViewBuilder _ content: () -> Content) throws {
        owner = UUID()
        DictationController.shared.showForScreenshot(.idle, owner: owner)
        CameraTalkController.shared.showForScreenshot(nil, owner: owner)
        try Shot.capture(name, style, in: Shot.composeDirectory, settle: 1.2, content)
    }

    private func screen(folded: Bool, allThree: Bool) -> some View {
        ZStack {
            CodegBackground()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(explanation, id: \.self) { paragraph in
                        Text(verbatim: paragraph)
                            .font(Theme.Typography.messageBody)
                            .foregroundStyle(Theme.textPrimary)
                    }
                }
                .padding(.horizontal, Theme.Layout.screenHMargin)
                .padding(.top, 80)
            }
            .defaultScrollAnchor(.bottom)
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 0) {
                    if allThree {
                        PermissionRequestCard(pending: migrate,
                                              fold: .constant(PromptFold(folded: folded ? "p1" : nil))) { _ in true }
                    }
                    AskQuestionCard(pending: PendingQuestion(questionId: "q", questions: [database, rollout]),
                                    onAnswer: { _ in true },
                                    initialSelections: ["q1": AskQuestionSelection(chosen: ["Yes"], otherText: "")],
                                    fold: .constant(PromptFold(folded: folded ? "q" : nil)))
                    if allThree {
                        PlanApprovalCard(pending: approval,
                                         fold: .constant(PromptFold(folded: folded ? "a1" : nil))) { _, _ in true }
                    }
                    ComposeBar(
                        text: .constant(""),
                        isInFlight: true,
                        notice: nil,
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

    /// What the agent wrote before asking: the text a folded card shows.
    private let explanation = [
        "I looked at why the cache misses. The session layer builds its key again on every request, so nothing it stores is ever read back.",
        "There are two ways out: keep the key on the session, which is one line but lives only as long as the session, or move the cache into a database, which takes longer and survives restarts.",
        "Which database it goes into decides the rest, so I'm asking before I change anything.",
    ]

    private func longTranscript() -> [MessageTurn] {
        let start = Date().addingTimeInterval(-3_600)
        return (0..<16).flatMap { index -> [MessageTurn] in
            let at = start.addingTimeInterval(Double(index) * 120)
            return [
                MessageTurn(id: "u-\(index)", role: .user, blocks: [.text("Step \(index): what next?")], timestamp: at),
                MessageTurn(id: "a-\(index)", role: .assistant, blocks: [.text(explanation[index % explanation.count])],
                            timestamp: at.addingTimeInterval(5), durationMs: 4_000,
                            completedAt: at.addingTimeInterval(9)),
            ]
        }
    }

    // MARK: - Hosting

    private func host<V: View>(_ view: V) throws -> (UIWindow, UIHostingController<V>) {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = scene.screen.bounds
        window.windowLevel = .alert + 1
        let controller = UIHostingController(rootView: view)
        window.rootViewController = controller
        window.isHidden = false
        windows.append(window)
        return (window, controller)
    }

    private func settle(_ seconds: TimeInterval) {
        let until = Date().addingTimeInterval(seconds)
        while Date() < until {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
    }

    /// The card's height at the window's width.
    private func height<V: View>(of card: UIHostingController<V>, in window: UIWindow) -> CGFloat {
        card.sizeThatFits(in: CGSize(width: window.bounds.width, height: 2_000)).height
    }

    /// The UIKit field showing `text` (a multi-line TextField is a UITextView).
    private func input(showing text: String, in view: UIView) -> UIView? {
        if let field = view as? UITextView, field.text == text { return field }
        if let field = view as? UITextField, field.text == text { return field }
        for subview in view.subviews {
            if let found = input(showing: text, in: subview) { return found }
        }
        return nil
    }

    private func collectionView(in view: UIView) -> UICollectionView? {
        if let list = view as? UICollectionView { return list }
        for subview in view.subviews {
            if let found = collectionView(in: subview) { return found }
        }
        return nil
    }

    /// The transcript's height between the bars and insets around it.
    private func visibleHeight(_ list: UICollectionView) -> CGFloat {
        list.bounds.height - list.adjustedContentInset.top - list.adjustedContentInset.bottom
    }

    /// How far the end of the transcript is below what shows.
    private func gapBelowLatest(_ list: UICollectionView) -> CGFloat {
        list.contentSize.height - (list.contentOffset.y + list.bounds.height - list.adjustedContentInset.bottom)
    }
}

/// Folds and unfolds a card from the test, as its chevron and its bar do.
private final class FoldDriver: ObservableObject {
    @Published var fold = PromptFold()
    @Published var requestID = "r1"
}

private struct QuestionCardHost: View {
    @ObservedObject var driver: FoldDriver
    var questions: [QuestionSpec]
    var selections: [String: AskQuestionSelection] = [:]
    var readOnly = false

    var body: some View {
        AskQuestionCard(pending: PendingQuestion(questionId: driver.requestID, questions: questions),
                        onAnswer: { _ in true }, readOnly: readOnly, initialSelections: selections,
                        fold: $driver.fold)
    }
}

/// A transcript with the question card pinned over it, as the session shows it.
private struct TranscriptWithCard: View {
    @ObservedObject var driver: FoldDriver
    let turns: [MessageTurn]
    let questions: [QuestionSpec]
    let onPinnedChange: (Bool) -> Void

    var body: some View {
        ZStack {
            CodegBackground()
            TranscriptView(turns: turns, pendingUserTurns: [], liveTurn: nil, agent: .pi, turnsVersion: 1,
                           scrollTick: 0, stickTick: 0, onPinnedChange: onPinnedChange) { EmptyView() }
                .safeAreaInset(edge: .bottom) {
                    AskQuestionCard(pending: PendingQuestion(questionId: driver.requestID, questions: questions),
                                    onAnswer: { _ in true }, fold: $driver.fold)
                }
        }
    }
}
