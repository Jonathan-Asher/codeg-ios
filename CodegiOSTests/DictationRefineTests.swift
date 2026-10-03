import XCTest
@testable import Codeg

/// A codeg server for the clean-up commands.
private final class MockRefineServer: DictationRefineTransport, @unchecked Sendable {
    let refineServerKey: String
    private let lock = NSLock()
    private var _settings: Result<DictationRefineSettings, Error>
    private var _refine: Result<DictationRefineResult, Error>
    private var _refineDelay: Duration = .zero
    private var _settingsCalls = 0
    private var _requests: [DictationRefineRequest] = []

    init(settings: Result<DictationRefineSettings, Error> = .success(DictationRefineSettings(configured: true)),
         refine: Result<DictationRefineResult, Error> = .success(DictationRefineResult(text: "Hello world")),
         refineDelay: Duration = .zero) {
        refineServerKey = "mock-\(UUID().uuidString)"
        _settings = settings
        _refine = refine
        _refineDelay = refineDelay
    }

    var settingsCalls: Int { lock.withLock { _settingsCalls } }
    var requests: [DictationRefineRequest] { lock.withLock { _requests } }

    func dictationRefineSettings() async throws -> DictationRefineSettings {
        let result = lock.withLock {
            _settingsCalls += 1
            return _settings
        }
        return try result.get()
    }

    func refineDictation(_ request: DictationRefineRequest) async throws -> DictationRefineResult {
        let (result, delay) = lock.withLock {
            _requests.append(request)
            return (_refine, _refineDelay)
        }
        if delay > .zero { try await Task.sleep(for: delay) }
        return try result.get()
    }
}

final class TranscriptPostProcessorTests: XCTestCase {
    private func makeProcessor(_ server: MockRefineServer, timeout: Duration = .seconds(12)) -> TranscriptPostProcessor {
        TranscriptPostProcessor(transport: server, timeout: timeout, cache: DictationRefineStatusCache())
    }

    func testTranslationReturnsTheServersText() async {
        let server = MockRefineServer(refine: .success(DictationRefineResult(
            text: "  Push the fix to main.  ", provider: "groq", model: "llama-3.3-70b", elapsedMs: 420)))
        let outcome = await makeProcessor(server).process("תדחוף את התיקון ל-main", mode: .translate, sourceLanguage: "he")
        XCTAssertEqual(outcome.text, "Push the fix to main.")
        XCTAssertEqual(outcome.status, .refined(provider: "groq", model: "llama-3.3-70b", elapsedMs: 420))
        XCTAssertNil(outcome.notice)
        XCTAssertEqual(server.requests, [DictationRefineRequest(
            text: "תדחוף את התיקון ל-main", mode: .translate, sourceLanguage: "he")])
        let request = server.requests[0]
        XCTAssertEqual(request.refine, true)
        XCTAssertEqual(request.translate, true)
        XCTAssertEqual(request.targetLanguage, "English")
        XCTAssertEqual(request.sourceLanguage, "Hebrew")
    }

    func testATranslateOnlyProviderIsNotAskedToCleanUp() async {
        let server = MockRefineServer(settings: .success(DictationRefineSettings(configured: true, provider: "google")))
        _ = await makeProcessor(server).process("שלום", mode: .translate, sourceLanguage: "he")
        XCTAssertEqual(server.requests.first?.refine, false)
        XCTAssertEqual(server.requests.first?.translate, true)
    }

    func testCleanUpDoesNotTranslate() async {
        let server = MockRefineServer()
        _ = await makeProcessor(server).process("אממ תבדוק את ה build", mode: .cleanUp, sourceLanguage: "he")
        let request = server.requests.first
        XCTAssertEqual(request?.refine, true)
        XCTAssertEqual(request?.translate, false)
        XCTAssertNil(request?.targetLanguage)
    }

    func testAsSpokenNeverAsksTheServer() async {
        let server = MockRefineServer()
        let outcome = await makeProcessor(server).process("שלום", mode: .asSpoken, sourceLanguage: "he")
        XCTAssertEqual(outcome, DictationRefineOutcome(text: "שלום", status: .asSpoken, mode: .asSpoken))
        XCTAssertEqual(server.settingsCalls, 0)
        XCTAssertTrue(server.requests.isEmpty)
    }

    func testAFailureKeepsTheWords() async {
        let server = MockRefineServer(refine: .failure(APIError.server(status: 500, code: "network_error", message: "Groq is down")))
        let outcome = await makeProcessor(server).process("שלום עולם", mode: .translate, sourceLanguage: "he")
        XCTAssertEqual(outcome.text, "שלום עולם")
        XCTAssertEqual(outcome.status, .kept(.failed("Groq is down")))
        XCTAssertEqual(outcome.notice, "Translation failed: Groq is down. Kept as spoken.")
    }

    func testTheServersMessageIsShownAsIs() async {
        let message = "Groq: the API key was rejected — check it in Settings › General › Dictation clean-up and translation"
        let server = MockRefineServer(refine: .failure(APIError.server(
            status: 422, code: "authentication_failed", message: message)))
        let outcome = await makeProcessor(server).process("שלום", mode: .cleanUp, sourceLanguage: "he")
        XCTAssertEqual(outcome.text, "שלום")
        XCTAssertEqual(outcome.notice, "Clean-up failed: \(message). Kept as spoken.")
    }

    func testATransportFailureKeepsTheWords() async {
        let server = MockRefineServer(refine: .failure(APIError.transport("The Internet connection appears to be offline.")))
        let outcome = await makeProcessor(server).process("שלום", mode: .translate, sourceLanguage: "he")
        XCTAssertEqual(outcome.text, "שלום")
        XCTAssertEqual(outcome.status, .kept(.failed("Network error: The Internet connection appears to be offline")))
    }

    func testAnEmptyAnswerKeepsTheWords() async {
        let server = MockRefineServer(refine: .success(DictationRefineResult(text: "   ")))
        let outcome = await makeProcessor(server).process("שלום", mode: .cleanUp, sourceLanguage: "he")
        XCTAssertEqual(outcome.text, "שלום")
        if case .kept(.failed) = outcome.status {} else { XCTFail("expected a failure, got \(outcome.status)") }
    }

    func testATimeoutKeepsTheWords() async {
        let server = MockRefineServer(refineDelay: .seconds(10))
        let started = Date()
        let outcome = await makeProcessor(server, timeout: .milliseconds(200))
            .process("שלום", mode: .translate, sourceLanguage: "he")
        XCTAssertEqual(outcome.text, "שלום")
        XCTAssertEqual(outcome.status, .kept(.timedOut))
        XCTAssertEqual(outcome.notice, "Translation took too long. Kept as spoken.")
        XCTAssertLessThan(Date().timeIntervalSince(started), 3)
    }

    func testAnOlderServerIsNotAvailable() async {
        let server = MockRefineServer(settings: .failure(APIError.server(
            status: 501, code: "not_implemented",
            message: "API endpoint 'get_dictation_refine_settings' is not available in web mode")))
        let processor = makeProcessor(server)
        let first = await processor.process("שלום", mode: .cleanUp, sourceLanguage: "he")
        XCTAssertEqual(first.text, "שלום")
        XCTAssertEqual(first.status, .kept(.notAvailable))
        XCTAssertNotNil(first.notice)
        XCTAssertTrue(server.requests.isEmpty, "refine_dictation isn't tried on an older server")

        // The answer is cached.
        _ = await processor.process("שוב", mode: .cleanUp, sourceLanguage: "he")
        XCTAssertEqual(server.settingsCalls, 1)
    }

    func testANotFoundIsNotAvailable() async {
        let server = MockRefineServer(settings: .failure(APIError.server(status: 404, code: nil, message: "Not Found")))
        let outcome = await makeProcessor(server).process("שלום", mode: .translate, sourceLanguage: "he")
        XCTAssertEqual(outcome.status, .kept(.notAvailable))
    }

    func testRefineRevealingAnOlderServer() async {
        let cache = DictationRefineStatusCache()
        let server = MockRefineServer(refine: .failure(APIError.server(status: 501, code: "not_implemented", message: "no")))
        let processor = TranscriptPostProcessor(transport: server, cache: cache)
        let outcome = await processor.process("שלום", mode: .cleanUp, sourceLanguage: "he")
        XCTAssertEqual(outcome.status, .kept(.notAvailable))
        let cached = await cache.availability(of: server, maxAge: 300)
        XCTAssertEqual(cached, .notAvailable)
    }

    func testNotConfiguredSaysWhereToSetItUp() async {
        let server = MockRefineServer(settings: .success(DictationRefineSettings(configured: false)))
        let outcome = await makeProcessor(server).process("שלום", mode: .translate, sourceLanguage: "he")
        XCTAssertEqual(outcome.text, "שלום")
        XCTAssertEqual(outcome.status, .kept(.notConfigured))
        XCTAssertEqual(outcome.notice, "Set up translation in codeg Settings on your computer.")
        XCTAssertTrue(server.requests.isEmpty)
    }

    func testAKeyStoreErrorIsNotSetUp() async {
        let server = MockRefineServer(settings: .success(DictationRefineSettings(
            configured: true, keyError: "the keychain is locked")))
        let processor = makeProcessor(server)
        let outcome = await processor.process("שלום", mode: .translate, sourceLanguage: "he")
        XCTAssertEqual(outcome.status, .kept(.notConfigured))
        XCTAssertEqual(outcome.notice, "Set up translation in codeg Settings on your computer.")
        XCTAssertTrue(server.requests.isEmpty)
        let availability = await processor.availability(maxAge: 300)
        XCTAssertEqual(availability, .notConfigured(keyError: "the keychain is locked"))
    }

    func testAMissingConfigurationErrorIsNotConfigured() async {
        let server = MockRefineServer(refine: .failure(APIError.server(
            status: 422, code: "configuration_missing", message: "No provider")))
        let outcome = await makeProcessor(server).process("שלום", mode: .cleanUp, sourceLanguage: "he")
        XCTAssertEqual(outcome.status, .kept(.notConfigured))
    }

    func testUnreachableSettingsStillTryTheRefine() async {
        let server = MockRefineServer(settings: .failure(APIError.transport("The request timed out.")))
        let outcome = await makeProcessor(server).process("שלום", mode: .translate, sourceLanguage: "he")
        XCTAssertEqual(outcome.text, "Hello world")
        XCTAssertEqual(server.requests.count, 1)
    }

    func testSkippingKeepsTheWordsQuietly() async {
        let server = MockRefineServer(refineDelay: .seconds(10))
        let processor = makeProcessor(server)
        let task = Task { await processor.process("שלום", mode: .translate, sourceLanguage: "he") }
        try? await Task.sleep(for: .milliseconds(100))
        task.cancel()
        let outcome = await task.value
        XCTAssertEqual(outcome.text, "שלום")
        XCTAssertEqual(outcome.status, .kept(.skipped))
        XCTAssertNil(outcome.notice)
    }
}

final class DictationRefineWireTests: XCTestCase {
    func testLanguagesGoOutAsNames() {
        let request = DictationRefineRequest(text: "hi", mode: .translate, sourceLanguage: "en")
        XCTAssertEqual(request.sourceLanguage, "English")
        XCTAssertEqual(request.targetLanguage, "English")
        XCTAssertNil(DictationRefineRequest(text: "hi", mode: .cleanUp, sourceLanguage: nil).sourceLanguage)
    }

    func testRequestBodyUsesTheWireNames() throws {
        let body = try DictationRefineRequest(text: "שלום", mode: .cleanUp, sourceLanguage: nil).jsonBody()
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["text", "refine", "translate", "targetLanguage", "sourceLanguage"])
        XCTAssertEqual(object["text"] as? String, "שלום")
        XCTAssertEqual(object["refine"] as? Bool, true)
        XCTAssertEqual(object["translate"] as? Bool, false)
        XCTAssertTrue(object["targetLanguage"] is NSNull)
        XCTAssertTrue(object["sourceLanguage"] is NSNull)
    }

    func testSettingsDecodeInEitherCasing() throws {
        let snake = """
        {"configured": true, "providers": [{"id": "groq", "label": "Groq", "has_key": true,
         "default_model": "llama-3.3-70b"}], "provider": "groq", "model": null,
         "target_language": "en", "refine": true, "translate": false, "instructions": "", "key_error": null}
        """
        let camel = """
        {"provider": "groq", "model": "", "endpoint": "", "targetLanguage": "en", "refine": true,
         "translate": true, "instructions": "", "configured": true,
         "providers": [{"id": "groq", "label": "Groq", "hasKey": true, "defaultModel": "llama-3.3-70b"},
                       {"id": "google", "label": "Google Cloud Translation", "hasKey": false, "defaultModel": null}],
         "keyError": null}
        """
        for json in [snake, camel] {
            let settings = try CodegJSON.decoder.decode(DictationRefineSettings.self, from: Data(json.utf8))
            XCTAssertTrue(settings.configured)
            XCTAssertTrue(settings.isSetUp)
            XCTAssertNil(settings.keyError)
            XCTAssertEqual(settings.providers.first, DictationRefineProvider(
                id: "groq", label: "Groq", hasKey: true, defaultModel: "llama-3.3-70b"))
            XCTAssertEqual(settings.targetLanguage, "en")
            XCTAssertEqual(settings.summary, "Groq · llama-3.3-70b")
        }
        let empty = try CodegJSON.decoder.decode(DictationRefineSettings.self, from: Data("{}".utf8))
        XCTAssertFalse(empty.configured)
        let locked = try CodegJSON.decoder.decode(DictationRefineSettings.self,
                                                  from: Data(#"{"configured": true, "keyError": "locked"}"#.utf8))
        XCTAssertFalse(locked.isSetUp)
    }

    func testResultDecodes() throws {
        let json = #"{"text": "Hello", "provider": "groq", "model": "m", "elapsed_ms": 312}"#
        let result = try CodegJSON.decoder.decode(DictationRefineResult.self, from: Data(json.utf8))
        XCTAssertEqual(result, DictationRefineResult(text: "Hello", provider: "groq", model: "m", elapsedMs: 312))
    }

    func testWhichErrorsMeanAnOlderServer() {
        XCTAssertTrue(DictationRefineWire.isNotAvailable(APIError.server(status: 501, code: "not_implemented", message: "")))
        XCTAssertTrue(DictationRefineWire.isNotAvailable(APIError.server(status: 404, code: nil, message: "")))
        XCTAssertFalse(DictationRefineWire.isNotAvailable(APIError.server(status: 500, code: nil, message: "")))
        XCTAssertFalse(DictationRefineWire.isNotAvailable(APIError.transport("offline")))
        XCTAssertFalse(DictationRefineWire.isNotAvailable(APIError.unauthorized))
        XCTAssertTrue(DictationRefineWire.isNotConfigured(APIError.server(status: 422, code: "configuration_missing", message: "")))
        XCTAssertFalse(DictationRefineWire.isNotConfigured(APIError.server(status: 422, code: "configuration_invalid", message: "")))
        XCTAssertFalse(DictationRefineWire.isNotConfigured(APIError.server(status: 422, code: "authentication_failed", message: "")))
    }

    func testTheStripChipCyclesTheModes() {
        XCTAssertEqual(DictationRefineMode.asSpoken.next, .cleanUp)
        XCTAssertEqual(DictationRefineMode.cleanUp.next, .translate)
        XCTAssertEqual(DictationRefineMode.translate.next, .asSpoken)
    }
}
