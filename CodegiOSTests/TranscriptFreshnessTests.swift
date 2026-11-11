import XCTest
@testable import Codeg

/// What a session screen says about the transcript it shows while the
/// server's copy is read (1.4.5): "Updating…" over a saved or kept copy until
/// the server's copy is in, "Couldn’t update" with Try Again when the read
/// fails, and the transcript shown as soon as it is in, without waiting for
/// the folder list. Against a ``MockCodegServer`` playing a windowed
/// transcript (``WindowedTranscriptServer``).
@MainActor
final class TranscriptFreshnessTests: XCTestCase {
    private var server: MockCodegServer!
    private var transcript: WindowedTranscriptServer!
    private var models: [SessionDetailViewModel] = []
    private var cacheRoot: URL!
    private let wifi = NetworkPath(status: .satisfied, interfaces: ["wifi"])
    private let noNetwork = NetworkPath(status: .unsatisfied)

    override func setUp() async throws {
        server = MockCodegServer()
        transcript = WindowedTranscriptServer(count: 200)
        transcript.install(on: server)
        cacheRoot = FileManager.default.temporaryDirectory.appendingPathComponent("tf-\(UUID().uuidString)")
    }

    override func tearDown() async throws {
        models.forEach { $0.teardown() }
        models = []
        server = nil
        transcript = nil
        try? FileManager.default.removeItem(at: cacheRoot)
    }

    private func makeModel(cache: TranscriptCache? = nil,
                           connectivity: ConnectivityMonitor? = nil) -> SessionDetailViewModel {
        let factory = StreamFactory([])
        let model = SessionDetailViewModel(client: server.client, conversationID: Fixtures.conversationID,
                                           makeEventStream: { _ in factory.make() }, transcriptCache: cache,
                                           connectivity: connectivity)
        models.append(model)
        return model
    }

    /// A cache holding the session as an earlier screen saw it: up to turn 199.
    private func savedCopy() async -> TranscriptCache {
        let cache = TranscriptCache(root: cacheRoot)
        let first = makeModel(cache: cache)
        await first.load()
        let key = TranscriptCache.serverKey(for: server.client)
        let saved = await eventuallyAsync {
            await cache.load(serverKey: key, conversationID: Fixtures.conversationID)?.turns.last?.id == "turn-199"
        }
        XCTAssertTrue(saved, "the first screen saved its copy")
        first.teardown()
        return cache
    }

    /// The server's detail, held until `gate` opens.
    private func holdDetail(until gate: ReplyGate) {
        let transcript = self.transcript!
        server.on("get_folder_conversation") { call in
            .held(gate, .body(transcript.detail(call.body, id: Fixtures.conversationID)))
        }
    }

    func testASavedCopySaysItIsUpdatingUntilTheServersCopyIsIn() async throws {
        let cache = await savedCopy()
        transcript.append(5)
        let gate = ReplyGate()
        holdDetail(until: gate)

        let model = makeModel(cache: cache)
        XCTAssertEqual(model.freshness, .current)
        let load = Task { await model.load() }
        let shown = await eventually { model.phase == .loaded && model.openedFromCache }
        XCTAssertTrue(shown, "the saved copy shows at once")
        XCTAssertEqual(model.freshness, .updating, "and says it is being updated")
        XCTAssertEqual(model.turns.last?.id, "turn-199", "the saved copy is behind the server")

        gate.open()
        await load.value
        XCTAssertEqual(model.freshness, .current, "the server's copy is in")
        XCTAssertEqual(model.turns.last?.id, "turn-204")
    }

    func testAFailedUpdateSaysSoAndTryAgainBringsTheServersCopy() async throws {
        let cache = await savedCopy()
        transcript.append(5)
        server.on("get_folder_conversation") { _ in .fail(.timedOut) }

        let model = makeModel(cache: cache)
        await model.load()
        XCTAssertEqual(model.phase, .loaded, "the saved copy stays on screen")
        guard case .failed = model.freshness else {
            return XCTFail("the screen should say it couldn't update, not \(model.freshness)")
        }
        XCTAssertEqual(model.turns.last?.id, "turn-199")

        transcript.install(on: server)
        model.retryUpdate()
        XCTAssertEqual(model.freshness, .updating, "Try Again says it is updating at once")
        let updated = await eventually { model.freshness == .current }
        XCTAssertTrue(updated)
        XCTAssertEqual(model.turns.last?.id, "turn-204")
    }

    func testAFailedUpdateGoesAgainWhenTheNetworkIsBack() async throws {
        let cache = await savedCopy()
        transcript.append(5)
        let monitor = ConnectivityMonitor(source: nil)
        monitor.apply(wifi)
        server.on("get_folder_conversation") { _ in .fail(.notConnectedToInternet) }

        let model = makeModel(cache: cache, connectivity: monitor)
        monitor.apply(noNetwork)
        await model.load()
        guard case .failed = model.freshness else {
            return XCTFail("the screen should say it couldn't update, not \(model.freshness)")
        }

        transcript.install(on: server)
        monitor.apply(wifi)
        let updated = await eventually { model.freshness == .current }
        XCTAssertTrue(updated, "the network back, the update went again by itself")
        XCTAssertEqual(model.turns.last?.id, "turn-204")
    }

    func testAKeptScreenShownAgainSaysItIsUpdating() async throws {
        let model = makeModel()
        await model.load()
        XCTAssertEqual(model.freshness, .current)
        model.suspend()

        transcript.append(5)
        let gate = ReplyGate()
        holdDetail(until: gate)
        let resume = Task { await model.resume() }
        let updating = await eventually { model.freshness == .updating }
        XCTAssertTrue(updating, "the kept copy says it is being updated")
        XCTAssertEqual(model.turns.last?.id, "turn-199")

        gate.open()
        await resume.value
        XCTAssertEqual(model.freshness, .current)
        XCTAssertEqual(model.turns.last?.id, "turn-204")
    }

    func testAFirstOpenWithNothingSavedShowsTheSpinnerInstead() async throws {
        let gate = ReplyGate()
        holdDetail(until: gate)
        let model = makeModel()
        let load = Task { await model.load() }
        let asked = await eventually { !self.server.calls("get_folder_conversation").isEmpty }
        XCTAssertTrue(asked)
        XCTAssertEqual(model.phase, .loading, "the whole screen says it is loading")
        XCTAssertEqual(model.freshness, .current, "nothing on screen to call out of date")

        gate.open()
        await load.value
        XCTAssertEqual(model.phase, .loaded)
        XCTAssertEqual(model.freshness, .current)
    }

    func testTheTranscriptShowsWithoutWaitingForTheFolderList() async throws {
        let cache = await savedCopy()
        transcript.append(5)
        let folders = ReplyGate()
        server.on("list_all_folder_details") { _ in .held(folders, .body("[]")) }

        let model = makeModel(cache: cache)
        let load = Task { await model.load() }
        let shown = await eventually { model.turns.last?.id == "turn-204" }
        XCTAssertTrue(shown, "the server's transcript is on screen while the folder list is on its way")
        XCTAssertEqual(model.freshness, .current)

        folders.open()
        await load.value
        XCTAssertEqual(model.turns.last?.id, "turn-204")
        XCTAssertEqual(model.freshness, .current)
    }

    /// Poll an async condition until it holds or `timeout` passes.
    private func eventuallyAsync(timeout: TimeInterval = 5, _ condition: () async -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return await condition()
    }
}
