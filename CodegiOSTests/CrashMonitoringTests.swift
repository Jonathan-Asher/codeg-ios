import AVFoundation
import XCTest
@testable import Codeg

/// The microphone's format checks before `installTap`, the guard that turns
/// AVFAudio's exceptions into errors, and the crash reports: breadcrumbs,
/// what is scrubbed, and how MetricKit's JSON and exception stacks read.
final class MicrophoneFormatCheckTests: XCTestCase {
    private let mono48 = AudioFormatShape(sampleRate: 48_000, channelCount: 1)

    func testMatchingFormatsAreReady() {
        XCTAssertEqual(MicrophoneFormatCheck.evaluate(hardware: mono48, output: mono48, inputAvailable: true), .ready)
        // The node converts channels, so only the rate has to agree.
        let stereo48 = AudioFormatShape(sampleRate: 48_000, channelCount: 2)
        XCTAssertEqual(MicrophoneFormatCheck.evaluate(hardware: stereo48, output: mono48, inputAvailable: true), .ready)
    }

    /// The crash: AirPods' HFP microphone (24 kHz) left in the node while
    /// the iPhone's microphone (48 kHz) is the input now.
    func testARateMismatchIsNotTapped() {
        let stale = AudioFormatShape(sampleRate: 24_000, channelCount: 1)
        XCTAssertEqual(MicrophoneFormatCheck.evaluate(hardware: mono48, output: stale, inputAvailable: true),
                       .unavailable(.formatChanging))
    }

    func testEmptyFormatsAreNotTapped() {
        let noRate = AudioFormatShape(sampleRate: 0, channelCount: 1)
        let noChannels = AudioFormatShape(sampleRate: 48_000, channelCount: 0)
        let nan = AudioFormatShape(sampleRate: .nan, channelCount: 1)
        for (hardware, output) in [(noRate, mono48), (mono48, noChannels), (nan, mono48), (noChannels, noChannels)] {
            XCTAssertEqual(MicrophoneFormatCheck.evaluate(hardware: hardware, output: output, inputAvailable: true),
                           .unavailable(.emptyFormat))
        }
    }

    func testNoInputWins() {
        XCTAssertEqual(MicrophoneFormatCheck.evaluate(hardware: mono48, output: mono48, inputAvailable: false),
                       .unavailable(.noInput))
    }

    func testStaleNodeAgainstTheSession() {
        XCTAssertTrue(MicrophoneFormatCheck.isStale(node: AudioFormatShape(sampleRate: 24_000, channelCount: 1),
                                                    sessionSampleRate: 48_000))
        XCTAssertFalse(MicrophoneFormatCheck.isStale(node: mono48, sessionSampleRate: 48_000))
        // Nothing to compare with: not called stale.
        XCTAssertFalse(MicrophoneFormatCheck.isStale(node: mono48, sessionSampleRate: 0))
    }

    func testFormatErrorsReadAsPlainWords() {
        let text = AudioErrorText(DictationRecorder.RecorderError.format(.formatChanging))
        XCTAssertEqual(text.message("Couldn't start the microphone"),
                       "Couldn't start the microphone: the audio route changed as the microphone started, try again.")
        XCTAssertEqual(AudioErrorText(DictationRecorder.RecorderError.format(.noInput)).reason,
                       "no microphone is available")
    }
}

final class AVFAudioGuardTests: XCTestCase {
    func testAnObjectiveCExceptionBecomesAnError() {
        XCTAssertThrowsError(try AVFAudioGuard.run("test raise") {
            NSException(name: NSExceptionName("com.apple.coreaudio.avfaudio"),
                        reason: "required condition is false: format.sampleRate == hwFormat.sampleRate",
                        userInfo: nil).raise()
        }) { error in
            let caught = error as? AVFAudioException
            XCTAssertEqual(caught?.operation, "test raise")
            XCTAssertEqual(caught?.name, "com.apple.coreaudio.avfaudio")
            XCTAssertEqual(caught?.reason, "required condition is false: format.sampleRate == hwFormat.sampleRate")
            XCTAssertEqual(AudioErrorText(error).message("Couldn't start the microphone"),
                           "Couldn't start the microphone: the audio system refused the request, try again.")
        }
    }

    /// Real AVFAudio misuse, caught: a second tap on a bus that has one
    /// (AVFAudio's "nullptr == Tap()" precondition, the call family of the
    /// standby crash), and a player started while its engine is stopped.
    func testCatchesRealAVFAudioExceptions() throws {
        let engine = AVAudioEngine()
        let mixer = engine.mainMixerNode
        let player = AVAudioPlayerNode()
        engine.attach(player)
        engine.connect(player, to: mixer, format: nil)
        XCTAssertFalse(engine.isRunning)
        try AVFAudioGuard.run("first tap") { mixer.installTap(onBus: 0, bufferSize: 1024, format: nil) { _, _ in } }
        defer { try? AVFAudioGuard.run("remove tap") { mixer.removeTap(onBus: 0) } }
        var caught: [AVFAudioException] = []
        for (name, misuse) in [("second tap", { mixer.installTap(onBus: 0, bufferSize: 1024, format: nil) { _, _ in } }),
                               ("play on a stopped engine", { player.play() })] {
            do {
                try AVFAudioGuard.run(name, misuse)
            } catch let error as AVFAudioException {
                caught.append(error)
            }
        }
        if caught.isEmpty { throw XCTSkip("this iOS raised for none of the misuses") }
        XCTAssertTrue(caught.allSatisfy { !$0.name.isEmpty })
    }

    func testValuesAndSwiftErrorsPassThrough() throws {
        XCTAssertEqual(try AVFAudioGuard.run("value") { 42 }, 42)
        struct Plain: Error, Equatable {}
        XCTAssertThrowsError(try AVFAudioGuard.run("swift error") { throw Plain() }) { error in
            XCTAssertEqual(error as? Plain, Plain())
        }
    }
}

final class BreadcrumbTests: XCTestCase {
    func testTheRingKeepsTheNewestHundred() {
        var ring = BreadcrumbRing()
        for i in 0..<150 { ring.append(Breadcrumb(t: Int64(i), event: "e\(i)", detail: nil)) }
        XCTAssertEqual(ring.items.count, BreadcrumbRing.capacity)
        XCTAssertEqual(ring.items.first?.event, "e50")
        XCTAssertEqual(ring.items.last?.event, "e149")
    }

    func testDetailsKeepOnlyPlainCharacters() {
        let crumb = Breadcrumb(t: 0, event: "mic.start\n", detail: "standby in=MicrophoneBuiltIn \"quoted\" ?q=1&x שלום")
        XCTAssertEqual(crumb.event, "mic.start")
        XCTAssertEqual(crumb.detail, "standby in=MicrophoneBuiltIn quoted q=1x")
        XCTAssertNil(Breadcrumb(t: 0, event: "x", detail: "\"\"").detail)
        XCTAssertEqual(Breadcrumb(t: 0, event: "x", detail: String(repeating: "a", count: 500)).detail?.count, 120)
    }

    func testCaseNamesDropThePayload() {
        XCTAssertEqual(Breadcrumbs.caseName(CameraTalkController.Status.interrupted("Jonathan's private reason")),
                       "interrupted")
        XCTAssertEqual(Breadcrumbs.caseName(Route.conversation(12)), "conversation")
        XCTAssertEqual(Breadcrumbs.caseName(AppTab.chats), "chats")
    }
}

final class DiagnosticReportTests: XCTestCase {
    func testTheScrubberCutsPathsQueriesAndSecrets() {
        let scrubbed = DiagnosticScrubber.scrub(
            "open /var/mobile/Containers/Data/Application/AB12/Documents/notes.md failed; url https://host:3080/api/x?token=abc#frag; Bearer sk-12345 password=hunter2",
            max: 1000)
        XCTAssertFalse(scrubbed.contains("notes.md"))
        XCTAssertFalse(scrubbed.contains("abc"))
        XCTAssertFalse(scrubbed.contains("sk-12345"))
        XCTAssertFalse(scrubbed.contains("hunter2"))
        XCTAssertTrue(scrubbed.contains("<path>"))
        XCTAssertTrue(scrubbed.contains("https://host:3080/api/x?<redacted>"))
        XCTAssertEqual(DiagnosticScrubber.scrub("required condition is false: format.sampleRate == hwFormat.sampleRate", max: 1000),
                       "required condition is false: format.sampleRate == hwFormat.sampleRate")
        XCTAssertEqual(DiagnosticScrubber.scrub(String(repeating: "x ", count: 100), max: 10).count, 11)
        // A word like "key" in a reason is not a credential.
        XCTAssertEqual(DiagnosticScrubber.scrub("not key value coding-compliant for the key title", max: 200),
                       "not key value coding-compliant for the key title")
    }

    /// `callStackSymbols` as the crash raised it: the frames that matter
    /// start two above the app's own.
    func testExceptionFramesFocusOnTheAppsCall() {
        let symbols = [
            "0   CoreFoundation                      0x00000001966728e0 __exceptionPreprocess + 164",
            "1   libobjc.A.dylib                     0x00000001963f0380 objc_exception_throw + 88",
            "2   CoreFoundation                      0x00000001966ed5e4 +[NSException raise:format:] + 128",
            "3   AVFAudio                            0x00000001d7d37f30 AVFAudio + 458544",
            "4   AVFAudio                            0x00000001d7dac3bc AVFAudio + 934844",
            "5   Codeg                               0x0000000104d98448 Codeg + 2437700",
            "6   Codeg                               0x0000000104c6822c Codeg + 1365544",
        ]
        XCTAssertEqual(DiagnosticReport.topFrames(fromSymbols: symbols, appBinary: "Codeg"),
                       ["AVFAudio +458544", "AVFAudio +934844", "Codeg +2437700", "Codeg +1365544"])
    }

    func testAnExceptionReport() throws {
        let report = DiagnosticReport.exception(
            kind: "caught_exception", source: "audio_guard", name: "com.apple.coreaudio.avfaudio",
            reason: "required condition is false: nullptr == Tap()", symbols: [], addresses: [0x104d98448],
            occurredAt: Date(timeIntervalSince1970: 0), context: "install the microphone tap",
            app: .init(version: "1.3.19", build: "105", bundleId: "io.ashurov.codeg"),
            device: .init(model: "iPhone18,2", os: "iOS 27.2 (24B5089g)"),
            image: .init(name: "Codeg", uuid: "F4831FCC-086B-3337-BD9E-AFCB958BD693", loadAddress: "0x1045fc000"),
            breadcrumbs: [Breadcrumb(t: 1, event: "mic.start", detail: "standby")], breadcrumbsFrom: "this_launch")
        XCTAssertEqual(report.stackAddresses, ["0x104d98448"])
        XCTAssertEqual(report.summary.context, "install the microphone tap")
        let body = try XCTUnwrap(DiagnosticsUploader.wrap(try JSONEncoder().encode(report)))
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        let inner = try XCTUnwrap(object["report"] as? [String: Any])
        XCTAssertEqual(inner["kind"] as? String, "caught_exception")
        XCTAssertEqual((inner["app"] as? [String: Any])?["build"] as? String, "105")
        XCTAssertEqual((inner["binaryImages"] as? [[String: Any]])?.first?["uuid"] as? String,
                       "F4831FCC-086B-3337-BD9E-AFCB958BD693")
    }

    /// A crash as MetricKit's `jsonRepresentation()` gives it: the crashing
    /// thread's innermost frame first, each caller as its first sub-frame.
    func testAMetricKitCrash() throws {
        func frame(_ name: String, _ offset: Int, _ sub: [String: Any]?) -> [String: Any] {
            var f: [String: Any] = ["binaryName": name, "binaryUUID": "UUID-\(name)",
                                    "offsetIntoBinaryTextSegment": offset, "sampleCount": 1, "address": 1]
            if let sub { f["subFrames"] = [sub] }
            return f
        }
        var chain: [String: Any]? = nil
        for (name, offset) in [("libswift_Concurrency.dylib", 30861), ("Codeg", 1365544), ("Codeg", 2437700),
                               ("AVFAudio", 934844), ("AVFAudio", 458544), ("CoreFoundation", 1123812),
                               ("libobjc.A.dylib", 50408), ("whisper", 10), ("libc++abi.dylib", 15772),
                               ("libsystem_c.dylib", 498028), ("libsystem_pthread.dylib", 29788),
                               ("libsystem_kernel.dylib", 45564)] {
            chain = frame(name, offset, chain)
        }
        let json: [String: Any] = [
            "callStackTree": ["callStackPerThread": true,
                              "callStacks": [["threadAttributed": false, "callStackRootFrames": [frame("Other", 1, nil)]],
                                             ["threadAttributed": true, "callStackRootFrames": [chain!]]]],
            "diagnosticMetaData": [
                "appVersion": "1.3.14", "appBuildVersion": "93", "bundleIdentifier": "io.ashurov.codeg",
                "deviceType": "iPhone18,2", "osVersion": "iPhone OS 27.2 (24B5089g)", "exceptionType": 10,
                "signal": 6, "exceptionCode": 0, "terminationReason": "Namespace SIGNAL, Code 6 Abort trap: 6",
                "virtualMemoryRegionInfo": "mapped file /private/var/containers/Bundle/Application/X/Codeg.app/Codeg",
                "objectiveCexceptionReason": ["composedMessage": "required condition is false: format.sampleRate == hwFormat.sampleRate",
                                              "exceptionName": "com.apple.coreaudio.avfaudio", "className": "NSException",
                                              "exceptionType": "ObjectiveC", "arguments": [], "formatString": "%s"],
            ],
        ]
        let value = DiagnosticJSON(any: json)
        let report = DiagnosticReport.metricKit(kind: "crash", json: value, occurredAt: nil, breadcrumbs: [],
                                                breadcrumbsFrom: nil)
        XCTAssertEqual(report.app.version, "1.3.14")
        XCTAssertEqual(report.app.build, "93")
        XCTAssertEqual(report.device.os, "iOS 27.2 (24B5089g)")
        XCTAssertEqual(report.summary.exceptionType, "EXC_CRASH")
        XCTAssertEqual(report.summary.signal, "SIGABRT")
        XCTAssertEqual(report.summary.exceptionName, "com.apple.coreaudio.avfaudio")
        XCTAssertEqual(report.summary.reason, "required condition is false: format.sampleRate == hwFormat.sampleRate")
        // From two frames above the app's own, past the abort machinery.
        XCTAssertEqual(report.summary.topFrames, ["AVFAudio +458544", "AVFAudio +934844", "Codeg +2437700",
                                                  "Codeg +1365544", "libswift_Concurrency.dylib +30861"])
        // The raw payload goes along, scrubbed.
        let region = report.metricKit?["diagnosticMetaData"]?["virtualMemoryRegionInfo"]?.string
        XCTAssertEqual(region, "mapped file <path>")
        XCTAssertEqual(report.metricKit?["callStackTree"]?["callStackPerThread"], .bool(true))
    }

    func testJSONValueKeepsBooleansAndNumbersApart() throws {
        let value = DiagnosticJSON(any: try JSONSerialization.jsonObject(with: Data(#"{"a":true,"b":1,"c":2.5,"d":[null,"x"]}"#.utf8)))
        XCTAssertEqual(value["a"], .bool(true))
        XCTAssertEqual(value["b"], .number(1))
        XCTAssertEqual(value["c"], .number(2.5))
        XCTAssertEqual(value["d"], .array([.null, .string("x")]))
        XCTAssertEqual(try JSONDecoder().decode(DiagnosticJSON.self, from: try JSONEncoder().encode(value)), value)
    }
}
