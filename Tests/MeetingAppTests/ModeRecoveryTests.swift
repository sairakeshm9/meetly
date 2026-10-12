import Combine
import MeetingCore
import XCTest

@testable import MeetingAssist

final class FeatureAudioCapture: MeetingAudioCapturing {
    var onFailure: ((String) -> Void)?
    var continuation: AsyncStream<AudioFrame>.Continuation?
    var startCount = 0
    func start(microphone: Bool) async throws -> AsyncStream<AudioFrame> {
        startCount += 1
        let channel = AsyncStream<AudioFrame>.makeStream()
        continuation = channel.continuation
        return channel.stream
    }
    func stop() async {
        continuation?.finish()
        continuation = nil
    }
}

@MainActor
final class ModeRecoveryTests: XCTestCase {
    func testStaticScreenGuidanceDoesNotRequireAnotherCaptureFrame() async throws {
        let capture = FeatureScreenCapture()
        let screen = ScreenContextController(
            captureFactory: { capture },
            analyzer: { _ in
                ScreenSnapshot(jpeg: Data([1]), text: "public class Main {}", capturedAt: Date())
            })
        var clock = Date()
        let scheduled = expectation(description: "quiet pause scheduled")
        var release: CheckedContinuation<Void, Never>?
        let guided = expectation(description: "single frame triggers guidance after pause")
        let model = MeetingModel(
            credentials: CredentialAccess { "test-only" }, now: { clock },
            screenPause: { seconds in
                XCTAssertEqual(seconds, 2)
                scheduled.fulfill()
                await withCheckedContinuation { release = $0 }
            }, screen: screen,
            answerStreamer: { request, delta in
                XCTAssertEqual(request.screenImage, Data([1]))
                delta("SAY THIS: Continue the loop. EXAMPLE: Swap two characters.")
                guided.fulfill()
            })
        model.hasKey = true
        model.mode = .coding
        model.codingTask = "Reverse a string"
        let enabled = expectation(description: "screen enabled")
        let observer = screen.$enabled.dropFirst().sink { if $0 { enabled.fulfill() } }
        model.setScreenWatching(true)
        await fulfillment(of: [enabled], timeout: 2)
        observer.cancel()
        capture.frame?(try ScreenContextTests.image())
        await fulfillment(of: [scheduled], timeout: 2)
        clock.addTimeInterval(3)
        release?.resume()
        await fulfillment(of: [guided], timeout: 2)
        model.setScreenWatching(false)
        model.stop()
    }
    func testTypingGuidanceWaitsForStableChangesAndViewerQuestionTakesPriority() async throws {
        let socket = MockSocket()
        let client = LiveTranscriber { _ in socket }
        try await client.connect(key: "test-only", model: "gpt-live-transcribe")
        let capture = FeatureScreenCapture()
        var code = "public class Main { return input; }"
        let screen = ScreenContextController(
            captureFactory: { capture },
            analyzer: { _ in
                ScreenSnapshot(jpeg: Data([1]), text: code, capturedAt: Date())
            })
        var clock = Date()
        var requests: [AnswerRequest] = []
        var releaseGuide: CheckedContinuation<Void, Never>?
        let guideStarted = expectation(description: "stable screen starts guidance")
        let model = MeetingModel(
            credentials: CredentialAccess { "test-only" }, meetingClient: client,
            now: { clock }, screen: screen,
            answerStreamer: { request, delta in
                requests.append(request)
                if request.question.hasPrefix("Review the current") {
                    guideStarted.fulfill()
                    await withCheckedContinuation { releaseGuide = $0 }
                    delta("stale guidance")
                } else {
                    delta("SAY THIS: Use a loop. EXAMPLE: hello becomes olleh.")
                }
            })
        model.hasKey = true
        model.listening = true
        model.mode = .advancedCoding
        model.codingTask = "Write Java code to reverse a string"
        let enabled = expectation(description: "capture enabled")
        let enabledObserver = screen.$enabled.dropFirst().sink { if $0 { enabled.fulfill() } }
        model.setScreenWatching(true)
        await fulfillment(of: [enabled], timeout: 2)
        enabledObserver.cancel()
        func frame() async throws {
            let received = expectation(description: "frame analyzed")
            let observer = screen.$snapshot.dropFirst().sink { if $0 != nil { received.fulfill() } }
            capture.frame?(try ScreenContextTests.image())
            await fulfillment(of: [received], timeout: 2)
            observer.cancel()
            // The callback follows publication on the same actor; a fresh frame starts only afterward.
            await Task.yield()
        }
        try await frame()
        clock.addTimeInterval(1)
        try await frame()
        XCTAssertTrue(requests.isEmpty)
        clock.addTimeInterval(2)
        try await frame()
        await fulfillment(of: [guideStarted], timeout: 2)
        XCTAssertTrue(model.guiding)
        XCTAssertEqual(requests.first?.screenImage, Data([1]))
        let interrupted = expectation(description: "viewer interruption answered")
        let observer = model.$cards.sink { cards in
            if cards.first?.question == "Why use a loop?", cards.first?.finished == true {
                interrupted.fulfill()
            }
        }
        socket.push([
            "type": "conversation.item.input_audio_transcription.completed",
            "item_id": "interruption", "transcript": "Why use a loop?",
        ])
        await fulfillment(of: [interrupted], timeout: 2)
        observer.cancel()
        XCTAssertFalse(model.guiding)
        XCTAssertEqual(model.codingTask, "Write Java code to reverse a string")
        releaseGuide?.resume()
        clock.addTimeInterval(10)
        try await frame()
        XCTAssertEqual(requests.count, 2, "Unchanged code must not repeat guidance")
        XCTAssertFalse(model.activeCard?.answer.contains("stale guidance") == true)
        // A code edit restarts the quiet period; it must not guide immediately.
        code = "public class Main { return result; }"
        try await frame()
        XCTAssertEqual(requests.count, 2)
        model.stop()
        screen.stop()
    }
    private func finished(_ model: MeetingModel, action: () -> Void) async {
        let done = expectation(description: "answer finished")
        var recorded = false
        let observer = model.$cards.sink { cards in
            if cards.first?.finished == true, !recorded {
                recorded = true
                done.fulfill()
            }
        }
        action()
        await fulfillment(of: [done], timeout: 2)
        observer.cancel()
    }
    func testCodingTaskSurvivesInterruptionAndOnlyThreeQuestionsAreSent() async {
        var requests: [AnswerRequest] = []
        let model = MeetingModel(
            credentials: CredentialAccess { "test-only" },
            screen: ScreenContextController(captureFactory: { FeatureScreenCapture() }),
            answerStreamer: { request, delta in
                requests.append(request)
                delta("SAY THIS: Use **constructor injection**. EXAMPLE: A Java constructor.")
            })
        model.hasKey = true
        model.mode = .coding
        model.setScreenWatching(false)  // This test exercises the text/editor-only path.
        let questions = [
            "Write Java code to reverse a string", "Why?", "What is its complexity?", "Without built-ins",
            "An example",
        ]
        for question in questions {
            // Clear the previous completion signal; the observer targets the new card below.
            let done = expectation(description: question)
            var recorded = false
            let observer = model.$cards.sink { cards in
                if cards.first?.question == question, cards.first?.finished == true, !recorded {
                    recorded = true
                    done.fulfill()
                }
            }
            model.ask(question)
            await fulfillment(of: [done], timeout: 2)
            observer.cancel()
        }
        XCTAssertEqual(model.codingTask, questions[0])
        XCTAssertEqual(requests.last?.mode, .coding)
        XCTAssertEqual(requests.last?.codingTask, questions[0])
        XCTAssertEqual(requests.last?.context.components(separatedBy: "Meeting question:").count, 4)
        XCTAssertFalse(requests.last?.context.contains("Meeting question: " + questions[0]) == true)
        model.finishCodingTask()
        XCTAssertTrue(model.codingTask.isEmpty)
    }
    func testUnclearLocalQuestionDoesNotCallProviderAndModelClarificationAcceptsY() async {
        var questions: [String] = []
        let model = MeetingModel(
            credentials: CredentialAccess { "test-only" },
            screen: ScreenContextController(captureFactory: { FeatureScreenCapture() }),
            answerStreamer: { request, delta in
                questions.append(request.question)
                delta(
                    request.question == "Y"
                        ? "SAY THIS: Use Java. EXAMPLE: A class."
                        : "ISSUE: Task input is missing.\nQUESTION: Should I use the standard example? (Y/N)")
            })
        model.hasKey = true
        model.ask("Can you")
        XCTAssertTrue(model.error?.contains("incomplete") == true)
        XCTAssertTrue(questions.isEmpty)
        await finished(model) { model.ask("Write a parser for this input") }
        XCTAssertNotNil(model.clarification)
        let replied = expectation(description: "yes answer finished")
        let observer = model.$cards.sink { cards in
            if cards.first?.question == "Y", cards.first?.finished == true { replied.fulfill() }
        }
        model.answerClarification(true)
        await fulfillment(of: [replied], timeout: 2)
        observer.cancel()
        XCTAssertNil(model.clarification)
        XCTAssertEqual(questions, ["Write a parser for this input", "Y"])
    }
    func testRefreshRetriesInterruptedAnswerAndPreservesResumeAndTask() async {
        var attempts = 0
        let model = MeetingModel(
            credentials: CredentialAccess { "test-only" },
            screen: ScreenContextController(captureFactory: { FeatureScreenCapture() }),
            answerStreamer: { _, delta in
                attempts += 1
                if attempts == 1 {
                    delta("SAY THIS: partial")
                    throw MeetingError.message("Answer connection ended early.")
                }
                delta("SAY THIS: Use a loop. EXAMPLE: Reverse hello to olleh.")
            })
        model.hasKey = true
        model.mode = .coding
        model.setScreenWatching(false)  // This test exercises the text/editor-only path.
        model.resumeName = "Synthetic.txt"
        model.projectNotes = "Synthetic known incident"
        let interrupted = expectation(description: "first request interrupted")
        let observer = model.$cards.sink { cards in
            if cards.first?.interrupted == true { interrupted.fulfill() }
        }
        model.ask("Write a Java string reversal function")
        await fulfillment(of: [interrupted], timeout: 2)
        observer.cancel()
        let retried = expectation(description: "retried request completed")
        var recorded = false
        let retryObserver = model.$cards.sink { cards in
            if cards.first?.finished == true, !recorded {
                recorded = true
                retried.fulfill()
            }
        }
        model.recoverSession()
        await fulfillment(of: [retried], timeout: 2)
        retryObserver.cancel()
        XCTAssertEqual(attempts, 2)
        XCTAssertEqual(model.resumeName, "Synthetic.txt")
        XCTAssertEqual(model.projectNotes, "Synthetic known incident")
        XCTAssertEqual(model.mode, .coding)
        XCTAssertEqual(model.codingTask, "Write a Java string reversal function")
        XCTAssertEqual(model.cards.count, 2)
    }
    func testRefreshReconnectsAndRetriesAllQueuedQuestionsWithoutOldAudioIDs() async throws {
        let old = MockSocket()
        let replacement = MockSocket()
        var sockets = [old, replacement]
        let client = LiveTranscriber { _ in sockets.removeFirst() }
        let audio = FeatureAudioCapture()
        var recovered: [AnswerRequest] = []
        let model = MeetingModel(
            credentials: CredentialAccess { "test-only" }, meetingClient: client, captureFactory: { audio },
            screen: ScreenContextController(captureFactory: { FeatureScreenCapture() }),
            answerStreamer: { request, delta in
                recovered.append(request)
                delta("SAY THIS: Keep updates atomic. EXAMPLE: Commit a transaction.")
            })
        model.hasKey = true
        model.microphone = false
        model.fastAnswers = true
        let listening = expectation(description: "first connection active")
        let observer = model.$listening.dropFirst().sink { if $0 { listening.fulfill() } }
        model.start()
        await fulfillment(of: [listening], timeout: 2)
        observer.cancel()
        let requested = expectation(description: "first question preparing")
        old.onSend = { if $0 == "response.create" { requested.fulfill() } }
        for (id, text) in [("one", "What is a transaction?"), ("two", "How does isolation work?")] {
            old.push(["type": "input_audio_buffer.committed", "item_id": id])
            old.push([
                "type": "conversation.item.input_audio_transcription.completed", "item_id": id,
                "transcript": text,
            ])
        }
        await fulfillment(of: [requested], timeout: 2)
        let drained = expectation(description: "all transcript events processed")
        let handler = client.onEvent
        client.onEvent = { event in
            handler?(event)
            if event == .ignored { drained.fulfill() }
        }
        old.push(["type": "rate_limits.updated"])
        await fulfillment(of: [drained], timeout: 2)
        client.onEvent = handler
        let done = expectation(description: "both recovered answers finished")
        var recorded = false
        let cardsObserver = model.$cards.sink { cards in
            if cards.filter(\.finished).count == 2, !recorded {
                recorded = true
                done.fulfill()
            }
        }
        model.recoverSession()
        await fulfillment(of: [done], timeout: 2)
        cardsObserver.cancel()
        XCTAssertEqual(recovered.map(\.question), ["What is a transaction?", "How does isolation work?"])
        XCTAssertTrue(model.listening)
        XCTAssertTrue(old.closed)
        XCTAssertFalse(replacement.closed)
        XCTAssertEqual(audio.startCount, 2)
        model.stop()
    }
    func testQuestionsModeCannotEnableScreenshotsAndSwitchingBackStopsCapture() async {
        let capture = FeatureScreenCapture()
        let screen = ScreenContextController(captureFactory: { capture })
        let model = MeetingModel(screen: screen)
        model.setScreenWatching(true)
        XCTAssertFalse(model.watchScreen)
        model.mode = .advancedCoding
        let ready = expectation(description: "screen enabled")
        let observer = screen.$enabled.dropFirst().sink { if $0 { ready.fulfill() } }
        model.setScreenWatching(true)
        await fulfillment(of: [ready], timeout: 2)
        observer.cancel()
        model.mode = .questions
        XCTAssertFalse(model.watchScreen)
        XCTAssertFalse(screen.enabled)
        XCTAssertNil(screen.snapshot)
    }
}
