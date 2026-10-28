import XCTest
import UserNotifications
@testable import Codeg

/// The notification delegate hands iOS its completion on the main thread,
/// once (1.3.27 called it from the cooperative pool, and iOS 27.2 ended the
/// app on every tap), and a notification action's network call is given up
/// at its deadline.
@MainActor
final class NotificationResponseTests: XCTestCase {
    /// What the injected handler and completion saw.
    private final class Record: @unchecked Sendable {
        var handled: [String] = []
        var completions: [Bool] = []
        var options: [UNNotificationPresentationOptions] = []
    }

    private func payload() -> PushPayload? {
        PushPayload(userInfo: ["kind": "needs_you", "server_id": "3f9c0a1b2c4d",
                               "conversation_id": NSNumber(value: 42)])
    }

    // MARK: - The delegate's requirements

    func testTheDelegateAnswersTheCompletionHandlerSelectors() {
        // A requirement that only nearly matched would leave these unexposed,
        // and iOS would never call them.
        let delegate = NotificationDelegate()
        XCTAssertTrue(delegate.responds(
            to: NSSelectorFromString("userNotificationCenter:didReceiveNotificationResponse:withCompletionHandler:")))
        XCTAssertTrue(delegate.responds(
            to: NSSelectorFromString("userNotificationCenter:willPresentNotification:withCompletionHandler:")))
    }

    // MARK: - A tap or a button

    func testAResponseCompletesOnceOnTheMainThreadAfterTheHandlerHopsAway() async {
        let record = Record()
        let completed = expectation(description: "completion")
        NotificationDelegate.didReceive(actionIdentifier: "ANSWER_1", payload: payload(), handle: { action, _ in
            // Like a network call: off the main actor and back.
            _ = await Task.detached { try? await Task.sleep(for: .milliseconds(50)) }.value
            record.handled.append(action)
        }, completion: {
            record.completions.append(Thread.isMainThread)
            completed.fulfill()
        })
        await fulfillment(of: [completed], timeout: 5)
        // Time for a second call, which must not come.
        try? await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(record.handled, ["ANSWER_1"])
        XCTAssertEqual(record.completions, [true])
    }

    func testAResponseDeliveredOffTheMainThreadStillCompletesOnIt() async {
        let record = Record()
        let completed = expectation(description: "completion")
        let payload = self.payload()
        DispatchQueue.global().async {
            NotificationDelegate.didReceive(actionIdentifier: UNNotificationDefaultActionIdentifier, payload: payload,
                                            handle: { action, _ in record.handled.append(action) },
                                            completion: {
                                                record.completions.append(Thread.isMainThread)
                                                completed.fulfill()
                                            })
        }
        await fulfillment(of: [completed], timeout: 5)
        XCTAssertEqual(record.handled, [UNNotificationDefaultActionIdentifier])
        XCTAssertEqual(record.completions, [true])
    }

    func testAResponseWithoutAPayloadStillCompletesOnce() async {
        let record = Record()
        let completed = expectation(description: "completion")
        NotificationDelegate.didReceive(actionIdentifier: "ACK", payload: nil,
                                        handle: { action, _ in record.handled.append(action) },
                                        completion: {
                                            record.completions.append(Thread.isMainThread)
                                            completed.fulfill()
                                        })
        await fulfillment(of: [completed], timeout: 5)
        XCTAssertEqual(record.handled, [])
        XCTAssertEqual(record.completions, [true])
    }

    // MARK: - In the foreground

    func testPresentingCompletesOnceOnTheMainThread() async {
        let record = Record()
        let completed = expectation(description: "completion")
        let payload = self.payload()
        DispatchQueue.global().async {
            NotificationDelegate.willPresent(payload, options: { _ in [.banner, .sound] }, completion: { options in
                record.options.append(options)
                record.completions.append(Thread.isMainThread)
                completed.fulfill()
            })
        }
        await fulfillment(of: [completed], timeout: 5)
        XCTAssertEqual(record.options, [[.banner, .sound]])
        XCTAssertEqual(record.completions, [true])
    }

    // MARK: - The deadline

    func testAQuickCallReturnsItsResult() async throws {
        let value = try await NotificationTimeout.run(within: .seconds(5)) { () async throws -> Int in 42 }
        XCTAssertEqual(value, 42)
    }

    func testAFailingCallThrowsItsOwnError() async {
        do {
            try await NotificationTimeout.run(within: .seconds(5)) { () async throws -> Void in
                throw URLError(.notConnectedToInternet)
            }
            XCTFail("Expected the call's error")
        } catch {
            XCTAssertEqual((error as? URLError)?.code, .notConnectedToInternet)
        }
    }

    func testTheDeadlineCancelsASlowCall() async {
        let cancelled = expectation(description: "cancelled")
        do {
            try await NotificationTimeout.run(within: .milliseconds(100)) { () async throws -> Void in
                do {
                    try await Task.sleep(for: .seconds(30))
                } catch {
                    cancelled.fulfill()
                    throw error
                }
            }
            XCTFail("Expected the deadline")
        } catch {
            XCTAssertTrue(error is NotificationTimeout.Expired, "\(error)")
        }
        await fulfillment(of: [cancelled], timeout: 5)
    }

    func testACallThatIgnoresCancellationIsNotWaitedFor() async {
        let finished = expectation(description: "the call finishes after the deadline")
        let started = ContinuousClock.now
        do {
            _ = try await NotificationTimeout.run(within: .milliseconds(200)) { () async throws -> Int in
                // Like a request that never looks at cancellation.
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    DispatchQueue.global().asyncAfter(deadline: .now() + 2) { continuation.resume() }
                }
                finished.fulfill()
                return 1
            }
            XCTFail("Expected the deadline")
        } catch {
            XCTAssertTrue(error is NotificationTimeout.Expired, "\(error)")
        }
        XCTAssertLessThan(ContinuousClock.now - started, .milliseconds(1500))
        // Its late result is dropped: a second resume of the caller would trap.
        await fulfillment(of: [finished], timeout: 10)
    }

    func testTheActionDeadlineLeavesTimeForTheCompletion() {
        XCTAssertLessThanOrEqual(NotificationTimeout.action, .seconds(10))
        XCTAssertGreaterThanOrEqual(NotificationTimeout.action, .seconds(5))
    }
}
