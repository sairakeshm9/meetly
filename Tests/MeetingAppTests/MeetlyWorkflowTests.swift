import AppKit
import Combine
import MeetingCore
import XCTest

@testable import MeetingAssist

@MainActor
final class MeetlyWorkflowTests: XCTestCase {
    func testRefreshUsesOlderPinnedCardAndItsLinkedContextWithoutNewScreenCapture() async {
        let refreshed = expectation(description: "pinned refresh")
        let model = MeetingModel(
            credentials: CredentialAccess { "test-only" },
            screen: ScreenContextController(captureFactory: { FeatureScreenCapture() }),
            answerStreamer: { request, delta in
                XCTAssertEqual(request.question, "Why?")
                XCTAssertTrue(request.simplified)
                XCTAssertTrue(request.context.contains("Original transaction explanation"))
                XCTAssertTrue(request.context.contains("Explain transactions"))
                XCTAssertFalse(request.context.contains("Unrelated newest answer"))
                XCTAssertNil(request.screenImage)
                XCTAssertEqual(request.mode, .questions)
                delta("Because all updates must succeed together.")
                refreshed.fulfill()
            }, appearanceDefaults: defaults())
        model.hasKey = true
        model.mode = .advancedCoding
        model.setScreenWatching(false)  // This test exercises the text/editor-only path.
        var parent = AnswerCard(question: "Explain transactions")
        parent.answer = "Original transaction explanation"
        parent.finished = true
        var followup = AnswerCard(question: "Why?")
        followup.answer = "The transaction prevents partial updates."
        followup.parentID = parent.id
        followup.finished = true
        var newest = AnswerCard(question: "Explain indexes")
        newest.answer = "Unrelated newest answer"
        newest.finished = true
        model.cards = [newest, followup, parent]
        model.selectAnswer(followup.id)
        model.refreshSession()
        XCTAssertFalse(model.cards.contains(where: { $0.id == followup.id }))
        await fulfillment(of: [refreshed], timeout: 2)
        XCTAssertEqual(model.activeCard?.question, "Why?")
        model.stop()
    }
    private func defaults() -> UserDefaults {
        let name = "Meetly.Tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        return defaults
    }
    func testRefreshClearsCurrentAnswerAndIgnoresLateCancelledText() async throws {
        let started = expectation(description: "old answer held")
        let refreshed = expectation(description: "simple retry")
        let cancelled = expectation(description: "old generation finished")
        var release: CheckedContinuation<Void, Never>?
        var calls = 0
        let model = MeetingModel(
            credentials: CredentialAccess { "test-only" },
            screen: ScreenContextController(captureFactory: { FeatureScreenCapture() }),
            answerStreamer: { request, delta in
                calls += 1
                if calls == 1 {
                    delta("SAY THIS: Stale complicated explanation.")
                    await withCheckedContinuation {
                        release = $0
                        started.fulfill()
                    }
                    delta(" LATE STALE TEXT")
                    cancelled.fulfill()
                    try Task.checkCancellation()
                } else {
                    XCTAssertEqual(request.question, "What is a transaction?")
                    XCTAssertTrue(request.simplified)
                    XCTAssertFalse(request.expanded)
                    delta("SAY THIS:\n- A transaction groups updates so all succeed together.")
                    refreshed.fulfill()
                }
            }, appearanceDefaults: defaults())
        model.hasKey = true
        model.answerTemplate = .layered
        model.ask("What is a transaction?")
        await fulfillment(of: [started], timeout: 2)
        model.refreshSession()
        XCTAssertEqual(model.cards.count, 1)
        XCTAssertEqual(model.cards[0].answer, "")
        XCTAssertFalse(model.readingPinned)
        await fulfillment(of: [refreshed], timeout: 2)
        release?.resume()
        await fulfillment(of: [cancelled], timeout: 2)
        XCTAssertEqual(calls, 2)
        XCTAssertFalse(model.cards[0].answer.contains("STALE"))
        XCTAssertEqual(model.status, "Displayed answer refreshed")
        model.stop()
    }
    func testRefreshChoosesDisplayedQuestionOverQueuedQuestionAndKeepsHealthyConnection() async throws {
        let socket = MockSocket()
        let client = LiveTranscriber { _ in socket }
        try await client.connect(key: "test-only", model: "gpt-live-transcribe")
        let first = expectation(description: "first held")
        let last = expectation(description: "latest retried")
        var release: CheckedContinuation<Void, Never>?
        var questions: [String] = []
        let model = MeetingModel(
            credentials: CredentialAccess { "test-only" }, meetingClient: client,
            screen: ScreenContextController(captureFactory: { FeatureScreenCapture() }),
            answerStreamer: { request, delta in
                questions.append(request.question)
                if questions.count == 1 {
                    await withCheckedContinuation {
                        release = $0
                        first.fulfill()
                    }
                    try Task.checkCancellation()
                } else {
                    XCTAssertTrue(request.simplified)
                    delta("SAY THIS: Brief explanation.")
                    last.fulfill()
                }
            }, appearanceDefaults: defaults())
        model.hasKey = true
        model.listening = true
        socket.push([
            "type": "conversation.item.input_audio_transcription.completed", "item_id": "one",
            "transcript": "Explain transactions",
        ])
        await fulfillment(of: [first], timeout: 2)
        let queued = expectation(description: "latest event processed")
        let handler = client.onEvent
        client.onEvent = { event in
            handler?(event)
            if event == .ignored { queued.fulfill() }
        }
        socket.push([
            "type": "conversation.item.input_audio_transcription.completed", "item_id": "two",
            "transcript": "Explain indexes",
        ])
        socket.push(["type": "rate_limits.updated"])
        await fulfillment(of: [queued], timeout: 2)
        model.refreshSession()
        await fulfillment(of: [last], timeout: 2)
        release?.resume()
        XCTAssertEqual(questions, ["Explain transactions", "Explain transactions"])
        XCTAssertEqual(model.waitingQuestionCount, 0)
        XCTAssertTrue(model.listening)
        XCTAssertFalse(socket.closed)
        model.stop()
    }
    func testCodingUsesSolButNormalQuestionsKeepOrdinaryModelAndSelectedTemplate() async throws {
        let answered = expectation(description: "two routes")
        answered.expectedFulfillmentCount = 2
        var requests: [AnswerRequest] = []
        let model = MeetingModel(
            credentials: CredentialAccess { "test-only" },
            screen: ScreenContextController(captureFactory: { FeatureScreenCapture() }),
            answerStreamer: { request, delta in
                requests.append(request)
                delta("SAY THIS: Brief reference.")
                answered.fulfill()
            }, appearanceDefaults: defaults())
        model.hasKey = true
        model.mode = .coding
        model.setScreenWatching(false)  // This test exercises the text/editor-only path.
        model.answerTemplate = .layered
        model.ask("Write Java code to reverse a string")
        let done = expectation(description: "first finishes")
        let observer = model.$answering.dropFirst().sink { if !$0 { done.fulfill() } }
        await fulfillment(of: [done], timeout: 2)
        observer.cancel()
        model.ask("What is dependency injection?")
        await fulfillment(of: [answered], timeout: 2)
        XCTAssertEqual(requests.first?.model, "gpt-6.1-sol")
        XCTAssertEqual(requests.last?.model, model.codingAnswerModel)
        XCTAssertEqual(requests.last?.template, .layered)
        XCTAssertFalse(model.codingTask.isEmpty)
        model.stop()
    }
    func testSharingSwitchesModesAndRetainsStateForHiddenToolbar() {
        let capture = FeatureScreenCapture()
        let screen = ScreenContextController(captureFactory: { capture })
        let model = MeetingModel(screen: screen, appearanceDefaults: defaults())
        model.observeSharingText("You are screen sharing")
        XCTAssertTrue(model.sharingActive)
        XCTAssertEqual(model.mode, .coding)
        XCTAssertTrue(model.watchScreen)
        model.observeSharingText("public class Main {}")
        XCTAssertTrue(model.sharingActive)
        model.mode = .advancedCoding
        model.observeSharingText("You are screen sharing")
        XCTAssertEqual(
            model.mode, .advancedCoding, "Repeated indicators must not undo a manual mode selection")
        model.observeSharingText("Screen sharing ended")
        XCTAssertEqual(model.mode, .questions)
        XCTAssertFalse(model.watchScreen)
        model.autoSharingMode = false
        model.observeSharingText("Stop sharing")
        XCTAssertFalse(model.sharingActive)
        model.stop()
    }
    func testTemplateTextTransparencyAndAutoModePreferencesSurviveRestart() {
        let saved = defaults()
        let model = MeetingModel(
            screen: ScreenContextController(captureFactory: { FeatureScreenCapture() }),
            appearanceDefaults: saved)
        model.answerTemplate = .layered
        model.setTextTransparency(100)
        model.codingAnswerModel = "test-coding-model"
        model.autoSharingMode = false
        let restored = MeetingModel(appearanceDefaults: saved)
        XCTAssertEqual(restored.answerTemplate, .layered)
        XCTAssertEqual(restored.textTransparency, 100)
        XCTAssertEqual(restored.windowTransparency, 20)
        XCTAssertEqual(restored.codingAnswerModel, "test-coding-model")
        XCTAssertFalse(restored.autoSharingMode)
        restored.setTextTransparency(-1)
        XCTAssertEqual(restored.textTransparency, 0)
    }
    func testCustomTemplateRequiresSaveAndSurvivesRestartThroughAnswerRequest() async {
        let saved = defaults()
        let delivered = expectation(description: "saved custom format reaches request")
        var calls = 0
        let model = MeetingModel(
            credentials: CredentialAccess { "test-only" },
            screen: ScreenContextController(captureFactory: { FeatureScreenCapture() }),
            answerStreamer: { request, delta in
                calls += 1
                XCTAssertEqual(request.template, .custom)
                XCTAssertEqual(request.customTemplate, "Use SUMMARY and ANALOGY.")
                delta("SUMMARY: Transactions group changes. ANALOGY: One package.")
                delivered.fulfill()
            }, appearanceDefaults: saved)
        model.hasKey = true
        model.answerTemplate = .custom
        model.ask("What is a transaction?")
        XCTAssertEqual(model.error, "Save a custom answer template first.")
        XCTAssertEqual(calls, 0)
        XCTAssertFalse(model.saveCustomAnswerTemplate("  "))
        XCTAssertTrue(model.saveCustomAnswerTemplate("  Use SUMMARY and ANALOGY.  "))
        XCTAssertFalse(model.saveCustomAnswerTemplate(""))
        let restored = MeetingModel(appearanceDefaults: saved)
        XCTAssertEqual(restored.answerTemplate, .custom)
        XCTAssertEqual(restored.customAnswerTemplate, "Use SUMMARY and ANALOGY.")
        model.answerControlsCollapsed = true
        model.ask("What is a transaction?")
        await fulfillment(of: [delivered], timeout: 2)
        XCTAssertEqual(model.activeCard?.question, "What is a transaction?")
        XCTAssertTrue(model.activeCard?.answer.contains("SUMMARY:") == true)
        XCTAssertTrue(model.answerControlsCollapsed)
        model.stop()
    }
    func testFullyTransparentBackgroundKeepsTextAndControlsUsable() {
        _ = NSApplication.shared
        let model = MeetingModel(
            screen: ScreenContextController(captureFactory: { FeatureScreenCapture() }),
            appearanceDefaults: defaults())
        let window = NSWindow(
            contentRect: NSRect(x: 100, y: 100, width: 640, height: 540), styleMask: [.titled],
            backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let view = AssistantAppearanceView()
        view.model = model
        view.transparency = 100
        window.contentView = view
        XCTAssertEqual(window.alphaValue, 1)
        XCTAssertFalse(window.ignoresMouseEvents)
        XCTAssertFalse(window.isOpaque)
        model.setWindowTransparency(100)
        XCTAssertEqual(model.textTransparency, 0)
        model.setTextTransparency(100)
        XCTAssertEqual(model.windowTransparency, 100)
        model.setWindowTransparency(0)
        XCTAssertEqual(model.textTransparency, 100)
        view.transparency = 0
        view.configureWindow()
        XCTAssertEqual(window.alphaValue, 1)
        XCTAssertFalse(window.ignoresMouseEvents)
    }
    func testDemoIsOfflineAndRefreshWithoutAQuestionDoesNotSendRequest() {
        let model = MeetingModel(
            screen: ScreenContextController(captureFactory: { FeatureScreenCapture() }),
            answerStreamer: { _, _ in XCTFail("Demo/empty refresh must not call API") },
            appearanceDefaults: defaults())
        model.hasKey = true
        model.refreshSession()
        XCTAssertNotNil(model.error)
        model.preview()
        model.refreshSession()
        XCTAssertTrue(model.demo)
        XCTAssertFalse(model.listening)
        XCTAssertTrue(model.cards.first?.finished == true)
        XCTAssertTrue(model.status.contains("no audio"))
    }
}
