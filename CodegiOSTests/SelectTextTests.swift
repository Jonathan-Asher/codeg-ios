import SwiftUI
import UIKit
import XCTest
@testable import Codeg

/// Select Text: the sheet shows a message, code block or tool output in a
/// native text view that selects any part of it, rendered the way the
/// transcript renders it: headings, lists, links, code in monospace, and
/// each paragraph in its own direction.
@MainActor
final class SelectTextTests: XCTestCase {
    private func render(_ source: SelectTextSource) -> NSAttributedString {
        SelectTextRenderer.attributed(source, contentSize: .large)
    }

    private struct MissingText: Error, CustomStringConvertible {
        let needle: String
        let text: String
        var description: String { "“\(needle)” is not in “\(text)”" }
    }

    private func location(of needle: String, in text: NSAttributedString) throws -> Int {
        let found = (text.string as NSString).range(of: needle)
        guard found.location != NSNotFound else { throw MissingText(needle: needle, text: text.string) }
        return found.location
    }

    private func font(of needle: String, in text: NSAttributedString) throws -> UIFont {
        try XCTUnwrap(text.attribute(.font, at: try location(of: needle, in: text), effectiveRange: nil) as? UIFont)
    }

    private func paragraph(of needle: String, in text: NSAttributedString) throws -> NSParagraphStyle {
        try XCTUnwrap(text.attribute(.paragraphStyle, at: try location(of: needle, in: text),
                                     effectiveRange: nil) as? NSParagraphStyle)
    }

    private func has(_ trait: UIFontDescriptor.SymbolicTraits, _ font: UIFont) -> Bool {
        font.fontDescriptor.symbolicTraits.contains(trait)
    }

    private func size(_ style: UIFont.TextStyle) -> CGFloat {
        UIFont.preferredFont(forTextStyle: style,
                             compatibleWith: UITraitCollection(preferredContentSizeCategory: .large)).pointSize
    }

    /// Right to left and aligned right, or left to right and aligned left.
    private func assertDirection(_ needle: String, in text: NSAttributedString, rightToLeft: Bool,
                                 file: StaticString = #filePath, line: UInt = #line) throws {
        let style = try paragraph(of: needle, in: text)
        XCTAssertEqual(style.baseWritingDirection, rightToLeft ? .rightToLeft : .leftToRight,
                       "direction of “\(needle)”", file: file, line: line)
        XCTAssertEqual(style.alignment, rightToLeft ? .right : .left, "alignment of “\(needle)”", file: file, line: line)
    }

    // MARK: - Markdown

    func testHeadingsTakeTheTranscriptsSizesAndWeights() throws {
        let text = render(.markdown("# Release notes\n\nThe build passed.\n\n### Details\n\nMore."))
        XCTAssertEqual(text.string, "Release notes\nThe build passed.\nDetails\nMore.")
        let title = try font(of: "Release", in: text)
        XCTAssertEqual(title.pointSize, size(.title2))
        XCTAssertTrue(has(.traitBold, title))
        let minor = try font(of: "Details", in: text)
        XCTAssertEqual(minor.pointSize, size(.headline))
        let body = try font(of: "build", in: text)
        XCTAssertEqual(body.pointSize, size(.body))
        XCTAssertFalse(has(.traitBold, body))
        // A block's gap comes after its last line, not before a new block.
        XCTAssertEqual(try paragraph(of: "Release", in: text).paragraphSpacing, Theme.Typography.blockSpacing)
        XCTAssertEqual(try paragraph(of: "build", in: text).lineSpacing, Theme.Typography.messageLineSpacing)
    }

    func testListsKeepTheirMarkersAndHangTheirLines() throws {
        let text = render(.markdown("- one\n- two\n\n1. first\n2. second\n\nAfter."))
        XCTAssertEqual(text.string, "• one\n• two\n1. first\n2. second\nAfter.")
        let item = try paragraph(of: "one", in: text)
        XCTAssertGreaterThan(item.headIndent, 0, "wrapped lines line up with the item's text")
        XCTAssertEqual(item.firstLineHeadIndent, 0)
        XCTAssertEqual(item.paragraphSpacing, Theme.Typography.listItemSpacing)
        XCTAssertEqual(try paragraph(of: "two", in: text).paragraphSpacing, Theme.Typography.blockSpacing,
                       "the list's last item is followed by a block's gap")
        let light = UITraitCollection(userInterfaceStyle: .light)
        let marker = try XCTUnwrap(text.attribute(.foregroundColor, at: try location(of: "•", in: text),
                                                  effectiveRange: nil) as? UIColor)
        XCTAssertEqual(marker.resolvedColor(with: light), UIColor(Theme.textTertiary).resolvedColor(with: light),
                       "markers are dimmer than the text, as in the transcript")
    }

    func testLinksAreLinks() throws {
        let text = render(.markdown("See [the docs](https://example.com/docs) now."))
        XCTAssertEqual(text.string, "See the docs now.")
        XCTAssertEqual(text.attribute(.link, at: try location(of: "the docs", in: text), effectiveRange: nil) as? URL,
                       URL(string: "https://example.com/docs"))
        XCTAssertNil(text.attribute(.link, at: try location(of: "See", in: text), effectiveRange: nil))
        XCTAssertNil(text.attribute(.link, at: try location(of: " now", in: text), effectiveRange: nil))
    }

    func testInlineAndFencedCodeAreMonospaced() throws {
        let text = render(.markdown("Run `make test` first.\n\n```swift\nlet x = 1\nlet y = 2\n```\n\nDone."))
        XCTAssertEqual(text.string, "Run make test first.\nlet x = 1\nlet y = 2\nDone.")
        XCTAssertTrue(has(.traitMonoSpace, try font(of: "make test", in: text)))
        XCTAssertEqual(try font(of: "make test", in: text).pointSize, size(.body))
        XCTAssertFalse(has(.traitMonoSpace, try font(of: "Run", in: text)))
        let code = try font(of: "let x", in: text)
        XCTAssertTrue(has(.traitMonoSpace, code))
        XCTAssertEqual(code.pointSize, 13)
        // The code's lines are one block: the gap comes after the last.
        XCTAssertEqual(try paragraph(of: "let x", in: text).paragraphSpacing, 0)
        XCTAssertEqual(try paragraph(of: "let y", in: text).paragraphSpacing, Theme.Typography.blockSpacing)
    }

    func testBoldItalicAndStrikethrough() throws {
        let text = render(.markdown("**bold** and *slanted* and ~~gone~~"))
        XCTAssertEqual(text.string, "bold and slanted and gone")
        XCTAssertTrue(has(.traitBold, try font(of: "bold", in: text)))
        XCTAssertTrue(has(.traitItalic, try font(of: "slanted", in: text)))
        XCTAssertNotNil(text.attribute(.strikethroughStyle, at: try location(of: "gone", in: text), effectiveRange: nil))
        XCTAssertFalse(has(.traitBold, try font(of: " and", in: text)))
    }

    // MARK: - Direction

    func testEachParagraphTakesItsOwnDirection() throws {
        let text = render(.markdown("""
            The plan is ready.

            התוכנית מוכנה, אפשר לאשר אותה.

            - פריט ראשון ברשימה
            - second item

            ## כותרת בעברית
            """))
        try assertDirection("The plan", in: text, rightToLeft: false)
        try assertDirection("התוכנית", in: text, rightToLeft: true)
        try assertDirection("פריט", in: text, rightToLeft: true)
        try assertDirection("second item", in: text, rightToLeft: false)
        try assertDirection("כותרת", in: text, rightToLeft: true)
    }

    func testCodeInARightToLeftReplyStaysLeftToRight() throws {
        let text = render(.markdown("הנה הפקודה להרצה:\n\n```\nnpm run build\n```"))
        try assertDirection("הנה", in: text, rightToLeft: true)
        try assertDirection("npm run", in: text, rightToLeft: false)
    }

    func testAHebrewSentenceOpeningWithALatinTermIsRightToLeft() throws {
        let text = render(.markdown("TestFlight מעלה את הגרסה החדשה לבדיקה הלילה"))
        try assertDirection("TestFlight", in: text, rightToLeft: true)
    }

    // MARK: - Your message, code

    func testYourMessageIsInlineMarkdownInRunsOfLines() throws {
        let text = render(.message("Hello there\nשלום לכולם\nמה שלומכם?\n- keep the dash\n**done**"))
        XCTAssertEqual(text.string, "Hello there\nשלום לכולם\nמה שלומכם?\n- keep the dash\ndone",
                       "no lists in your messages, as on the card")
        try assertDirection("Hello", in: text, rightToLeft: false)
        try assertDirection("שלום", in: text, rightToLeft: true)
        try assertDirection("מה", in: text, rightToLeft: true)
        try assertDirection("keep the dash", in: text, rightToLeft: false)
        XCTAssertTrue(has(.traitBold, try font(of: "done", in: text)))
    }

    func testCodeIsVerbatim() throws {
        let text = render(.code("let a = \"**not bold**\" // שלום\n\n"))
        XCTAssertEqual(text.string, "let a = \"**not bold**\" // שלום", "no Markdown, no trailing line breaks")
        XCTAssertTrue(has(.traitMonoSpace, try font(of: "not bold", in: text)))
        try assertDirection("let a", in: text, rightToLeft: false)
    }

    func testCopyIsTheTextAsItCame() {
        XCTAssertEqual(SelectTextSource.markdown("**a** [b](https://x.y)").raw, "**a** [b](https://x.y)")
        XCTAssertEqual(SelectTextSource.message("שלום").raw, "שלום")
        XCTAssertEqual(SelectTextSource.code("x\n").raw, "x\n")
    }

    func testADiffReadsAsTextWithItsSigns() {
        let rows = [
            DiffRow(kind: .context, oldLine: 1, newLine: 1, text: "let a = 1"),
            DiffRow(kind: .deleted, oldLine: 2, newLine: nil, text: "let b = 2"),
            DiffRow(kind: .added, oldLine: nil, newLine: 2, text: "let b = 3"),
        ]
        let second = [DiffRow(kind: .added, oldLine: nil, newLine: 40, text: "// end")]
        let file = DiffFile(path: "a.swift", oldPath: nil, mode: .modified, additions: 2, deletions: 1,
                            hunks: [DiffHunk(header: "@@ -1,2 +1,2 @@", rows: rows),
                                    DiffHunk(header: "@@ -39,0 +40,1 @@", rows: second)])
        XCTAssertEqual(file.selectableText, " let a = 1\n-let b = 2\n+let b = 3\n@@ -39,0 +40,1 @@\n+// end")
        let new = DiffFile(path: "b.swift", oldPath: nil, mode: .added, additions: 1, deletions: 0,
                           hunks: [DiffHunk(header: nil, rows: [DiffRow(kind: .added, oldLine: nil, newLine: 1,
                                                                         text: "print(1)")])])
        XCTAssertEqual(new.selectableText, "print(1)", "a new file is its lines")
    }

    // MARK: - The sheet

    func testALinkTappedInTheSheetOpensOnceTheSheetHasClosed() throws {
        var opened: [URL] = []
        let openURL = OpenURLAction { url in
            opened.append(url)
            return .handled
        }
        let presentation = SelectTextPresentation()
        let action = SelectTextAction(presentation: presentation)
        action(.markdown("[docs](https://example.com)"), openURL: openURL)
        XCTAssertEqual(presentation.shown?.source, .markdown("[docs](https://example.com)"))

        let url = try XCTUnwrap(URL(string: "https://example.com"))
        presentation.linkTapped(url)
        XCTAssertNil(presentation.shown, "the sheet closes")
        XCTAssertEqual(opened, [], "nothing opens behind the sheet")
        presentation.dismissed()
        XCTAssertEqual(opened, [url], "with the action where the text was")
        presentation.dismissed()
        XCTAssertEqual(opened, [url], "once")
    }

    func testClosingTheSheetOpensNothing() {
        var opened = 0
        let presentation = SelectTextPresentation()
        presentation.open(.code("x"), openURL: OpenURLAction { _ in
            opened += 1
            return .handled
        })
        presentation.shown = nil
        presentation.dismissed()
        XCTAssertEqual(opened, 0)
    }

    /// The sheet with a reply that mixes English and Hebrew paragraphs, a
    /// list, code and a quote, part of it selected across both directions.
    /// Written to `$COMPOSE_SHOTS_DIR` as `select-text-sheet-*.png`.
    func testTheSheetScreenshot() throws {
        let reply = """
            ## Release notes

            The build passed on **iOS 26**, and the `TestFlight` upload is ready to [install](https://testflight.apple.com).

            הגרסה החדשה מוכנה לבדיקה. אפשר להתקין אותה מ-TestFlight ולבדוק את **בחירת הטקסט** בכל הודעה.

            - English item with some more words so that it wraps onto a second line
            - פריט בעברית עם `code` ועוד כמה מילים כדי שהשורה תישבר לשתיים

            1. ראשון
            2. שני

            > A quote in English.

            ```swift
            let range = textView.selectedRange
            ```
            """
        for style in [UIUserInterfaceStyle.light, .dark] {
            try SessionListScreenshotTests.capture(
                "select-text-sheet", style, in: SessionListScreenshotTests.composeDirectory,
                prepare: { window in
                    guard let textView = Self.textView(in: window) else {
                        return XCTFail("the sheet has no text view")
                    }
                    let string = textView.attributedText.string as NSString
                    let start = string.range(of: "passed").location
                    let end = string.range(of: "לבדיקה").location
                    XCTAssertNotEqual(start, NSNotFound)
                    XCTAssertNotEqual(end, NSNotFound)
                    XCTAssertFalse(textView.isEditable)
                    XCTAssertTrue(textView.isSelectable)
                    window.makeKey()
                    textView.becomeFirstResponder()
                    textView.selectedRange = NSRange(location: start, length: end + "לבדיקה".utf16.count - start)
                }
            ) {
                SelectTextSheet(source: .markdown(reply))
            }
        }
    }

    private static func textView(in view: UIView) -> UITextView? {
        if let textView = view as? UITextView { return textView }
        for subview in view.subviews {
            if let found = textView(in: subview) { return found }
        }
        return nil
    }
}
