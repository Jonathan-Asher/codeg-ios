import XCTest
@testable import Codeg

/// Payload parsing and action routing for codeg pushes (docs/ios-push.md §5–6).
final class PushPayloadTests: XCTestCase {
    private func permissionUserInfo() -> [AnyHashable: Any] {
        [
            "aps": [
                "alert": ["title": "Fix the login bug", "body": "codeg · needs you"],
                "thread-id": "3f9c0a1b2c4d-42",
                "category": "CODEG_PERMISSION",
                "interruption-level": "time-sensitive",
            ] as [String: Any],
            "server_id": "3f9c0a1b2c4d",
            "kind": "needs_you",
            "needs": "permission",
            "alert_id": "9a8b",
            "conversation_id": NSNumber(value: 42),
            "folder_id": NSNumber(value: 7),
            "agent_type": "claude_code",
            "connection_id": "conn-1",
            "request_id": "req-9",
            "approve_option_id": "allow_once",
            "deny_option_id": "reject_once",
        ]
    }

    func testParsesPermissionPayload() throws {
        let payload = try XCTUnwrap(PushPayload(userInfo: permissionUserInfo()))
        XCTAssertEqual(payload.serverID, "3f9c0a1b2c4d")
        XCTAssertEqual(payload.kind, "needs_you")
        XCTAssertEqual(payload.needs, "permission")
        XCTAssertEqual(payload.conversationID, 42)
        XCTAssertEqual(payload.folderID, 7)
        XCTAssertEqual(payload.connectionID, "conn-1")
        XCTAssertEqual(payload.requestID, "req-9")
        XCTAssertEqual(payload.approveOptionID, "allow_once")
        XCTAssertEqual(payload.category, PushCategory.permission)
        XCTAssertEqual(payload.threadID, "3f9c0a1b2c4d-42")
    }

    func testNotACodegPush() {
        XCTAssertNil(PushPayload(userInfo: ["aps": ["alert": "hi"]]))
    }

    func testActionRouting() throws {
        let payload = try XCTUnwrap(PushPayload(userInfo: permissionUserInfo()))
        XCTAssertEqual(PushRouting.action(for: PushActionID.approve, payload: payload),
                       .approve(connectionID: "conn-1", requestID: "req-9", optionID: "allow_once"))
        XCTAssertEqual(PushRouting.action(for: PushActionID.open, payload: payload),
                       .open(conversationID: 42, folderID: 7))
        XCTAssertEqual(PushRouting.action(for: PushActionID.tap, payload: payload),
                       .open(conversationID: 42, folderID: 7))
        XCTAssertEqual(PushRouting.action(for: PushActionID.ack, payload: payload), .ack(conversationID: 42))
        XCTAssertEqual(PushRouting.action(for: PushActionID.snooze, payload: payload),
                       .snooze(conversationID: 42, minutes: 15))
        XCTAssertEqual(PushRouting.action(for: PushActionID.dismiss, payload: payload), .none)
    }

    func testApproveWithoutOptionOpensInstead() {
        var payload = PushPayload(kind: "needs_you", serverID: "s", conversationID: 5, folderID: 1)
        payload.connectionID = "c"
        payload.requestID = "r"
        XCTAssertEqual(PushRouting.action(for: PushActionID.approve, payload: payload),
                       .open(conversationID: 5, folderID: 1))
    }

    func testTestPushHasNothingToOpen() {
        let payload = PushPayload(kind: "test", serverID: "s")
        XCTAssertEqual(PushRouting.action(for: PushActionID.tap, payload: payload), .none)
    }

    func testServerMatching() {
        let a = UUID(), b = UUID()
        let recorded = [a: "server-a", b: "server-b"]
        XCTAssertEqual(PushRouting.serverProfileID(for: "server-b", recorded: recorded, saved: [a, b]), b)
        // Unknown id with several servers: no guess.
        XCTAssertNil(PushRouting.serverProfileID(for: "server-x", recorded: recorded, saved: [a, b]))
        // Unknown id with a single server: that one.
        XCTAssertEqual(PushRouting.serverProfileID(for: "server-x", recorded: [:], saved: [a]), a)
        // A recorded id whose server was deleted is ignored.
        XCTAssertNil(PushRouting.serverProfileID(for: "server-b", recorded: recorded, saved: [a, UUID()]))
    }

    func testForegroundSuppressionOnlyForTheVisibleSession() {
        let a = UUID()
        let payload = PushPayload(kind: "turn_finished", serverID: "server-a", conversationID: 42, folderID: 7)
        XCTAssertTrue(PushRouting.isAboutVisibleSession(payload, visibleServer: a, visibleConversation: 42,
                                                         recorded: [a: "server-a"], saved: [a]))
        XCTAssertFalse(PushRouting.isAboutVisibleSession(payload, visibleServer: a, visibleConversation: 43,
                                                          recorded: [a: "server-a"], saved: [a]))
        XCTAssertFalse(PushRouting.isAboutVisibleSession(payload, visibleServer: nil, visibleConversation: nil,
                                                          recorded: [a: "server-a"], saved: [a]))
    }

    func testDevicePrefsEncodeSnakeCase() throws {
        var prefs = PushDevicePrefs()
        prefs.turnFinished = .always
        prefs.needsYou = .off
        let data = try CodegJSON.encoder.encode(prefs)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["turn_finished"] as? String, "always")
        XCTAssertEqual(object["needs_you"] as? String, "off")
        XCTAssertEqual(object["critical"] as? Bool, true)
        XCTAssertEqual(object["errors"] as? Bool, false)

        let device = try CodegJSON.decoder.decode(PushDeviceView.self, from: Data("""
        {"id": 3, "name": "iPhone", "platform": "ios", "environment": "production",
         "bundle_id": "io.ashurov.codeg", "token_hint": "…a1b2c3d4",
         "prefs": {"turn_finished": "always", "needs_you": "away", "critical": false, "errors": true},
         "created_at": "2026-10-02T10:00:00Z", "last_seen_at": "2026-10-02T10:00:00Z"}
        """.utf8))
        XCTAssertEqual(device.prefs.turnFinished, .always)
        XCTAssertEqual(device.prefs.needsYou, .away)
        XCTAssertFalse(device.prefs.critical)
        XCTAssertTrue(device.prefs.errors)
        XCTAssertTrue(device.matches(token: "ffffffffffffffffffffffffa1b2c3d4"))
        XCTAssertFalse(device.matches(token: "ffffffffffffffffffffffff00000000"))
    }
}
