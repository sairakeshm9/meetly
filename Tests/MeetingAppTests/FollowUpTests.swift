import Combine
import MeetingCore
import XCTest

@testable import MeetingAssist

@MainActor
final class FollowUpTests: XCTestCase {
    private func connected(
        answer: @escaping (AnswerRequest, @escaping @MainActor (String) -> Void) async throws -> Void = {
            _, delta in delta("SAY THIS: Precise answer. EXAMPLE: One example.")
        }
    ) async throws -> (MeetingModel, LiveTranscriber, MockSocket) {
        let socket = MockSocket()
        let client = LiveTranscriber { _ in socket }
        try await client.connect(
            key: "test-only", model: "gpt-live-transcribe", realtimeAnswerModel: "gpt-realtime-2.1-mini")
        let model = MeetingModel(
            credentials: CredentialAccess { "test-only" }, meetingClient: client, answerStreamer: answer)
        model.hasKey = true
        model.listening = true
        return (model, client, socket)
    }
    private func requests(_ socket: MockSocket) -> [[String: Any]] {
        socket.packets.filter { $0["type"] as? String == "response.create" }
    }
    private func emit(_ socket: MockSocket, id: String, text: String) {
        socket.push(["type": "input_audio_buffer.committed", "item_id": id])
        socket.push([
            "type": "conversation.item.input_audio_transcription.completed", "item_id": id,
            "transcript": text,
        ])
    }
    private func finish(
        _ socket: MockSocket, answer: String = "SAY THIS: Use a transaction. EXAMPLE: Commit atomically."
    ) {
        let request = requests(socket).last!["response"] as! [String: Any]
        let id = (request["metadata"] as! [String: String])["client_run"]!
        socket.push(["type": "response.created", "response": ["id": id, "metadata": request["metadata"]!]])
        socket.push(["type": "response.output_text.delta", "response_id": id, "delta": answer])
        socket.push(["type": "response.done", "response": ["id": id, "status": "completed"]])
    }
    private func barrier(_ client: LiveTranscriber, socket: MockSocket) async {
        let processed = expectation(description: "all prior transcript events processed")
        let handler = client.onEvent
        client.onEvent = { event in
            handler?(event)
            if event == .ignored { processed.fulfill() }
        }
        socket.push(["type": "rate_limits.updated"])
        await fulfillment(of: [processed], timeout: 2)
        client.onEvent = handler
    }
    private func waitForFinished(_ model: MeetingModel, question: String, action: () -> Void) async {
        let finished = expectation(description: "answer finished: " + question)
        var recorded = false
        let observer = model.$cards.sink { cards in
            guard cards.first?.question == question, cards.first?.finished == true, !recorded else { return }
            recorded = true
            finished.fulfill()
        }
        action()
        await fulfillment(of: [finished], timeout: 2)
        observer.cancel()
    }
    func testPreparedUnclearAnswerKeepsIssueBannerWhenTranscriptArrivesLater() async throws {
        let (model, client, socket) = try await connected()
        defer { model.stop() }
        let requested = expectation(description: "audio answer prepared")
        socket.onSend = { if $0 == "response.create" { requested.fulfill() } }
        socket.push(["type": "input_audio_buffer.committed", "item_id": "unclear"])
        await fulfillment(of: [requested], timeout: 2)
        socket.onSend = nil
        finish(socket, answer: "ISSUE: Input format missing.\nQUESTION: Should I use JSON? (Y/N)")
        await barrier(client, socket: socket)
        await waitForFinished(model, question: "Write a parser for the input") {
            socket.push([
                "type": "conversation.item.input_audio_transcription.completed",
                "item_id": "unclear", "transcript": "Write a parser for the input",
            ])
        }
        XCTAssertEqual(model.error, "Input format missing.")
        XCTAssertTrue(model.clarification?.contains("Y/N") == true)
    }
    func testSeveralQuestionsWhileBusyAreAnsweredInOrderWithTheirOwnContext() async throws {
        let strongerStarted = expectation(description: "queued followup uses stronger route")
        var release: CheckedContinuation<Void, Never>?
        var strongerRequest: AnswerRequest?
        let (model, client, socket) = try await connected { request, delta in
            strongerRequest = request
            await withCheckedContinuation {
                release = $0
                strongerStarted.fulfill()
            }
            delta("SAY THIS: An example. EXAMPLE: Commit a payment.")
        }
        defer { model.stop() }
        let questions = ["What is a database transaction?", "An example", "Explain Docker images."]
        let first = expectation(description: "first fast request")
        socket.onSend = { if $0 == "response.create" { first.fulfill() } }
        emit(socket, id: "one", text: questions[0])
        await fulfillment(of: [first], timeout: 2)
        socket.onSend = nil
        emit(socket, id: "two", text: questions[1])
        emit(socket, id: "three", text: questions[2])
        await barrier(client, socket: socket)
        XCTAssertEqual(requests(socket).count, 1)
        finish(socket)
        await fulfillment(of: [strongerStarted], timeout: 2)
        XCTAssertEqual(strongerRequest?.question, questions[1])
        XCTAssertTrue(strongerRequest?.precision == true)
        XCTAssertTrue(strongerRequest?.context.contains(questions[0]) == true)
        XCTAssertFalse(strongerRequest?.context.contains(questions[2]) == true)
        let third = expectation(description: "ordinary queued question retains fast route")
        socket.onSend = { if $0 == "response.create" { third.fulfill() } }
        release?.resume()
        await fulfillment(of: [third], timeout: 2)
        socket.onSend = nil
        let response = try XCTUnwrap(requests(socket).last?["response"] as? [String: Any])
        let input = try XCTUnwrap(response["input"] as? [[String: Any]])
        XCTAssertEqual(input[0]["id"] as? String, "three")
        await waitForFinished(model, question: questions[2]) { finish(socket) }
        XCTAssertEqual(model.cards.reversed().map(\.question), questions)
        XCTAssertTrue(model.cards.allSatisfy { $0.finished && !$0.interrupted })
    }
    func testShortFollowUpAfterFinishedAnswerIsAcceptedAndThanksStaysQuiet() async throws {
        var strongerCalls = 0
        let (model, client, socket) = try await connected { request, delta in
            XCTAssertTrue(request.precision)
            XCTAssertFalse(request.expanded)
            strongerCalls += 1
            delta("SAY THIS: Precise followup. EXAMPLE: One concrete example.")
        }
        defer { model.stop() }
        let first = expectation(description: "first request")
        socket.onSend = { if $0 == "response.create" { first.fulfill() } }
        emit(socket, id: "one", text: "What is dependency injection?")
        await fulfillment(of: [first], timeout: 2)
        socket.onSend = nil
        await waitForFinished(model, question: "What is dependency injection?") { finish(socket) }
        for (index, text) in ["And in Java", "An example", "Why?", "Without annotations"].enumerated() {
            await waitForFinished(model, question: text) { emit(socket, id: "follow-\(index)", text: text) }
        }
        XCTAssertEqual(strongerCalls, 4)
        let count = requests(socket).count
        socket.push([
            "type": "conversation.item.input_audio_transcription.completed", "item_id": "thanks",
            "transcript": "Thanks, that helps.",
        ])
        await barrier(client, socket: socket)
        XCTAssertEqual(requests(socket).count, count)
        XCTAssertEqual(strongerCalls, 4)
    }
    func testRepeatedWordingWithNewAudioIDIsAnsweredButDuplicateFinalCannotCancelCurrentAnswer() async throws
    {
        var strongerCalls = 0
        let (model, client, socket) = try await connected { request, delta in
            XCTAssertTrue(request.precision)
            strongerCalls += 1
            delta("SAY THIS: One precise example.")
        }
        defer { model.stop() }
        let question = "Can you give an example?"
        let first = expectation(description: "first audio request")
        socket.onSend = { if $0 == "response.create" { first.fulfill() } }
        emit(socket, id: "one", text: question)
        await fulfillment(of: [first], timeout: 2)
        socket.onSend = nil
        await waitForFinished(model, question: question) { finish(socket) }
        emit(socket, id: "one", text: question)
        await barrier(client, socket: socket)
        let finished = expectation(description: "second separate audio ID is answered")
        let observer = model.$cards.sink { cards in
            if cards.count == 2, cards.first?.finished == true { finished.fulfill() }
        }
        emit(socket, id: "two", text: question)
        await fulfillment(of: [finished], timeout: 2)
        observer.cancel()
        emit(socket, id: "two", text: question)
        await barrier(client, socket: socket)
        XCTAssertEqual(strongerCalls, 1)
        XCTAssertEqual(requests(socket).count, 1)
        XCTAssertEqual(model.cards.count, 2)
        XCTAssertTrue(model.cards.allSatisfy { $0.finished && !$0.interrupted })
    }
    func testTurningOffAutomaticAnswersDropsQueuedFollowUp() async throws {
        let (model, client, socket) = try await connected()
        defer { model.stop() }
        let first = expectation(description: "first request")
        socket.onSend = { if $0 == "response.create" { first.fulfill() } }
        emit(socket, id: "one", text: "What is a transaction?")
        await fulfillment(of: [first], timeout: 2)
        socket.onSend = nil
        emit(socket, id: "two", text: "How does isolation work?")
        await barrier(client, socket: socket)
        model.autoAnswer = false
        await waitForFinished(model, question: "What is a transaction?") { finish(socket) }
        await barrier(client, socket: socket)
        XCTAssertEqual(requests(socket).count, 1)
        XCTAssertEqual(model.cards.count, 1)
    }
    func testLateFirstTranscriptDoesNotLoseQueuedSecondQuestion() async throws {
        let (model, client, socket) = try await connected()
        defer { model.stop() }
        let first = expectation(description: "first preparation")
        socket.onSend = { if $0 == "response.create" { first.fulfill() } }
        socket.push(["type": "input_audio_buffer.committed", "item_id": "one"])
        await fulfillment(of: [first], timeout: 2)
        socket.onSend = nil
        emit(socket, id: "two", text: "How does isolation work?")
        await barrier(client, socket: socket)
        XCTAssertTrue(model.cards.isEmpty)
        finish(socket)
        await barrier(client, socket: socket)
        let second = expectation(description: "queued question starts after late first final")
        socket.onSend = { if $0 == "response.create" { second.fulfill() } }
        socket.push([
            "type": "conversation.item.input_audio_transcription.completed", "item_id": "one",
            "transcript": "What is a transaction?",
        ])
        await fulfillment(of: [second], timeout: 2)
        socket.onSend = nil
        await waitForFinished(model, question: "How does isolation work?") { finish(socket) }
        XCTAssertEqual(
            model.cards.reversed().map(\.question), ["What is a transaction?", "How does isolation work?"])
    }
    func testShortFollowupAfterPauseUsesBoundedContextAndStopDiscardsWaitingQuestions() async throws {
        var clock = Date(timeIntervalSince1970: 1000)
        var release: CheckedContinuation<Void, Never>?
        let held = expectation(description: "followup held")
        let socket = MockSocket()
        let client = LiveTranscriber { _ in socket }
        try await client.connect(
            key: "test-only", model: "gpt-live-transcribe", realtimeAnswerModel: "gpt-realtime-2.1-mini")
        let model = MeetingModel(
            credentials: CredentialAccess { "test-only" }, meetingClient: client, now: { clock },
            answerStreamer: { request, delta in
                XCTAssertTrue(request.precision)
                XCTAssertTrue(request.context.contains("What is a transaction?"))
                await withCheckedContinuation {
                    release = $0
                    held.fulfill()
                }
                delta("LATE_CANCELLED_ANSWER")
            })
        model.hasKey = true
        model.listening = true
        let first = expectation(description: "first request")
        socket.onSend = { if $0 == "response.create" { first.fulfill() } }
        emit(socket, id: "one", text: "What is a transaction?")
        await fulfillment(of: [first], timeout: 2)
        socket.onSend = nil
        await waitForFinished(model, question: "What is a transaction?") { finish(socket) }
        clock += 121
        emit(socket, id: "two", text: "An example")
        await fulfillment(of: [held], timeout: 2)
        emit(socket, id: "three", text: "Explain Docker images")
        await barrier(client, socket: socket)
        XCTAssertEqual(model.waitingQuestionCount, 1)
        model.stop()
        release?.resume()
        XCTAssertEqual(model.waitingQuestionCount, 0)
        XCTAssertEqual(model.cards.count, 2)
        XCTAssertTrue(model.cards.first?.interrupted == true)
        XCTAssertEqual(requests(socket).count, 1)
    }
}
