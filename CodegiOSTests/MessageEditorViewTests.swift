import SwiftUI
import UIKit
import XCTest
@testable import Codeg

/// The message editor on the simulator: a Hebrew message edits right to
/// left (right-aligned, right-to-left base direction) and an English one
/// left to right, whatever the app's language, and the text follows a
/// change of language as it is typed. Captures go to `compose-screenshots`
/// as `message-editor-*.png`.
@MainActor
final class MessageEditorViewTests: XCTestCase {
    private static let picture = ImageData(
        data: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==",
        mimeType: "image/png", uri: nil)

    private func editor(_ text: String, images: [ImageData] = [], availability: MessageEditAvailability,
                        keepOriginal: Bool = false) -> MessageEditorSheet {
        MessageEditorSheet(
            session: MessageEditSession(id: "u3", initialText: text, images: images),
            availability: { availability },
            keepOriginal: keepOriginal,
            onSave: { _ in nil }
        )
    }

    private func host<V: View>(_ view: V) throws -> UIWindow {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = scene.screen.bounds
        window.windowLevel = .alert + 1
        window.rootViewController = UIHostingController(rootView: view)
        window.isHidden = false
        return window
    }

    private func textView(in view: UIView) -> UITextView? {
        if let text = view as? UITextView { return text }
        for sub in view.subviews { if let found = textView(in: sub) { return found } }
        return nil
    }

    private func settle(_ seconds: TimeInterval = 0.6) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    func testAHebrewMessageEditsRightToLeft() throws {
        let window = try host(editor("שלום, תוכל לבדוק את הקובץ README.md שוב?", availability: .available(.fork(forkPointID: "a2", ready: true))))
        defer { window.isHidden = true; window.rootViewController = nil }
        settle()
        let field = try XCTUnwrap(textView(in: window))
        XCTAssertEqual(field.textAlignment, .right)
        XCTAssertEqual((field.typingAttributes[.paragraphStyle] as? NSParagraphStyle)?.baseWritingDirection, .rightToLeft)
        XCTAssertEqual(field.semanticContentAttribute, .forceRightToLeft, "the caret and selection too")
        XCTAssertEqual(field.text, "שלום, תוכל לבדוק את הקובץ README.md שוב?")

        // Typed over in English: the field turns left to right.
        field.text = "Please check README.md again."
        field.delegate?.textViewDidChange?(field)
        settle(0.3)
        XCTAssertEqual(field.textAlignment, .left)
        XCTAssertEqual((field.typingAttributes[.paragraphStyle] as? NSParagraphStyle)?.baseWritingDirection, .leftToRight)
    }

    func testAnEnglishMessageEditsLeftToRight() throws {
        let window = try host(editor("Please check the README again.", availability: .available(.fork(forkPointID: "a2", ready: true))))
        defer { window.isHidden = true; window.rootViewController = nil }
        settle()
        let field = try XCTUnwrap(textView(in: window))
        XCTAssertEqual(field.textAlignment, .left)
        XCTAssertEqual((field.typingAttributes[.paragraphStyle] as? NSParagraphStyle)?.baseWritingDirection, .leftToRight)
    }

    func testScreenshots() throws {
        for style in Shot.styles {
            try Shot.capture("message-editor-hebrew", style, in: Shot.composeDirectory) {
                editor("שלום, תוכל לבדוק את הקובץ README.md שוב ולתקן את הכותרת?", images: [Self.picture],
                       availability: .available(.fork(forkPointID: "a2", ready: true)))
            }
            try Shot.capture("message-editor-busy", style, in: Shot.composeDirectory) {
                editor("Please check the README again.", availability: .blocked(.fork(forkPointID: "a2", ready: true), .busy),
                       keepOriginal: true)
            }
            try Shot.capture("message-editor-first", style, in: Shot.composeDirectory) {
                editor("Set up the project and run the tests.", availability: .available(.first))
            }
        }
    }
}
