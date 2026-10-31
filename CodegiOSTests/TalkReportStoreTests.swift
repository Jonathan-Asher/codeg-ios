import XCTest
@testable import Codeg

/// Talk reports kept on the iPhone until the session's server has them.
final class TalkReportStoreTests: XCTestCase {
    private var directory: URL!
    private var store: TalkReportStore!
    private let server = UUID()

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("talk-reports-\(UUID().uuidString)")
        store = TalkReportStore(directory: directory)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    private func report(_ id: String) -> Data {
        Data(#"{"id":"\#(id)","kind":"talk_lab","talk":{"part":1}}"#.utf8)
    }

    private func ids(_ files: [URL]) -> [String] {
        files.compactMap(TalkReportStore.id(ofFile:))
    }

    func testReportsAreKeptPerServerUnderTheirIdsInOrder() {
        store.keep([report("talk-a-1"), report("talk-a-2")], for: server)
        store.keep([report("talk-b-1")], for: UUID())
        XCTAssertEqual(ids(store.waiting(for: server)), ["talk-a-1", "talk-a-2"])
        XCTAssertEqual(store.servers().count, 2)
        store.keep([report("talk-a-1")], for: server)
        XCTAssertEqual(ids(store.waiting(for: server)), ["talk-a-2", "talk-a-1"], "kept again, it replaces its copy")
    }

    func testAReportWithoutAUsableIdIsStillKept() {
        store.keep([Data(#"{"kind":"talk_lab"}"#.utf8), Data(#"{"id":"../x","kind":"talk_lab"}"#.utf8)], for: server)
        XCTAssertEqual(store.waiting(for: server).count, 2)
        XCTAssertTrue(store.waiting(for: server).allSatisfy {
            $0.deletingLastPathComponent().lastPathComponent == server.uuidString && !$0.lastPathComponent.contains("..")
        })
    }

    func testWhatTheServerTookOrRefusedGoesAndAFailureKeepsTheRest() async throws {
        store.keep([report("talk-a-1"), report("talk-a-2"), report("talk-a-3"), report("talk-a-4")], for: server)
        var bodies: [Data] = []
        let sent = await store.send(for: server) { body in
            bodies.append(body)
            switch bodies.count {
            case 2: throw APIError.server(status: 400, code: nil, message: "larger than 1024 KiB")
            case 3: throw APIError.transport("offline")
            default: break
            }
        }
        XCTAssertEqual(sent, 1)
        XCTAssertEqual(bodies.count, 3, "it stops at a failure")
        let first = try XCTUnwrap(JSONSerialization.jsonObject(with: bodies[0]) as? [String: Any])
        XCTAssertEqual((first["report"] as? [String: Any])?["id"] as? String, "talk-a-1", "the endpoint's body")
        XCTAssertEqual(ids(store.waiting(for: server)), ["talk-a-3", "talk-a-4"])
        let later = await store.send(for: server) { _ in }
        XCTAssertEqual(later, 2)
        XCTAssertTrue(store.waiting(for: server).isEmpty)
        XCTAssertTrue(store.servers().isEmpty)
    }

    func testAServerWithoutTheCallOrBusyKeepsTheReports() async {
        store.keep([report("talk-a-1")], for: server)
        for status in [404, 408, 429, 500] {
            await store.send(for: server) { _ in throw APIError.server(status: status, code: nil, message: "") }
            XCTAssertEqual(store.waiting(for: server).count, 1, "HTTP \(status)")
        }
    }

    func testOldReportsAndTheOldestPastTheLimitAreDropped() async {
        let old = Date().addingTimeInterval(-TalkReportStore.maxAge - 60)
        store.keep([report("talk-old-1")], for: server, now: old)
        XCTAssertEqual(store.waiting(for: server).count, 1)
        store.keep((0..<(TalkReportStore.maxPerServer + 2)).map { report("talk-n-\($0)") }, for: server)
        let kept = ids(store.waiting(for: server))
        XCTAssertEqual(kept.count, TalkReportStore.maxPerServer)
        XCTAssertFalse(kept.contains("talk-old-1"), "past its age")
        XCTAssertEqual(kept.first, "talk-n-2", "the oldest go first")
        var sentAfterAge = 0
        await store.send(for: server, now: Date().addingTimeInterval(TalkReportStore.maxAge + 60)) { _ in
            sentAfterAge += 1
        }
        XCTAssertEqual(sentAfterAge, 0, "nothing past its age is sent")
    }

    func testRemovingAServerOrAll() {
        let other = UUID()
        store.keep([report("talk-a-1")], for: server)
        store.keep([report("talk-b-1")], for: other)
        store.remove(server: server)
        XCTAssertEqual(store.servers(), [other])
        store.removeAll()
        XCTAssertTrue(store.servers().isEmpty)
    }
}
