import XCTest
@testable import Codeg

/// The Camera Control's pre-roll: the last 1.5 s of microphone audio, kept
/// in memory while standing by and handed to the recording a press starts.
final class AudioRingBufferTests: XCTestCase {
    func testKeepsSamplesInOrderUntilFull() {
        var ring = AudioRingBuffer(capacity: 5)
        XCTAssertEqual(ring.contents, [])
        ring.append(contentsOf: [1, 2, 3])
        XCTAssertEqual(ring.contents, [1, 2, 3])
        XCTAssertEqual(ring.count, 3)
    }

    func testWrapsAroundKeepingTheNewest() {
        var ring = AudioRingBuffer(capacity: 5)
        ring.append(contentsOf: [1, 2, 3])
        ring.append(contentsOf: [4, 5, 6, 7])
        XCTAssertEqual(ring.contents, [3, 4, 5, 6, 7])
        ring.append(contentsOf: [8])
        XCTAssertEqual(ring.contents, [4, 5, 6, 7, 8])
        // Many small appends around the end of the storage.
        for value in 9...23 { ring.append(contentsOf: [Float(value)]) }
        XCTAssertEqual(ring.contents, [19, 20, 21, 22, 23])
        XCTAssertEqual(ring.count, 5)
    }

    func testAChunkLongerThanTheBufferKeepsItsTail() {
        var ring = AudioRingBuffer(capacity: 4)
        ring.append(contentsOf: [1, 2])
        ring.append(contentsOf: (3...12).map(Float.init))
        XCTAssertEqual(ring.contents, [9, 10, 11, 12])
    }

    func testRemoveAllEmptiesIt() {
        var ring = AudioRingBuffer(capacity: 3)
        ring.append(contentsOf: [1, 2, 3, 4])
        ring.removeAll()
        XCTAssertEqual(ring.contents, [])
        ring.append(contentsOf: [5])
        XCTAssertEqual(ring.contents, [5])
    }

    func testTheRecorderKeepsOneAndAHalfSeconds() {
        XCTAssertEqual(DictationRecorder.preRollSeconds, 1.5)
        let buffer = RecordingBuffer(preRollSamples: Int(DictationRecorder.preRollSeconds * DictationRecorder.sampleRate),
                                     maxSamples: 10)
        XCTAssertEqual(buffer.preRoll.capacity, 24_000)
    }
}

final class RecordingBufferTests: XCTestCase {
    func testAPressStartsWithThePreRollThenCarriesOnLive() {
        var buffer = RecordingBuffer(preRollSamples: 4, maxSamples: 100)
        // Standing by: only the last four samples survive.
        buffer.receive([1, 2, 3])
        buffer.receive([4, 5, 6])
        XCTAssertFalse(buffer.isRecording)
        XCTAssertEqual(buffer.samples, [])
        XCTAssertEqual(buffer.preRoll.contents, [3, 4, 5, 6])

        buffer.beginRecording(includePreRoll: true)
        XCTAssertTrue(buffer.isRecording)
        XCTAssertEqual(buffer.samples, [3, 4, 5, 6])
        XCTAssertEqual(buffer.preRoll.contents, [], "the pre-roll is handed over, not kept twice")
        buffer.receive([7, 8])
        buffer.receive([9])
        XCTAssertEqual(buffer.samples, [3, 4, 5, 6, 7, 8, 9])

        // Back to standby: the next pre-roll starts empty.
        XCTAssertEqual(buffer.endRecording(), [3, 4, 5, 6, 7, 8, 9])
        XCTAssertFalse(buffer.isRecording)
        XCTAssertEqual(buffer.samples, [])
        XCTAssertEqual(buffer.preRoll.contents, [])
        buffer.receive([10])
        XCTAssertEqual(buffer.preRoll.contents, [10])
    }

    func testWithoutThePreRollTheRecordingStartsLive() {
        var buffer = RecordingBuffer(preRollSamples: 4, maxSamples: 100)
        buffer.receive([1, 2, 3])
        buffer.beginRecording(includePreRoll: false)
        XCTAssertEqual(buffer.samples, [])
        XCTAssertEqual(buffer.preRoll.contents, [])
        buffer.receive([4])
        XCTAssertEqual(buffer.endRecording(), [4])
    }

    func testTheRecordingStopsGrowingAtTheLimit() {
        var buffer = RecordingBuffer(preRollSamples: 3, maxSamples: 5)
        buffer.receive([1, 2, 3])
        buffer.beginRecording(includePreRoll: true)
        buffer.receive([4, 5, 6, 7])
        XCTAssertEqual(buffer.samples, [1, 2, 3, 4, 5])
        buffer.receive([8])
        XCTAssertEqual(buffer.samples, [1, 2, 3, 4, 5])
    }

    func testResetDropsEverything() {
        var buffer = RecordingBuffer(preRollSamples: 3, maxSamples: 10)
        buffer.receive([1, 2])
        buffer.beginRecording(includePreRoll: true)
        buffer.receive([3])
        buffer.reset()
        XCTAssertFalse(buffer.isRecording)
        XCTAssertEqual(buffer.samples, [])
        XCTAssertEqual(buffer.preRoll.contents, [])
    }
}
