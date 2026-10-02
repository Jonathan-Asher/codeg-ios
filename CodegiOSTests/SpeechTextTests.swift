import XCTest
@testable import Codeg

/// Markdown → read-aloud text.
final class SpeechTextTests: XCTestCase {
    func testStripsMarkdownAndSkipsCode() {
        let markdown = """
        ## Summary

        I **fixed** the `login` bug in [auth.ts](src/auth.ts) and _cleaned up_ the tests.

        ```swift
        let x = 1
        ```

        - First item
        - Second item

        See https://example.com/docs for more
        """
        let text = SpeechText.fromMarkdown(markdown)
        XCTAssertEqual(text, """
        Summary.
        I fixed the login bug in auth.ts and cleaned up the tests.
        First item.
        Second item.
        See a link for more.
        """)
    }

    func testIncludesCodeWhenAsked() {
        let text = SpeechText.fromMarkdown("Run this:\n\n```sh\nnpm test\n```", includeCode: true)
        XCTAssertEqual(text, "Run this:\nnpm test.")
    }

    func testKeepsIdentifierUnderscores() {
        XCTAssertEqual(SpeechText.inline("call snake_case_name now"), "call snake_case_name now")
        XCTAssertEqual(SpeechText.inline("a *b* c"), "a b c")
    }

    func testTablesReadAsCells() {
        let text = SpeechText.fromMarkdown("| File | Status |\n|---|:---:|\n| a.ts | done |")
        XCTAssertEqual(text, "File, Status.\na.ts, done.")
    }

    func testHebrewProse() {
        let text = SpeechText.fromMarkdown("עדכנתי את ה-**Dockerfile** ודחפתי ל-`main`")
        XCTAssertEqual(text, "עדכנתי את ה-Dockerfile ודחפתי ל-main.")
    }

    func testBlocksSkipThinkingAndToolsByDefault() {
        let blocks: [ContentBlock] = [
            .thinking("private reasoning"),
            .text("Done."),
            .toolUse(id: "t1", name: "Bash", inputPreview: "ls", meta: nil),
            .toolResult(id: "t1", outputPreview: "file.txt", isError: false),
        ]
        XCTAssertEqual(SpeechText.from(blocks: blocks), "Done.")
        let withTools = SpeechText.from(blocks: blocks, options: .init(includeCode: false, includeToolOutput: true))
        XCTAssertEqual(withTools, "Done.\n\nTool: Bash.\n\nfile.txt.")
    }

    func testScriptRuns() {
        let runs = SpeechText.scriptRuns("שלום world, מה קורה?")
        XCTAssertEqual(runs, [
            .init(text: "שלום", isHebrew: true),
            .init(text: "world,", isHebrew: false),
            .init(text: "מה קורה?", isHebrew: true),
        ])
        XCTAssertEqual(SpeechText.scriptRuns("2 tests"), [.init(text: "2 tests", isHebrew: false)])
        XCTAssertTrue(SpeechText.containsHebrew("abc ש"))
        XCTAssertFalse(SpeechText.containsHebrew("abc"))
    }
}
