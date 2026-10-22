import XCTest
@testable import Codeg

/// Usage limits and the account pool: why a pause waits, a stop that no
/// longer continues, Cancel auto-continue and Continue now, opening a session
/// while the pool is full, and a message the pool holds back (codeg's
/// `limit-pause.tsx`, `limit-continue.ts` and `pool_exhausted`).
@MainActor
final class LimitPauseTests: XCTestCase {
    private let resetsAt = Date(timeIntervalSince1970: 2_000_000_000)

    private func summary(_ fields: String) throws -> ConversationSummary {
        let json = """
        {"id": 42, "folder_id": 7, "title": "Pool", "agent_type": "claude_code", "status": "in_progress",
         "model": null, "git_branch": null, "external_id": "abc", "message_count": 3,
         "created_at": "2026-10-02T10:00:00Z", "updated_at": "2026-10-02T11:00:00Z"\(fields)}
        """
        return try CodegJSON.decoder.decode(ConversationSummary.self, from: Data(json.utf8))
    }

    func testAPoolPauseSaysSoAndWhenItContinues() throws {
        let pooled = try summary("""
        , "turn_state": "interrupted", "limit_reason": "pool_capacity",
          "limit_pause": {"resets_at": "2033-05-18T03:33:20Z", "state": "scheduled", "attempts": 0}
        """)
        XCTAssertEqual(pooled.limitReason, .poolCapacity)
        guard case .limitPaused(let pause) = SessionActivity.of(pooled) else {
            return XCTFail("expected a pause, got \(SessionActivity.of(pooled))")
        }
        XCTAssertTrue(pause.isPool)
        let now = resetsAt.addingTimeInterval(-90 * 60)
        let time = LimitResetFormat.parts(resetsAt: resetsAt, now: now).time
        XCTAssertEqual(SessionActivity.limitPaused(pause).label(now: now), "Paused by usage limits — continues at \(time)")
        XCTAssertTrue(SessionActivity.limitPaused(pause).hint.hasPrefix("Every Claude account behind the account pool"))
        XCTAssertEqual(LimitPausedBanner.title(pause), "Paused by usage limits")
        XCTAssertEqual(LimitPausedBanner.detail(pause, now: now),
                       "Continues automatically when it resets at \(time) (in 1h 30m).")

        // The account's own limit, and a server that predates the reason, read as before.
        let own = try summary("""
        , "turn_state": "interrupted", "limit_reason": "usage_limit",
          "limit_pause": {"resets_at": "2033-05-18T03:33:20Z", "state": "scheduled", "attempts": 1}
        """)
        guard case .limitPaused(let ownPause) = SessionActivity.of(own) else { return XCTFail("expected a pause") }
        XCTAssertFalse(ownPause.isPool)
        XCTAssertTrue(SessionActivity.limitPaused(ownPause).label(now: now).hasPrefix("Paused — limit resets at "))
        XCTAssertEqual(LimitPausedBanner.title(ownPause), "Paused on the usage limit")
        let older = try summary("""
        , "turn_state": "interrupted",
          "limit_pause": {"resets_at": "2033-05-18T03:33:20Z", "state": "claimed", "attempts": 1}
        """)
        XCTAssertNil(older.limitReason)
        guard case .limitPaused(let claimed) = SessionActivity.of(older) else { return XCTFail("expected a pause") }
        XCTAssertFalse(claimed.isPool)
        XCTAssertEqual(LimitPausedBanner.detail(claimed, now: now), "The limit has reset — continuing now.")
    }

    func testAStopThatNoLongerContinuesReadsStopped() throws {
        let stopped = try summary(#", "turn_state": "interrupted", "limit_reason": "pool_capacity", "limit_pause": null"#)
        XCTAssertEqual(SessionActivity.of(stopped), .limitStopped(.poolCapacity))
        XCTAssertEqual(SessionActivity.limitStopped(.poolCapacity).label(), "Stopped by usage limits")
        // Any other interrupted turn stays "Interrupted", and a running one isn't stopped.
        XCTAssertEqual(SessionActivity.of(try summary(#", "turn_state": "interrupted""#)), .interrupted)
        XCTAssertEqual(SessionActivity.derive(SessionActivityInputs(turnState: .running, limitReason: .usageLimit)),
                       .working)
    }

    func testCancelAndContinueNowGoToTheServer() async throws {
        let server = MockCodegServer()
        server.on("cancel_limit_continue") { _ in .body("true") }
        server.on("continue_limit_now") { _ in .body("false") }
        let cancelled = try await server.client.cancelLimitContinue(conversationId: 42)
        let continued = try await server.client.continueLimitNow(conversationId: 42)
        XCTAssertTrue(cancelled)
        XCTAssertFalse(continued, "not paused any more")
        XCTAssertEqual(server.calls("cancel_limit_continue").first?.body["conversationId"] as? Int, 42)
        XCTAssertEqual(server.calls("continue_limit_now").first?.body["conversationId"] as? Int, 42)
    }

    func testOpeningASessionWhileThePoolIsFull() throws {
        let event = try CodegJSON.decoder.decode(EventEnvelope.self, from: Data(
            #"{"seq": 2, "connection_id": "c", "type": "attach_progress", "phase": "pool_wait", "elapsed_ms": 900, "pool_resumes_at": 2000000000}"#.utf8))
        XCTAssertEqual(event.event, .attachProgress(phase: "pool_wait", elapsedMs: 900, poolResumesAt: resetsAt))
        let time = LimitResetFormat.parts(resetsAt: resetsAt, now: resetsAt).time
        XCTAssertEqual(SessionActivity.connecting(phase: "pool_wait", poolResumesAt: resetsAt).label(now: resetsAt),
                       "Connecting… (all Claude subscriptions are at their limit — the next one frees at \(time))")
        XCTAssertEqual(SessionActivity.connecting(phase: "pool_wait").label(),
                       "Connecting… (all Claude subscriptions are at their limit)")
    }

    func testAMessageThePoolHoldsBackWaitsForAnAccount() async throws {
        let message = "All Claude subscriptions behind the account pool are at their limit, so Claude Code cannot take a request yet; the next one frees at 03:33 UTC. [pool_exhausted resumes_at=2000000000]"
        // The server's 409 is not "a turn is already running".
        let server = MockCodegServer()
        server.on("acp_prompt") { _ in
            .status(409, #"{"code": "pool_exhausted", "message": "\#(message)"}"#)
        }
        do {
            try await server.client.prompt(connectionId: "c", blocks: [], folderId: nil, conversationId: 42,
                                           clientMessageId: "m1")
            XCTFail("refused")
        } catch let error as APIError {
            XCTAssertTrue(error.isPoolExhausted, "\(error)")
            XCTAssertEqual(error.poolResumesAt, resetsAt)
            let failure = SendFailure.next(after: error, previous: nil)
            XCTAssertEqual(failure.reason, .poolExhausted)
            XCTAssertTrue(failure.autoRetry)
            XCTAssertEqual(failure.retryAt, resetsAt)
            XCTAssertTrue(failure.label.hasPrefix("All accounts at their limit — will resend at "), failure.label)
            // It keeps going by itself, however many times it meets the limit.
            let again = SendFailure.next(after: error, previous: SendFailure.next(
                after: error, previous: SendFailure.next(after: error, previous: failure)))
            XCTAssertTrue(again.autoRetry)
        }
        let unknown = APIError.server(status: 409, code: "pool_exhausted", message: "… [pool_exhausted]")
        let failure = SendFailure.next(after: unknown, previous: nil)
        XCTAssertNil(failure.retryAt)
        XCTAssertEqual(failure.retryDelay, 60)
        XCTAssertEqual(failure.label, "All accounts at their limit — will resend when one frees up")
        // Stored before 1.3.22 (no `retryAt`), a failure still reads back.
        let stored = #"{"reason": "network", "autoRetry": true, "attempts": 2}"#
        XCTAssertEqual(try JSONDecoder().decode(SendFailure.self, from: Data(stored.utf8)).reason, .network)
    }
}
