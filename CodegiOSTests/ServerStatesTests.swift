import XCTest
@testable import Codeg

/// Three states the codeg fork's server gained: a question that ended without
/// an answer ("This question expired"), a sub-agent a usage limit paused
/// ("Paused · usage limit"), and that sub-agent's result delivered to its
/// parent as a message (a compact card). Mirrors codeg web's
/// `ask-question.test.ts` and `delegation-status-badge.test.tsx`, and the
/// backend's `limit_delivery` message format.
@MainActor
final class ServerStatesTests: XCTestCase {

    // MARK: - A question that expired

    private let askInput = #"{"questions":[{"header":"Deploy","question":"Ship it now?","multiSelect":false,"options":[{"label":"Yes","description":""},{"label":"No","description":""}]}]}"#

    private func askVM(state: ToolCallState, output: String? = nil, isError: Bool = false,
                       inRunningTurn: Bool = false) -> ToolCallVM {
        var vm = ToolCallVM(id: "toolu_ask", rawName: "mcp__codeg__ask_user_question", kind: "", state: state,
                            input: askInput, output: output, content: nil, isError: isError)
        vm.inRunningTurn = inRunningTurn
        return vm
    }

    func testTheRecordStatesFollowCodegWeb() {
        // A call rejected for its arguments never was a question: an error.
        XCTAssertEqual(AskQuestionParse.recordState(output: nil, errorText: "ask_user_question requires at least one question",
                                                    answered: false, running: false), .error)
        XCTAssertEqual(AskQuestionParse.recordState(output: nil, errorText: "questions[0].options needs 2 to 4 entries",
                                                    answered: false, running: false), .error)
        XCTAssertEqual(AskQuestionParse.recordState(output: nil, errorText: "MCP error -32602: Invalid params",
                                                    answered: false, running: true), .error)
        // Any other error ended the call before an answer.
        XCTAssertEqual(AskQuestionParse.recordState(output: nil, errorText: "MCP error -32001: Request timed out",
                                                    answered: false, running: false), .expired)
        XCTAssertEqual(AskQuestionParse.recordState(output: nil, errorText: "The turn was cancelled",
                                                    answered: false, running: true), .expired)
        // An answer; no result while the turn runs; no result after it ended.
        XCTAssertEqual(AskQuestionParse.recordState(output: "{}", errorText: nil, answered: true, running: true), .answered)
        XCTAssertEqual(AskQuestionParse.recordState(output: nil, errorText: nil, answered: false, running: true), .inFlight)
        XCTAssertEqual(AskQuestionParse.recordState(output: " ", errorText: " ", answered: false, running: false), .expired)
        // A result that didn't parse is still a result.
        XCTAssertEqual(AskQuestionParse.recordState(output: "Done.", errorText: nil, answered: false, running: false), .answered)
    }

    func testACallWithoutAResultWaitsOnlyWhileItsLiveTurnRuns() {
        XCTAssertEqual(AskQuestionParse.recordState(of: askVM(state: .running, inRunningTurn: true)), .inFlight)
        // A transcript's call with no result: its turn has ended.
        XCTAssertEqual(AskQuestionParse.recordState(of: askVM(state: .running)), .expired)
        // An error result expires the question, unless the call was malformed.
        XCTAssertEqual(AskQuestionParse.recordState(of: askVM(state: .error, output: "Tool execution was interrupted",
                                                              isError: true)), .expired)
        XCTAssertEqual(AskQuestionParse.recordState(of: askVM(state: .error, output: "ask_user_question supports at most 4 questions",
                                                              isError: true)), .error)
        let answer = #"{"answers":[{"header":"Deploy","question":"Ship it now?","selected":["Yes"]}],"declined":false}"#
        XCTAssertEqual(AskQuestionParse.recordState(of: askVM(state: .done, output: answer)), .answered)
    }

    func testAnUnansweredQuestionInTheTranscriptExpiredAndItsMarkerIsQuiet() throws {
        let prompt = MessageTurn(id: "u-1", role: .user, blocks: [.text("Deploy when ready")], timestamp: Date())
        let reply = MessageTurn(id: "a-1", role: .assistant, blocks: [
            .toolUse(id: "toolu_ask", name: "mcp__codeg__ask_user_question", inputPreview: askInput, meta: nil),
        ], timestamp: Date())
        let nodes = TranscriptTimeline.buildPersisted(turns: [prompt, reply], pending: [], agent: .claudeCode,
                                                      suppressInFlight: false)
        let node = try XCTUnwrap(nodes.first { if case .tool = $0.content { return true } else { return false } })
        guard case .tool(let vm) = node.content else { return XCTFail("not a tool node") }
        XCTAssertEqual(vm.companion, .askQuestion)
        XCTAssertEqual(AskQuestionParse.recordState(of: vm), .expired)
        guard case .muted = node.marker else { return XCTFail("an expired question's marker must not pulse") }
    }

    func testTheLiveTurnsQuestionWaitsUntilTheTurnEnds() throws {
        let live = LiveTurn()
        live.upsertToolCall(id: "toolu_ask", title: "ask_user_question", kind: "other", status: "in_progress",
                            rawInput: askInput, rawOutput: nil, content: nil)
        func askNode() throws -> TimelineNode {
            try XCTUnwrap(TranscriptTimeline.buildLive(live, agent: .claudeCode).first {
                if case .tool(let vm) = $0.content { return vm.companion == .askQuestion } else { return false }
            })
        }
        guard case .tool(let waiting) = try askNode().content else { return XCTFail("not a tool node") }
        XCTAssertEqual(AskQuestionParse.recordState(of: waiting), .inFlight)
        guard case .tool(_, .running) = try askNode().marker else { return XCTFail("a waiting question pulses") }

        // The turn was cancelled with the question still open.
        live.isStreaming = false
        guard case .tool(let ended) = try askNode().content else { return XCTFail("not a tool node") }
        XCTAssertEqual(AskQuestionParse.recordState(of: ended), .expired)
        guard case .muted = try askNode().marker else { return XCTFail("an expired question's marker must not pulse") }
    }

    // MARK: - A sub-agent paused by a usage limit

    private func delegationMeta(_ status: String, code: String? = nil) -> AnyJSON {
        var inner: [String: AnyJSON] = ["status": .string(status), "child_conversation_id": .number(9)]
        if let code { inner["error_code"] = .string(code) }
        return .object(["codeg.delegation": .object(inner)])
    }

    func testTheDelegateCardReadsPausedUntilItsChildCompletes() {
        // codeg records a limit-paused child as failed, with the paused code.
        let paused = DelegationModel.parseDelegationMeta(delegationMeta("failed", code: "paused_usage_limit"))
        XCTAssertEqual(paused?.status, .paused)
        XCTAssertEqual(DelegationModel.resolveStatus(parsedMeta: paused, toolOutput: nil, state: .done, hasError: false),
                       .paused)
        // The continued child finished.
        let done = DelegationModel.parseDelegationMeta(delegationMeta("completed"))
        XCTAssertEqual(DelegationModel.resolveStatus(parsedMeta: done, toolOutput: nil, state: .done, hasError: false), .ok)
        // Any other failure still fails.
        XCTAssertEqual(DelegationModel.parseDelegationMeta(delegationMeta("failed", code: "child_refusal"))?.status, .err)
    }

    func testAPausedReportFromTheDelegateCallReadsPaused() {
        let output = #"{"structuredContent":{"task_id":"t-1","status":"running","error_code":"paused_usage_limit","child_conversation_id":9,"message":"Paused by a usage limit (not a failure)."},"content":[{"type":"text","text":"Paused by a usage limit (not a failure)."}]}"#
        let parsed = DelegationModel.parseToolOutput(output)
        XCTAssertEqual(DelegationModel.resolveStatus(parsedMeta: nil, toolOutput: parsed, state: .done, hasError: false),
                       .paused)
    }

    private func statusPoll(_ id: String, report: String) -> ToolCallVM {
        ToolCallVM(id: id, rawName: "mcp__codeg__get_delegation_status", kind: "", state: .done,
                   input: #"{"task_ids":["t-1"]}"#, output: report, content: nil, isError: false)
    }

    func testAStatusReportReadsPausedUntilALaterPollCompletes() {
        let pausedReport = #"{"structuredContent":{"task_id":"t-1","status":"running","error_code":"paused_usage_limit","message":"Paused by a usage limit (not a failure)."},"content":[{"type":"text","text":"Paused by a usage limit (not a failure)."}]}"#
        let doneReport = #"{"structuredContent":{"task_id":"t-1","status":"completed","text":"All done."},"content":[{"type":"text","text":"All done."}]}"#

        let paused = DelegationModel.buildTaskRows([statusPoll("p1", report: pausedReport)])
        XCTAssertEqual(paused.map(\.badge.status), [.paused])

        let later = DelegationModel.buildTaskRows([statusPoll("p1", report: pausedReport),
                                                   statusPoll("p2", report: doneReport)])
        XCTAssertEqual(later.map(\.badge.status), [.ok])
    }

    func testTheBadgeShowsAnErrorWithThePausedCodeAsPaused() {
        XCTAssertEqual(CompanionStatusBadge.shown(.err, errorCode: "paused_usage_limit"), .paused)
        XCTAssertEqual(CompanionStatusBadge.shown(.err, errorCode: "timeout"), .err)
        XCTAssertEqual(CompanionStatusBadge.shown(.ok, errorCode: nil), .ok)
    }

    // MARK: - A delivered sub-agent result

    /// The message codeg's `limit_delivery::delivery_prompt` sends the parent.
    private func delivery(status: String = "completed", code: String? = nil, body: String = "The answer is 42.") -> String {
        let codeAttribute = code.map { #" error_code="\#($0)""# } ?? ""
        return """
        A task you delegated earlier has finished. A usage limit had paused its sub-agent and codeg continued it; \
        this is its final result, delivered once. Carry on with it — do not delegate, resume or retry this task.

        <delegation-result task_id="t-compute" agent="claude_code" status="\(status)"\(codeAttribute) child_session="42">
        \(body)
        </delegation-result>
        """
    }

    func testReadsTheDeliveredResult() throws {
        let result = try XCTUnwrap(DelegatedResult.parse(delivery()))
        XCTAssertEqual(result.taskId, "t-compute")
        XCTAssertEqual(result.agent, .claudeCode)
        XCTAssertEqual(result.status, "completed")
        XCTAssertNil(result.errorCode)
        XCTAssertEqual(result.childConversationId, 42)
        XCTAssertEqual(result.body, "The answer is 42.")
        XCTAssertEqual(result.preview, "The answer is 42.")
        XCTAssertEqual(result.badge.status, .ok)
        XCTAssertFalse(result.isFailure)
    }

    func testReadsAFailedResultsCode() throws {
        let result = try XCTUnwrap(DelegatedResult.parse(delivery(status: "failed", code: "child_refusal",
                                                                  body: "subagent refused")))
        XCTAssertEqual(result.errorCode, "child_refusal")
        XCTAssertEqual(result.badge.status, .err)
        XCTAssertEqual(result.badge.errorCode, "child_refusal")
        XCTAssertTrue(result.isFailure)
    }

    func testKeepsAResultThatQuotesTheTag() throws {
        let body = "Line one\n\nIt mentions <delegation-result status=\"failed\"> in passing."
        let result = try XCTUnwrap(DelegatedResult.parse(delivery(body: body)))
        XCTAssertEqual(result.status, "completed")
        XCTAssertEqual(result.body, body)
        XCTAssertEqual(result.preview, "Line one It mentions <delegation-result status=\"failed\"> in passing.")
    }

    func testOtherMessagesAreNotResults() {
        XCTAssertNil(DelegatedResult.parse("Please summarize the delegation-result format"))
        // The block must end the message.
        XCTAssertNil(DelegatedResult.parse(delivery() + "\nAnd one more thing."))
        // A block without a status.
        XCTAssertNil(DelegatedResult.parse("<delegation-result task_id=\"t\">x</delegation-result>"))
        // A message with a picture is the user's own.
        let picture = ImageData(data: "", mimeType: "image/png", uri: nil)
        let turn = MessageTurn(id: "u-9", role: .user, blocks: [.text(delivery()), .image(picture)], timestamp: Date())
        XCTAssertNil(DelegatedResult.parse(turn))
    }

    func testTheTranscriptDrawsADeliveredResultAsItsCard() throws {
        let delivered = MessageTurn(id: "u-2", role: .user, blocks: [.text(delivery())], timestamp: Date())
        let own = MessageTurn(id: "u-3", role: .user, blocks: [.text("Thanks, go on")], timestamp: Date())
        let nodes = TranscriptTimeline.buildPersisted(turns: [delivered, own], pending: [], agent: .claudeCode,
                                                      suppressInFlight: false)
        let card = try XCTUnwrap(nodes.first { $0.id == "u-2" })
        guard case .delegatedResult(let result) = card.content else { return XCTFail("not the result card") }
        XCTAssertEqual(result.childConversationId, 42)
        guard case .tool("person.2", .done) = card.marker else { return XCTFail("the card's marker") }
        let message = try XCTUnwrap(nodes.first { $0.id == "u-3" })
        guard case .user = message.content else { return XCTFail("the user's own message stays a message") }
    }
}
