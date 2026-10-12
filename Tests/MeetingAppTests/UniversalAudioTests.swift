import XCTest

@testable import MeetingAssist

final class UniversalAudioTests: XCTestCase {
    @MainActor
    func testSilentFramesAndStoppedCaptureDoNotReportSound() {
        let model = MeetingModel()
        model.framesReceived = 50
        XCTAssertNil(model.audioInputStatus)
        model.listening = true
        XCTAssertEqual(model.audioInputStatus, "Waiting for speech")
        model.level = 0.2
        XCTAssertEqual(model.audioInputStatus, "Sound detected")
        model.stop()
        XCTAssertNil(model.audioInputStatus)
    }
    func testSmallCaptureCallbacksAreBatchedWithoutLosingAudio() {
        var batcher = PCMFrameBatcher()
        let values = [Int16](repeating: 3277, count: 240)
        let data = values.withUnsafeBytes { Data($0) }
        let end = Date(timeIntervalSince1970: 100)
        let frame = AudioFrame(pcm: data, rms: 0.1, seconds: 0.01, microphone: false, capturedAt: end)
        for _ in 0..<3 { XCTAssertTrue(batcher.append(frame).isEmpty) }
        let output = batcher.append(frame)
        XCTAssertEqual(output.count, 1)
        XCTAssertEqual(output[0].pcm, data + data + data + data)
        XCTAssertEqual(output[0].rms, 0.1, accuracy: 0.001)
        XCTAssertEqual(output[0].seconds, 0.04)
        XCTAssertEqual(output[0].capturedAt, end)
        XCTAssertFalse(output[0].microphone)
        XCTAssertTrue(batcher.append(frame).isEmpty)
    }
    func testLargeCaptureCallbackPreservesPacketOrderRemainderAndTimestamps() {
        var batcher = PCMFrameBatcher()
        let values = (0..<2400).map { Int16($0) }
        let data = values.withUnsafeBytes { Data($0) }
        let end = Date(timeIntervalSince1970: 100)
        let output = batcher.append(
            AudioFrame(pcm: data, rms: 0.1, seconds: 0.1, microphone: true, capturedAt: end))
        XCTAssertEqual(output.count, 2)
        XCTAssertEqual(output[0].pcm + output[1].pcm, Data(data.prefix(3840)))
        XCTAssertTrue(output.allSatisfy(\.microphone))
        XCTAssertEqual(output[0].capturedAt.timeIntervalSince(end), -0.06, accuracy: 0.001)
        XCTAssertEqual(output[1].capturedAt.timeIntervalSince(end), -0.02, accuracy: 0.001)
        let tail = Data(repeating: 0, count: 960)
        let next = batcher.append(AudioFrame(pcm: tail, rms: 0, seconds: 0.02, microphone: true))
        XCTAssertEqual(next[0].pcm, Data(data.suffix(960)) + tail)
    }
    func testEmptyAndMalformedPCMDoNotProducePackets() {
        var batcher = PCMFrameBatcher()
        XCTAssertTrue(batcher.append(AudioFrame(pcm: Data(), rms: 0, seconds: 0, microphone: false)).isEmpty)
        XCTAssertTrue(
            batcher.append(AudioFrame(pcm: Data([1]), rms: 0, seconds: 0, microphone: false)).isEmpty)
    }
}
