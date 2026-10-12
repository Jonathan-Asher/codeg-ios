import SwiftUI
import XCTest
@testable import Codeg

/// Which way a message's blocks read: the word-counting rule shared with codeg
/// web, the line runs of a user message, and the direction each Markdown block
/// is laid out in.
final class TextDirectionTests: XCTestCase {
    private let rtl = LayoutDirection.rightToLeft
    private let ltr = LayoutDirection.leftToRight

    private func dir(_ text: String) -> LayoutDirection? { TextDirection.detect(text) }

    // MARK: - The rule

    func testPlainHebrewArabicAndEnglish() {
        XCTAssertEqual(dir("שלום עולם"), rtl)
        XCTAssertEqual(dir("مرحبا بالعالم"), rtl)
        XCTAssertEqual(dir("Hello world"), ltr)
        // Persian is Arabic script.
        XCTAssertEqual(dir("سلام دنیا"), rtl)
        // Niqqud are combining marks inside the word.
        XCTAssertEqual(dir("שָׁלוֹם"), rtl)
    }

    func testNoLettersHasNoDirection() {
        XCTAssertNil(dir(""))
        XCTAssertNil(dir("   \n"))
        XCTAssertNil(dir("1. 2026-10-12 — 42%"))
        XCTAssertNil(dir("⚡🏗️ ✅"))
        XCTAssertNil(dir("`src/app/page.tsx`"))
        XCTAssertNil(dir("```swift\nlet a = 1\n```"))
        XCTAssertNil(dir("https://example.com/docs"))
    }

    func testLeadingNumbersMarkdownAndEmojiCarryNoDirection() {
        XCTAssertEqual(dir("1. פטור ה de minimis של ארה\"ב"), rtl)
        XCTAssertEqual(dir("24.6.2026: השעיה בלתי מוגבלת"), rtl)
        XCTAssertEqual(dir("## ⚡ שני ממצאים קריטיים"), rtl)
        XCTAssertEqual(dir("- **€3 מכס לפריט** על חבילות"), rtl)
        XCTAssertEqual(dir("> (הערה) זה חשוב"), rtl)
        XCTAssertEqual(dir("🏗️ השערת המבנה"), rtl)
        XCTAssertEqual(dir("1. Install the CLI"), ltr)
        XCTAssertEqual(dir("**Bold** start"), ltr)
    }

    func testHebrewSentenceOpeningWithALatinTermStaysRTL() {
        XCTAssertEqual(dir(
            "EO 14324 (אוגוסט 2025) → חוק → הושהה פעמיים (פברואר ואפריל 2026), CBP כולל דואר (Federal Register 2026-12670)."
        ), rtl)
        XCTAssertEqual(dir("React Query היא ספרייה לניהול state"), rtl)
        XCTAssertEqual(dir("Claude Code עם GLM model ב-BaseTen עובד טוב"), rtl)
    }

    func testEnglishSentenceWithAFewHebrewWordsStaysLTR() {
        // 1 of 8 words is Hebrew, under the 40% share.
        XCTAssertEqual(dir("The Hebrew word for settings is הגדרות here"), ltr)
        // 2 of 5 is exactly the share: right to left.
        XCTAssertEqual(dir("Use these: שלום עולם now"), rtl)
        XCTAssertEqual(TextDirection.rtlWordShare, 0.4)
    }

    func testCodeURLsPathsAndHandlesDoNotVote() {
        XCTAssertEqual(dir("`research/international-tax-structure.md` נכתב ל-workspace"), rtl)
        XCTAssertEqual(dir("`npm run build` ואז תבדוק"), rtl)
        XCTAssertEqual(dir("https://example.com/some/long/english/path תבדוק את הקישור"), rtl)
        XCTAssertEqual(dir("www.example.com/some/page תבדוק"), rtl)
        XCTAssertEqual(dir("mailto:someone@example.com תכתוב לו"), rtl)
        XCTAssertEqual(dir("dev.team@example.com תכתוב לו"), rtl)
        XCTAssertEqual(dir("src/components/message/plain-text.tsx תבדוק"), rtl)
        XCTAssertEqual(dir("C:\\Users\\dev\\project תבדוק"), rtl)
        XCTAssertEqual(dir("@Codex @src/app.ts תריץ את הבדיקות"), rtl)
        XCTAssertEqual(dir("$deploy-skill עכשיו"), rtl)
        XCTAssertEqual(dir("```ts\nconst a = 1\nconst b = 2\n```\nזה הקוד"), rtl)
        XCTAssertEqual(dir("[@page.tsx](codeg://file/x) [Codex](codeg://agent/codex) תבדוק"), rtl)
        XCTAssertEqual(dir("[main.swift](file:///Users/dev/main.swift) עודכן"), rtl)
        // A web link's label is prose; its target is not.
        XCTAssertEqual(dir("ראה [the docs](https://example.com/docs/guide)"), rtl)
        XCTAssertEqual(dir("See [המסמך](https://example.com/he/doc) for details"), ltr)
        // A slash between Hebrew words is Hebrew prose.
        XCTAssertEqual(dir("כן/לא"), rtl)
        XCTAssertEqual(dir("Use and/or or ו/או in the contract text"), ltr)
    }

    func testQuotedMaterialDoesNotVoteUnlessItIsAllThereIs() {
        XCTAssertEqual(dir("Changed the title to 'כתב תביעה' and the subtitle to 'טיוטה ראשונה לעיון'"), ltr)
        XCTAssertEqual(dir("הכפתור \"Save all pending changes now\" לא עובד"), rtl)
        XCTAssertEqual(dir("הכפתור “Save all pending changes now” לא עובד"), rtl)
        XCTAssertEqual(dir("He said «שלום עולם רב מאוד» today"), ltr)
        XCTAssertEqual(dir("Label: „כותרת ארוכה מאוד כאן“ done"), ltr)
        XCTAssertEqual(dir("Called it ‘פרויקט חדש לגמרי ומיוחד’ in the end"), ltr)
        XCTAssertEqual(dir("\"שלום עולם\""), rtl)
        XCTAssertEqual(dir("'Hello world'"), ltr)
    }

    func testGershayimGereshAndApostrophesAreNotQuotes() {
        XCTAssertEqual(dir("ארה\"ב ועו\"ד, צ'יפס"), rtl)
        XCTAssertEqual(dir("מחר יש שיחה עם PayPal ו Fulfillment center's בסין"), rtl)
        XCTAssertEqual(dir("It's the center's 'main' office"), ltr)
    }

    func testHasRTLLetter() {
        XCTAssertTrue(TextDirection.hasRTLLetter("abc א"))
        XCTAssertTrue(TextDirection.hasRTLLetter("abc ب"))
        XCTAssertFalse(TextDirection.hasRTLLetter("abc 123"))
        XCTAssertFalse(TextDirection.hasRTLLetter(""))
    }

    // MARK: - Line runs (user messages)

    private func runs(_ text: String) -> [TextDirection.Run] { TextDirection.lineRuns(text) }

    func testSingleLanguageMessageIsOneRun() {
        let hebrew = "אני מעוניין במחקר\nהמוצרים מיוצרים בסין\n\nמחר יש שיחה"
        XCTAssertEqual(runs(hebrew), [.init(text: hebrew, direction: rtl)])
        XCTAssertEqual(runs("one\ntwo"), [.init(text: "one\ntwo", direction: ltr)])
    }

    func testSplitsWhereTheDirectionChangesAndMovesTheGapForward() {
        let text = "Fix this please:\n\nהבאג נמצא בטופס\nשורה שנייה\n42\nThanks"
        let split = runs(text)
        XCTAssertEqual(split, [
            .init(text: "Fix this please:", direction: ltr),
            .init(text: "\nהבאג נמצא בטופס\nשורה שנייה\n42", direction: rtl),
            .init(text: "Thanks", direction: ltr),
        ])
        XCTAssertEqual(split.map(\.text).joined(separator: "\n"), text)
    }

    func testLetterlessLinesJoinTheirNeighbours() {
        XCTAssertEqual(runs("123\nשלום"), [.init(text: "123\nשלום", direction: rtl)])
        XCTAssertEqual(runs("😀"), [.init(text: "😀", direction: nil)])
        XCTAssertEqual(runs(""), [.init(text: "", direction: nil)])
        XCTAssertEqual(runs("שלום\n`a.ts`\nעוד שורה"), [.init(text: "שלום\n`a.ts`\nעוד שורה", direction: rtl)])
    }

    func testRunsAlwaysJoinBackToTheInput() {
        for text in [
            "Hello\n\n\nשלום\n\nWorld\n",
            "\n\nשלום\nhello\n😀\n\nעולם",
            "a\r\nב\r\nc",
            "שלום\n\n\n",
        ] {
            XCTAssertEqual(runs(text).map(\.text).joined(separator: "\n"), text)
        }
    }

    // MARK: - Rendering decisions

    func testEachMarkdownBlockGetsItsOwnDirection() {
        let markdown = """
        # כותרת ראשית

        פסקה בעברית עם `inline code` ו-**הדגשה**.

        An English paragraph that stays left to right.

        > ציטוט בעברית

        ```ts
        const greeting = "שלום עולם"
        ```

        ---

        42
        """
        let directions = MarkdownContent.parseBlocks(markdown).map(\.direction)
        XCTAssertEqual(directions, [rtl, rtl, ltr, rtl, ltr, nil, nil])
    }

    func testListsDecideTheirSideAndItemsFollowTheirOwnText() {
        let blocks = MarkdownContent.parseBlocks("""
        - פריט ראשון
        - Second item in English
        - 42

        1. התקנה של ה-CLI
        2. Run `npm test`
        """)
        XCTAssertEqual(blocks.count, 2)
        guard case .bulletList(let bullets, let bulletDirection) = blocks[0],
              case .numberedList(let numbered, let numberedDirection) = blocks[1] else {
            return XCTFail("expected two lists, got \(blocks)")
        }
        XCTAssertEqual(bulletDirection, rtl)
        XCTAssertEqual(bullets.map(\.direction), [rtl, ltr, nil])
        XCTAssertEqual(numberedDirection, rtl)
        XCTAssertEqual(numbered.map(\.content.direction), [rtl, ltr])
        XCTAssertEqual(numbered.map(\.marker), ["1.", "2."])
    }

    func testTablesDecideTheirColumnOrderAndCellsTheirAlignment() {
        let blocks = MarkdownContent.parseBlocks("""
        | שם | Status |
        |---|---|
        | קובץ | done |
        | `a.ts` | 3 |
        """)
        guard case .table(let header, let rows, let direction) = blocks.first else {
            return XCTFail("expected a table, got \(blocks)")
        }
        XCTAssertEqual(direction, rtl)
        XCTAssertEqual(header.map(\.direction), [rtl, ltr])
        XCTAssertEqual(rows.map { $0.map(\.direction) }, [[rtl, ltr], [nil, nil]])
    }

    func testEnglishMarkdownStaysLeftToRight() {
        let blocks = MarkdownContent.parseBlocks("""
        ## Summary

        I fixed the `login` bug in [auth.ts](src/auth.ts).

        - First item
        - Second item

        | File | Status |
        |---|---|
        | a.ts | done |
        """)
        XCTAssertEqual(blocks.map(\.direction), [ltr, ltr, ltr, ltr])
    }

    func testUserMessageRunsAreParsedOnTheirOwn() {
        let split = MarkdownText.runs(from: "Fix this **please**:\n\nהבאג נמצא ב-`Form.tsx`")
        XCTAssertEqual(split.map(\.direction), [ltr, rtl])
        XCTAssertEqual(split.map { String($0.text.characters) }, ["Fix this please:", "\nהבאג נמצא ב-Form.tsx"])
        XCTAssertEqual(MarkdownText.runs(from: "Hello **world**").map(\.direction), [ltr])
    }
}
