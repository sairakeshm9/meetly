import Combine
import MeetingCore
import XCTest

@testable import MeetingAssist

@MainActor
private final class FakeLocalRecognizer: LocalSpeechRecognizing {
    var activity: (@MainActor (String, Bool) -> Void)?
    var receive: (@MainActor (LocalSpeechEvent) -> Void)?
    var failure: (@MainActor (String) -> Void)?
    var starts = 0
    var stops = 0
    var held: CheckedContinuation<Void, Never>?
    var hold = false
    var reject = false
    func start(
        receive: @escaping @MainActor (LocalSpeechEvent) -> Void,
        failure: @escaping @MainActor (String) -> Void
    ) async throws {
        starts += 1
        self.receive = receive
        self.failure = failure
        if hold { await withCheckedContinuation { held = $0 } }
        if reject { throw MeetingError.message("Microphone access denied") }
    }
    func stop() { stops += 1 }
}

@MainActor
final class SpeechFollowingTests: XCTestCase {
    let explanation =
        "Constructor injection makes dependencies testable.\nDatabase constraints prevent duplicate payment events."
    func prepared(_ controller: SpeechFollowingController) async {
        let ready = expectation(description: "answer indexed")
        var fired = false
        let observer = controller.$document.sink {
            if !$0.passages.isEmpty, !fired {
                fired = true
                ready.fulfill()
            }
        }
        await fulfillment(of: [ready], timeout: 3)
        observer.cancel()
    }
    func ready(_ controller: SpeechFollowingController) async {
        let ready = expectation(description: "local recognizer ready")
        var fired = false
        let observer = controller.$starting.sink {
            if !$0, controller.enabled, !fired {
                fired = true
                ready.fulfill()
            }
        }
        controller.setEnabled(true)
        await fulfillment(of: [ready], timeout: 2)
        if !controller.document.passages.isEmpty {} else { await prepared(controller) }
        observer.cancel()
    }
    func testOffByDefaultAndNoCredentialsOrMeetingCaptureNeeded() async {
        let source = FakeLocalRecognizer()
        let controller = SpeechFollowingController(recognizer: source)
        XCTAssertFalse(controller.enabled)
        XCTAssertEqual(source.starts, 0)
        controller.setAnswer(id: UUID(), text: explanation)
        await ready(controller)
        XCTAssertEqual(source.starts, 1)
        source.receive?(
            .init(
                text: "Constructor injection makes dependencies testable", final: true,
                startedAt: .distantFuture))
        XCTAssertEqual(controller.progress.current, 0)
        XCTAssertEqual(controller.progress.covered, [0])
        XCTAssertTrue(controller.status.contains("passage 1/2"))
        controller.stop()
        source.receive?(
            .init(
                text: "Database constraints prevent duplicate payment events", final: true,
                startedAt: .distantFuture))
        XCTAssertEqual(controller.progress.current, 0)
        XCTAssertFalse(controller.enabled)
    }
    func testNewAnswerRejectsOldUtteranceAndRestoresSelectedHistoryPosition() async {
        var time = Date(timeIntervalSince1970: 10)
        let source = FakeLocalRecognizer()
        let controller = SpeechFollowingController(recognizer: source, now: { time })
        let first = UUID()
        controller.setAnswer(id: first, text: explanation)
        await ready(controller)
        source.receive?(
            .init(text: "Constructor injection makes dependencies testable", final: true, startedAt: time))
        XCTAssertEqual(controller.progress.current, 0)
        time = time.addingTimeInterval(5)
        let second = UUID()
        controller.setAnswer(id: second, text: explanation)
        await prepared(controller)
        source.receive?(
            .init(
                text: "Database constraints prevent duplicate payment events", final: true,
                startedAt: time.addingTimeInterval(-1)))
        XCTAssertNil(controller.progress.current)
        source.receive?(
            .init(text: "Database constraints prevent duplicate payment events", final: true, startedAt: time)
        )
        XCTAssertEqual(controller.progress.current, 1)
        controller.setAnswer(id: first, text: explanation)
        XCTAssertEqual(controller.progress.current, 0)
        XCTAssertEqual(controller.progress.covered, [0])
        controller.stop()
    }
    func testEchoManualPauseResumeAndRestart() async {
        var time = Date(timeIntervalSince1970: 10)
        let source = FakeLocalRecognizer()
        let controller = SpeechFollowingController(recognizer: source, now: { time })
        controller.setAnswer(id: UUID(), text: explanation)
        await ready(controller)
        controller.setReadAloud(true)
        source.receive?(
            .init(text: "Constructor injection makes dependencies testable", final: true, startedAt: time))
        XCTAssertNil(controller.progress.current)
        time = time.addingTimeInterval(5)
        controller.setReadAloud(false)
        source.receive?(
            .init(
                text: "Constructor injection makes dependencies testable", final: true,
                startedAt: time.addingTimeInterval(-1)))
        XCTAssertNil(controller.progress.current)
        source.receive?(
            .init(text: "Constructor injection makes dependencies testable", final: true, startedAt: time))
        controller.pauseScrolling()
        source.receive?(
            .init(text: "Database constraints prevent duplicate payment events", final: true, startedAt: time)
        )
        XCTAssertEqual(controller.progress.current, 1)
        XCTAssertTrue(controller.progress.manualPause)
        controller.resume()
        source.receive?(
            .init(text: "Database constraints prevent duplicate payment events", final: true, startedAt: time)
        )
        XCTAssertEqual(controller.progress.current, 1)
        controller.resetProgress()
        XCTAssertNil(controller.progress.current)
        XCTAssertTrue(controller.progress.covered.isEmpty)
        controller.clear()
        XCTAssertFalse(controller.enabled)
        XCTAssertTrue(controller.document.passages.isEmpty)
    }
    func testRepeatedPartialResultsAndWheelEventsPublishOnlyChangedProgress() async {
        let source = FakeLocalRecognizer()
        let controller = SpeechFollowingController(recognizer: source)
        controller.setAnswer(id: UUID(), text: explanation)
        await ready(controller)
        var publications = 0
        let observer = controller.$progress.dropFirst().sink { _ in publications += 1 }
        for _ in 0..<100 {
            source.receive?(
                .init(
                    text: "Constructor injection makes dependencies testable", final: false,
                    startedAt: .distantFuture))
        }
        XCTAssertEqual(publications, 1)
        for _ in 0..<100 { controller.pauseScrolling() }
        XCTAssertEqual(publications, 2, "Scrolling should pause once, without continuously rebuilding the UI")
        observer.cancel()
        controller.stop()
    }
    func testResumeAcceptsFreshWordsWithinUtteranceStartedBeforeBoundary() async {
        var time = Date(timeIntervalSince1970: 10)
        let source = FakeLocalRecognizer()
        let controller = SpeechFollowingController(recognizer: source, now: { time })
        controller.setAnswer(id: UUID(), text: explanation)
        await ready(controller)
        controller.pauseScrolling()
        time = time.addingTimeInterval(5)
        controller.resume()
        source.receive?(
            .init(
                text: explanation, final: true, startedAt: time.addingTimeInterval(-5),
                segments: [
                    .init(
                        text: "Constructor injection makes dependencies testable.",
                        startedAt: time.addingTimeInterval(-5)),
                    .init(text: "Database constraints prevent duplicate payment events.", startedAt: time),
                ]))
        XCTAssertEqual(controller.progress.current, 1)
        XCTAssertEqual(controller.progress.covered, [1])
        XCTAssertFalse(controller.inputStatus.heard.contains("Constructor"))
        controller.stop()
    }
    func testMicrophoneActivityAndTranscriptClearOnStopAndStaleCallbacksStayIgnored() async {
        let source = FakeLocalRecognizer()
        let controller = SpeechFollowingController(recognizer: source)
        controller.setAnswer(id: UUID(), text: explanation)
        await ready(controller)
        source.activity?("Test headset microphone", true)
        XCTAssertTrue(controller.inputStatus.active)
        XCTAssertEqual(controller.inputStatus.name, "Test headset microphone")
        source.receive?(
            .init(text: "Unrelated words do not match this answer", final: true, startedAt: .distantFuture))
        XCTAssertTrue(controller.progress.uncertain)
        XCTAssertFalse(controller.inputStatus.heard.isEmpty)
        controller.stop()
        source.activity?("Test headset microphone", true)
        XCTAssertFalse(controller.inputStatus.active)
        XCTAssertEqual(controller.inputStatus.heard, "")
    }
    func testLateStartAndOldRunCallbacksCannotRestartStoppedTracking() async {
        let source = FakeLocalRecognizer()
        source.hold = true
        let controller = SpeechFollowingController(recognizer: source)
        controller.setEnabled(true)
        let started = expectation(description: "started")
        Task { @MainActor in
            while source.held == nil { await Task.yield() }
            started.fulfill()
        }
        await fulfillment(of: [started], timeout: 2)
        let oldCallback = source.failure
        controller.stop()
        source.held?.resume()
        source.held = nil
        oldCallback?("Stale failure")
        XCTAssertFalse(controller.enabled)
        XCTAssertFalse(controller.issue)
        XCTAssertEqual(controller.status, "")
    }
    func testAudioFailureStopsFollowingButKeepsAnswerReadableAndCanRetry() async {
        let source = FakeLocalRecognizer()
        let controller = SpeechFollowingController(recognizer: source)
        controller.setAnswer(id: UUID(), text: explanation)
        await ready(controller)
        source.failure?("Microphone changed. Retry.")
        XCTAssertFalse(controller.enabled)
        XCTAssertTrue(controller.issue)
        XCTAssertFalse(controller.document.passages.isEmpty)
        await ready(controller)
        XCTAssertFalse(controller.issue)
        XCTAssertEqual(source.starts, 2)
        controller.stop()
    }
    func testPermissionFailureAndPositionHistoryBounds() async {
        let source = FakeLocalRecognizer()
        source.reject = true
        let controller = SpeechFollowingController(recognizer: source)
        let failed = expectation(description: "permission failure")
        let observer = controller.$issue.sink { if $0 { failed.fulfill() } }
        controller.setEnabled(true)
        await fulfillment(of: [failed], timeout: 2)
        observer.cancel()
        XCTAssertFalse(controller.enabled)
        XCTAssertTrue(controller.status.contains("denied"))
        let oldest = UUID()
        controller.setAnswer(id: oldest, text: explanation)
        source.reject = false
        await ready(controller)
        source.receive?(
            .init(
                text: "Constructor injection makes dependencies testable", final: true,
                startedAt: .distantFuture))
        for _ in 0..<15 { controller.setAnswer(id: UUID(), text: explanation) }
        controller.setAnswer(id: oldest, text: explanation)
        XCTAssertNil(controller.progress.current)
        controller.stop()
    }
}
