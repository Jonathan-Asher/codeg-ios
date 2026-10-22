import XCTest
@testable import Codeg

/// How a model provider's refusal or error is recognized in an agent's text
/// (``ProviderError``), and how the transcript titles it. Mirrors codeg web's
/// `src/lib/provider-errors.test.ts`. The fixtures are synthesized in the
/// shapes Claude Code writes; none is copied from a session.
@MainActor
final class ProviderErrorTests: XCTestCase {
    private let policyMessage =
        "This request was blocked as it seems to violate the provider's terms of service on example misuse. To learn more, visit https://example.com/legal/terms."
    private let policyLink = URL(string: "https://example.com/legal/terms")

    // MARK: - A usage-policy block

    func testReadsTheClientsAPIErrorLine() {
        let error = ProviderError.detect("API Error: 400 \(policyMessage)")
        XCTAssertEqual(error?.kind, .policyBlock)
        XCTAssertEqual(error?.status, 400)
        XCTAssertEqual(error?.message, policyMessage)
        XCTAssertEqual(error?.link, policyLink)
        XCTAssertEqual(error?.raw, "API Error: 400 \(policyMessage)")
    }

    func testReadsTheMessageOutOfAJSONErrorBody() throws {
        let body = try XCTUnwrap(String(data: JSONSerialization.data(withJSONObject: [
            "type": "error",
            "error": ["type": "invalid_request_error", "message": policyMessage],
        ]), encoding: .utf8))
        let error = ProviderError.detect("API Error: 400 \(body)")
        XCTAssertEqual(error?.kind, .policyBlock)
        XCTAssertEqual(error?.message, policyMessage)
        XCTAssertEqual(error?.link, policyLink)
    }

    func testReadsATruncatedBodyFieldByField() {
        let body = #"{"type":"error","error":{"type":"permission_error","message":"\#(policyMessage)"#
        let error = ProviderError.detect("API Error: 403 \(body)")
        XCTAssertEqual(error?.kind, .policyBlock)
        XCTAssertEqual(error?.status, 403)
        XCTAssertEqual(error?.link, policyLink)
    }

    func testTakesTheNoticeBare() {
        let error = ProviderError.detect(policyMessage)
        XCTAssertEqual(error?.kind, .policyBlock)
        XCTAssertNil(error?.status)
    }

    func testSeesThroughASubagentResultsTrailersAndALeadIn() {
        let text = """
        Error: API Error: 400 \(policyMessage)
        agentId: a1b2c3 (for resuming to continue this agent's work if needed)
        <usage>total_tokens: 12
        tool_uses: 0
        duration_ms: 900</usage>
        """
        let error = ProviderError.detect(text)
        XCTAssertEqual(error?.kind, .policyBlock)
        XCTAssertEqual(error?.raw, "Error: API Error: 400 \(policyMessage)")
    }

    func testUnwrapsAToolUseError() {
        XCTAssertEqual(ProviderError.detect("<tool_use_error>API Error: 400 \(policyMessage)</tool_use_error>")?.kind,
                       .policyBlock)
    }

    // MARK: - Other provider errors

    func testTellsTheOtherKindsApart() {
        XCTAssertEqual(ProviderError.detect("API Error: 429 Too many requests")?.kind, .rateLimit)
        XCTAssertEqual(ProviderError.detect(
            "API Error: Request rejected (429) · this may be a temporary capacity issue.")?.kind, .rateLimit)
        XCTAssertEqual(ProviderError.detect(
            #"API Error: 529 {"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}"#)?.kind,
                       .overloaded)
        XCTAssertEqual(ProviderError.detect("API Error: Repeated 529 Overloaded errors")?.kind, .overloaded)
        XCTAssertEqual(ProviderError.detect("API Error: 400 messages: text content blocks must be non-empty")?.kind,
                       .invalidRequest)
        XCTAssertEqual(ProviderError.detect("API Error: 500 Internal server error")?.kind, .apiError)
        XCTAssertEqual(ProviderError.detect(
            #"{"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}"#)?.kind, .overloaded)
    }

    // MARK: - What is not one

    func testLeavesProseAndResultsAlone() {
        XCTAssertNil(ProviderError.detect("I hit an API Error: 400 while calling the endpoint, so I retried."))
        XCTAssertNil(ProviderError.detect("The log says: \(policyMessage) I could not reproduce it."))
        XCTAssertNil(ProviderError.detect("This request was blocked by the firewall rule."))
        XCTAssertNil(ProviderError.detect(#"{"message":"done","files":3}"#))
        XCTAssertNil(ProviderError.detect("API Error: 400 " + String(repeating: "explained at length. ", count: 100)))
        XCTAssertNil(ProviderError.detect(nil))
        XCTAssertNil(ProviderError.detect(""))
        XCTAssertNil(ProviderError.detect("   "))
    }

    // MARK: - Where it shows

    func testTitlesSayWhoStoppedAndWhy() throws {
        let error = try XCTUnwrap(ProviderError.detect("API Error: 400 \(policyMessage)"))
        XCTAssertEqual(ProviderErrorNotice.title(for: error, scope: .subagent),
                       "Sub-agent stopped: request blocked by the provider’s usage policy")
        XCTAssertEqual(ProviderErrorNotice.title(for: error, scope: .turn),
                       "Stopped: request blocked by the provider’s usage policy")
    }

    func testASubagentCardCarriesItAndAnOrdinaryResultDoesnt() {
        let blocked = ToolCallVM(id: "t1", rawName: "Task", kind: "", state: .done,
                                 input: #"{"description":"map the repo"}"#,
                                 output: "API Error: 400 \(policyMessage)", content: nil, isError: false)
        XCTAssertEqual(blocked.bucket, .task)
        XCTAssertEqual(blocked.providerError?.kind, .policyBlock)

        let fine = ToolCallVM(id: "t2", rawName: "Task", kind: "", state: .done,
                              input: nil, output: "Mapped 12 files.", content: nil, isError: false)
        XCTAssertNil(fine.providerError)

        let notASubagent = ToolCallVM(id: "t3", rawName: "Bash", kind: "execute", state: .error,
                                      input: nil, output: "API Error: 429 Too many requests", content: nil,
                                      isError: true)
        XCTAssertNil(notASubagent.providerError, "only a sub-agent's result is read this way")

        let running = ToolCallVM(id: "t4", rawName: "Task", kind: "", state: .running,
                                 input: nil, output: "API Error: 400 \(policyMessage)", content: nil, isError: false)
        XCTAssertNil(running.providerError, "a running sub-agent has no result yet")
    }
}
