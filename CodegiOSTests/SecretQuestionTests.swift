import SwiftUI
import UIKit
import XCTest
@testable import Codeg

/// A question whose answer is a secret (an API key, a password): the card
/// masks it as it is typed, with no autocorrection, and no answered view
/// shows what was typed.
@MainActor
final class SecretQuestionTests: XCTestCase {
    private func question(secret: Bool, options: [String] = []) -> QuestionSpec {
        QuestionSpec(id: "q0", question: "OpenAI API key?", header: "Key", multiSelect: false,
                     options: options.map { QuestionOption(label: $0, description: "") }, isSecret: secret)
    }

    func testTheSecretMarkIsReadFromTheQuestion() throws {
        let secret = try CodegJSON.decoder.decode(QuestionSpec.self, from: Data(
            #"{"id": "q1", "question": "Token?", "header": "Token", "multi_select": false, "options": [], "is_secret": true}"#.utf8))
        XCTAssertTrue(secret.isSecret)
        let plain = try CodegJSON.decoder.decode(QuestionSpec.self, from: Data(
            #"{"id": "q2", "question": "Which?", "header": "", "multi_select": true, "options": [{"label": "A", "description": ""}]}"#.utf8))
        XCTAssertFalse(plain.isSecret, "absent unless true")
        XCTAssertTrue(plain.multiSelect)
        // The transcript's record of the call.
        let recorded = AskQuestionParse.parseInput(#"""
        {"questions": [{"question": "Token?", "header": "Token", "options": [], "is_secret": true},
                       {"question": "Which?", "header": "", "options": [{"label": "A"}], "isSecret": false}]}
        """#)
        XCTAssertEqual(recorded.map(\.isSecret), [true, false])
    }

    func testTheAnsweredViewNeverShowsATypedSecret() {
        let questions = [question(secret: true)]
        let outcome = AskOutcome(declined: false, answers: [
            AskAnswer(header: "Key", question: "OpenAI API key?", selected: ["sk-live-123"]),
        ])
        let picks = AskQuestionParse.shownPicks(outcome, questions: questions)
        XCTAssertEqual(picks, [AskQuestionParse.hiddenAnswer])
        XCTAssertFalse(picks.joined().contains("sk-live"))
        XCTAssertEqual(AskQuestionParse.answeredSelections(questions: questions, outcome: outcome)["q0"],
                       AskQuestionSelection(chosen: [], otherText: AskQuestionParse.hiddenAnswer),
                       "the expanded card gets only that there was an answer")

        // An offered option picked shows; an answer that can't be told
        // apart from the secret's is hidden too.
        let mixed = AskOutcome(declined: false, answers: [
            AskAnswer(header: "Key", question: "OpenAI API key?", selected: ["Use the saved one", "typed"]),
            AskAnswer(header: "", question: "Something else", selected: ["hunter2"]),
        ])
        XCTAssertEqual(AskQuestionParse.shownPicks(mixed, questions: [question(secret: true, options: ["Use the saved one"])]),
                       ["Use the saved one", AskQuestionParse.hiddenAnswer, AskQuestionParse.hiddenAnswer])

        // No secret: as before.
        let plain = AskOutcome(declined: false, answers: [
            AskAnswer(header: "Key", question: "OpenAI API key?", selected: ["typed"]),
        ])
        XCTAssertEqual(AskQuestionParse.shownPicks(plain, questions: [question(secret: false)]), ["typed"])
        XCTAssertEqual(AskQuestionParse.answeredSelections(questions: [question(secret: false)], outcome: plain)["q0"],
                       AskQuestionSelection(chosen: [], otherText: "typed"))
    }

    // MARK: - On the simulator

    private func host<V: View>(_ view: V) throws -> UIWindow {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = scene.screen.bounds
        window.windowLevel = .alert + 1
        window.rootViewController = UIHostingController(rootView: view)
        window.isHidden = false
        return window
    }

    private func textFields(in view: UIView) -> [UITextField] {
        ((view as? UITextField).map { [$0] } ?? []) + view.subviews.flatMap(textFields(in:))
    }

    private func textViews(in view: UIView) -> [UITextView] {
        ((view as? UITextView).map { [$0] } ?? []) + view.subviews.flatMap(textViews(in:))
    }

    func testTheCardMasksASecretAsItIsTyped() throws {
        let card = AskQuestionCard(
            pending: PendingQuestion(questionId: "r", questions: [question(secret: true)]),
            onAnswer: { _ in true },
            initialSelections: ["q0": AskQuestionSelection(chosen: [], otherText: "sk-live-123")]
        )
        let window = try host(card)
        defer { window.isHidden = true }
        RunLoop.main.run(until: Date().addingTimeInterval(0.6))
        let field = try XCTUnwrap(textFields(in: window).first)
        XCTAssertTrue(field.isSecureTextEntry, "masked")
        XCTAssertEqual(field.autocorrectionType, .no)
        XCTAssertTrue(textViews(in: window).isEmpty, "no plain field shows it")
    }
}
