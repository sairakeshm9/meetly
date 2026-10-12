import Combine
import MeetingCore
import XCTest

@testable import MeetingAssist

@MainActor
final class StressTests: XCTestCase {
    private func connected(
        fast: Bool = false,
        answer: @escaping (AnswerRequest, @escaping @MainActor (String) -> Void) async throws -> Void
    ) async throws -> (MeetingModel, LiveTranscriber, MockSocket) {
        let socket = MockSocket()
        var first = true
        let client = LiveTranscriber { _ in
            defer { first = false }
            return first ? socket : MockSocket()
        }
        try await client.connect(
            key: "test-only", model: "gpt-live-transcribe",
            realtimeAnswerModel: fast ? "gpt-realtime-2.1-mini" : nil)
        let model = MeetingModel(
            credentials: CredentialAccess { "test-only" }, meetingClient: client,
            captureFactory: { FeatureAudioCapture() },
            screen: ScreenContextController(captureFactory: { FeatureScreenCapture() }),
            answerStreamer: answer)
        model.hasKey = true
        model.listening = true
        return (model, client, socket)
    }

    private func emit(_ socket: MockSocket, id: String, text: String) {
        socket.push([
            "type": "conversation.item.input_audio_transcription.completed", "item_id": id,
            "transcript": text,
        ])
    }

    private func barrier(_ client: LiveTranscriber, socket: MockSocket) async {
        let processed = expectation(description: "all preceding events processed")
        let handler = client.onEvent
        client.onEvent = { event in
            handler?(event)
            if event == .ignored { processed.fulfill() }
        }
        socket.push(["type": "rate_limits.updated"])
        await fulfillment(of: [processed], timeout: 2)
        client.onEvent = handler
    }

    func testRapidSixtyQuestionsStayOrderedAndInvalidManualInputCannotDropThem() async throws {
        var requests: [AnswerRequest] = []
        var release: CheckedContinuation<Void, Never>?
        let firstStarted = expectation(description: "first answer held")
        let allDone = expectation(description: "sixty answers completed")
        let (model, client, socket) = try await connected { request, delta in
            requests.append(request)
            if requests.count == 1 {
                await withCheckedContinuation {
                    release = $0
                    firstStarted.fulfill()
                }
            }
            delta("SAY THIS: Use a transaction. EXAMPLE: Commit atomically.")
            if requests.count == 60 { allDone.fulfill() }
        }
        defer { model.stop() }
        let questions = (0..<60).map { "Explain transaction number \($0)." }
        emit(socket, id: "0", text: questions[0])
        await fulfillment(of: [firstStarted], timeout: 2)
        for index in 1..<60 {
            emit(socket, id: String(index), text: questions[index])
            if index.isMultiple(of: 7) { emit(socket, id: String(index), text: questions[index]) }
        }
        await barrier(client, socket: socket)
        model.ask("   ")
        XCTAssertTrue(model.error?.contains("Enter a question") == true)
        model.ask("Can you")
        XCTAssertTrue(model.error?.contains("incomplete") == true)
        release?.resume()
        await fulfillment(of: [allDone], timeout: 2)
        XCTAssertEqual(requests.map(\.question), questions)
        XCTAssertEqual(model.cards.count, 10)
        XCTAssertTrue(
            requests.allSatisfy { $0.context.components(separatedBy: "Meeting question:").count <= 4 })
    }

    func testFailurePausesQueueUntilRefreshAndRetriesInOrder() async throws {
        var requests: [String] = []
        var release: CheckedContinuation<Void, Never>?
        let started = expectation(description: "first answer held")
        let recovered = expectation(description: "all questions recovered")
        let (model, client, socket) = try await connected { request, delta in
            requests.append(request.question)
            if requests.count == 1 {
                await withCheckedContinuation {
                    release = $0
                    started.fulfill()
                }
                throw MeetingError.message("API quota exceeded. Refresh after resolving billing.")
            }
            delta("SAY THIS: Use a transaction. EXAMPLE: Commit atomically.")
            if requests.count == 4 { recovered.fulfill() }
        }
        defer { model.stop() }
        let questions = ["Explain transactions.", "Explain isolation.", "Explain optimistic locking."]
        emit(socket, id: "1", text: questions[0])
        await fulfillment(of: [started], timeout: 2)
        emit(socket, id: "2", text: questions[1])
        emit(socket, id: "3", text: questions[2])
        await barrier(client, socket: socket)
        let failed = expectation(description: "failure reported")
        let observer = model.$cards.sink { if $0.first?.interrupted == true { failed.fulfill() } }
        release?.resume()
        await fulfillment(of: [failed], timeout: 2)
        observer.cancel()
        await barrier(client, socket: socket)
        XCTAssertEqual(requests, [questions[0]], "One error must not trigger a request storm")
        XCTAssertTrue(model.error?.contains("quota") == true)
        model.recoverSession()
        await fulfillment(of: [recovered], timeout: 2)
        XCTAssertEqual(requests, [questions[0]] + questions)
    }

    func testClarificationReplyKeepsWaitingQuestionsAndOriginalTaskContext() async throws {
        var requests: [AnswerRequest] = []
        var release: CheckedContinuation<Void, Never>?
        let started = expectation(description: "parser answer held")
        let replied = expectation(description: "binary reply processed")
        let drained = expectation(description: "waiting questions processed")
        let (model, client, socket) = try await connected { request, delta in
            requests.append(request)
            if requests.count == 1 {
                await withCheckedContinuation {
                    release = $0
                    started.fulfill()
                }
                delta("ISSUE: Input format missing.\nQUESTION: Should I use JSON? (Y/N)")
            } else {
                if request.question == "Y" { replied.fulfill() }
                delta("SAY THIS: Use JSON. EXAMPLE: Parse a JSON object.")
                if requests.count == 5 { drained.fulfill() }
            }
        }
        defer { model.stop() }
        let question = "Write a parser for this input."
        emit(socket, id: "1", text: question)
        await fulfillment(of: [started], timeout: 2)
        let waiting = ["Explain indexes.", "Explain caching.", "Explain locking."]
        for (index, text) in waiting.enumerated() { emit(socket, id: "q\(index)", text: text) }
        await barrier(client, socket: socket)
        let needsReply = expectation(description: "clarification visible")
        let observer = model.$clarification.compactMap { $0 }.sink { _ in needsReply.fulfill() }
        release?.resume()
        await fulfillment(of: [needsReply], timeout: 2)
        observer.cancel()
        await barrier(client, socket: socket)
        XCTAssertEqual(requests.count, 1)
        model.answerClarification(true)
        await fulfillment(of: [replied, drained], timeout: 2)
        XCTAssertEqual(requests.map(\.question), [question, "Y"] + waiting)
        let reply = try XCTUnwrap(requests.first(where: { $0.question == "Y" }))
        XCTAssertTrue(reply.context.contains(question))
        XCTAssertTrue(reply.context.contains("Should I use JSON?"))
        XCTAssertFalse(reply.context.contains("Explain locking."))
    }

    func testClearAfterDisconnectCannotResurrectRecoveryQuestions() async throws {
        var requests: [String] = []
        var release: CheckedContinuation<Void, Never>?
        let started = expectation(description: "first answer held")
        let (model, client, socket) = try await connected { request, delta in
            requests.append(request.question)
            if requests.count == 1 {
                await withCheckedContinuation {
                    release = $0
                    started.fulfill()
                }
            }
            delta("late text")
        }
        defer { model.stop() }
        emit(socket, id: "1", text: "Explain transactions.")
        await fulfillment(of: [started], timeout: 2)
        emit(socket, id: "2", text: "Explain isolation.")
        await barrier(client, socket: socket)
        let failed = expectation(description: "connection failed")
        let observer = model.$error.compactMap { $0 }.sink { _ in failed.fulfill() }
        socket.push(["type": "error", "error": ["message": "Synthetic disconnection"]])
        await fulfillment(of: [failed], timeout: 2)
        observer.cancel()
        model.clear()
        model.recoverSession()
        release?.resume()
        await Task.yield()
        XCTAssertFalse(model.connecting)
        XCTAssertTrue(model.cards.isEmpty)
        XCTAssertEqual(requests, ["Explain transactions."])
    }

    func testCancelledAnswerLateTextCannotReplaceNewAnswer() async {
        var release: CheckedContinuation<Void, Never>?
        let started = expectation(description: "old answer held")
        let finished = expectation(description: "new answer finished")
        let model = MeetingModel(
            credentials: CredentialAccess { "test-only" },
            screen: ScreenContextController(captureFactory: { FeatureScreenCapture() }),
            answerStreamer: { request, delta in
                if request.question == "Explain transactions." {
                    await withCheckedContinuation {
                        release = $0
                        started.fulfill()
                    }
                    delta("old stale text")
                } else {
                    delta("SAY THIS: New answer. EXAMPLE: New example.")
                    finished.fulfill()
                }
            })
        model.hasKey = true
        model.ask("Explain transactions.")
        await fulfillment(of: [started], timeout: 2)
        model.ask("Explain indexes.")
        await fulfillment(of: [finished], timeout: 2)
        release?.resume()
        await Task.yield()
        XCTAssertFalse(model.activeCard?.answer.contains("stale") == true)
        XCTAssertEqual(model.activeCard?.question, "Explain indexes.")
        model.stop()
    }

    func testOverloadStaysBoundedAndDuplicateCacheDoesNotResetAfterFiveHundredItems() async throws {
        var requests: [String] = []
        var release: CheckedContinuation<Void, Never>?
        let started = expectation(description: "first answer held")
        let newest = expectation(description: "explicit newest answer generated")
        let (model, client, socket) = try await connected { request, delta in
            requests.append(request.question)
            if requests.count == 1 {
                await withCheckedContinuation {
                    release = $0
                    started.fulfill()
                }
            } else {
                newest.fulfill()
            }
            delta("SAY THIS: New answer. EXAMPLE: New example.")
        }
        defer { model.stop() }
        emit(socket, id: "0", text: "Explain transaction 0.")
        await fulfillment(of: [started], timeout: 2)
        for index in 1..<600 { emit(socket, id: String(index), text: "Explain transaction \(index).") }
        await barrier(client, socket: socket)
        XCTAssertEqual(model.waitingQuestionCount, 80)
        XCTAssertTrue(model.error?.contains("Too many questions") == true)
        var repeatedErrors = 0
        let observer = model.$error.dropFirst().sink { _ in repeatedErrors += 1 }
        emit(socket, id: "450", text: "Explain transaction 450.")
        emit(socket, id: "599", text: "Explain transaction 599.")
        emit(socket, id: "thanks", text: "Thanks, that helps.")
        await barrier(client, socket: socket)
        observer.cancel()
        XCTAssertEqual(repeatedErrors, 0, "Recent duplicates must remain deduplicated after the limit")
        model.answerNewestWaiting()
        await fulfillment(of: [newest], timeout: 2)
        release?.resume()
        await Task.yield()
        XCTAssertEqual(requests, ["Explain transaction 0.", "Explain transaction 599."])
        XCTAssertEqual(model.waitingQuestionCount, 0)
        XCTAssertFalse(model.activeCard?.answer.contains("stale") == true)
    }

    func testEmptyAnswerIsInterruptedAndCannotDrainWaitingQuestions() async throws {
        let empty = expectation(description: "empty output reported")
        let (model, client, socket) = try await connected { _, delta in delta(" \n\t") }
        defer { model.stop() }
        let observer = model.$error.compactMap { $0 }.sink { text in
            if text.contains("No answer text") { empty.fulfill() }
        }
        emit(socket, id: "1", text: "Explain transactions.")
        await fulfillment(of: [empty], timeout: 2)
        observer.cancel()
        emit(socket, id: "2", text: "Explain isolation.")
        await barrier(client, socket: socket)
        XCTAssertTrue(model.activeCard?.interrupted == true)
        XCTAssertFalse(model.activeCard?.finished == true)
        XCTAssertTrue(model.queuePaused)
        XCTAssertEqual(model.waitingQuestionCount, 1)
        XCTAssertEqual(model.cards.count, 1)
    }

    func testExplicitCancelPausesFutureQuestionsUntilAnswerNewest() async throws {
        var requests: [String] = []
        var release: CheckedContinuation<Void, Never>?
        let started = expectation(description: "first answer held")
        let newest = expectation(description: "newest answer generated")
        let (model, client, socket) = try await connected { request, delta in
            requests.append(request.question)
            if requests.count == 1 {
                await withCheckedContinuation {
                    release = $0
                    started.fulfill()
                }
            } else {
                newest.fulfill()
            }
            delta("SAY THIS: Use a transaction. EXAMPLE: Commit atomically.")
        }
        defer { model.stop() }
        emit(socket, id: "1", text: "Explain transactions.")
        await fulfillment(of: [started], timeout: 2)
        emit(socket, id: "2", text: "Explain indexes.")
        await barrier(client, socket: socket)
        model.cancelAnswer(pauseQueue: true)
        emit(socket, id: "3", text: "Explain isolation.")
        await barrier(client, socket: socket)
        XCTAssertTrue(model.queuePaused)
        XCTAssertEqual(model.waitingQuestionCount, 2)
        XCTAssertEqual(requests.count, 1)
        model.answerNewestWaiting()
        await fulfillment(of: [newest], timeout: 2)
        release?.resume()
        await Task.yield()
        XCTAssertEqual(requests, ["Explain transactions.", "Explain isolation."])
        XCTAssertEqual(model.waitingQuestionCount, 0)
        XCTAssertFalse(model.queuePaused)
    }

    func testFastClarificationFinishedBeforeTranscriptKeepsItsOwnTask() async throws {
        var replyContext = ""
        let replied = expectation(description: "clarification reply sent")
        let (model, client, socket) = try await connected(fast: true) { request, delta in
            replyContext = request.context
            delta("SAY THIS: Use JSON. EXAMPLE: Parse a JSON object.")
            replied.fulfill()
        }
        defer { model.stop() }
        let created = expectation(description: "fast preparation sent")
        socket.onSend = { if $0 == "response.create" { created.fulfill() } }
        socket.push(["type": "input_audio_buffer.committed", "item_id": "parser"])
        await fulfillment(of: [created], timeout: 2)
        socket.onSend = nil
        for index in 0..<3 { emit(socket, id: "q\(index)", text: "Explain index \(index).") }
        let request =
            socket.packets.last(where: { $0["type"] as? String == "response.create" })!["response"]
            as! [String: Any]
        let id = "fast-response"
        socket.push(["type": "response.created", "response": ["id": id, "metadata": request["metadata"]!]])
        socket.push([
            "type": "response.output_text.delta", "response_id": id,
            "delta": "ISSUE: Input format missing.\nQUESTION: Should I use JSON? (Y/N)",
        ])
        socket.push(["type": "response.done", "response": ["id": id, "status": "completed"]])
        await barrier(client, socket: socket)
        XCTAssertNil(model.clarification, "Unconfirmed audio must not show a speculative issue")
        emit(socket, id: "parser", text: "Write a parser for this input.")
        await barrier(client, socket: socket)
        XCTAssertNotNil(model.clarification)
        model.answerClarification(true)
        await fulfillment(of: [replied], timeout: 2)
        XCTAssertTrue(replyContext.contains("Write a parser for this input."))
        XCTAssertTrue(replyContext.contains("Should I use JSON?"))
        XCTAssertFalse(replyContext.contains("Explain index 2."))
    }

    func testQueuedCodingTasksCannotChangeTheActiveTaskBeforeTheirTurn() async throws {
        var tasks: [String] = []
        var release: CheckedContinuation<Void, Never>?
        let started = expectation(description: "first code request held")
        let drained = expectation(description: "both coding tasks processed")
        let (model, client, socket) = try await connected { request, delta in
            tasks.append(request.codingTask)
            if tasks.count == 1 {
                await withCheckedContinuation {
                    release = $0
                    started.fulfill()
                }
            }
            delta("SAY THIS: Use a loop. EXAMPLE: A Java loop.")
            if tasks.count == 2 { drained.fulfill() }
        }
        defer { model.stop() }
        model.mode = .coding
        model.setScreenWatching(false)  // This test exercises the text/editor-only path.
        let first = "Write Java code to reverse a string."
        let second = "Write Java code to search a sorted array."
        emit(socket, id: "1", text: first)
        await fulfillment(of: [started], timeout: 2)
        emit(socket, id: "2", text: second)
        await barrier(client, socket: socket)
        XCTAssertEqual(model.codingTask, first)
        release?.resume()
        await fulfillment(of: [drained], timeout: 2)
        XCTAssertEqual(tasks, [first, second])
        XCTAssertEqual(model.codingTask, second)
    }

    func testTurningOffAutomaticAnswersClearsDisconnectedRecoveryBacklog() async throws {
        var release: CheckedContinuation<Void, Never>?
        let started = expectation(description: "first answer held")
        let (model, client, socket) = try await connected { _, delta in
            await withCheckedContinuation {
                release = $0
                started.fulfill()
            }
            delta("stale answer")
        }
        defer { model.stop() }
        emit(socket, id: "1", text: "Explain transactions.")
        await fulfillment(of: [started], timeout: 2)
        emit(socket, id: "2", text: "Explain indexes.")
        await barrier(client, socket: socket)
        let failed = expectation(description: "disconnection reported")
        let observer = model.$error.compactMap { $0 }.sink { _ in failed.fulfill() }
        socket.push(["type": "error", "error": ["message": "Synthetic disconnection"]])
        await fulfillment(of: [failed], timeout: 2)
        observer.cancel()
        XCTAssertEqual(model.waitingQuestionCount, 1)
        model.autoAnswer = false
        XCTAssertEqual(model.waitingQuestionCount, 0)
        release?.resume()
    }

    func testUnexpectedAudioStreamEndCannotLeaveListeningIndicatorStuck() async {
        let audio = FeatureAudioCapture()
        let client = LiveTranscriber { _ in MockSocket() }
        let model = MeetingModel(
            credentials: CredentialAccess { "test-only" }, meetingClient: client,
            captureFactory: { audio })
        model.hasKey = true
        model.microphone = false
        let ready = expectation(description: "listening started")
        let readyObserver = model.$listening.dropFirst().sink { if $0 { ready.fulfill() } }
        model.start()
        await fulfillment(of: [ready], timeout: 2)
        readyObserver.cancel()
        let failed = expectation(description: "ended capture surfaced")
        let failureObserver = model.$error.compactMap { $0 }.sink { text in
            if text.contains("Audio capture ended") { failed.fulfill() }
        }
        audio.continuation?.finish()
        await fulfillment(of: [failed], timeout: 2)
        failureObserver.cancel()
        XCTAssertFalse(model.listening)
        XCTAssertFalse(model.connecting)
        model.stop()
    }

    func testFirstCodingQuestionAfterDemoRetainsTaskAndFollowUpContext() async {
        var requests: [AnswerRequest] = []
        let model = MeetingModel(
            credentials: CredentialAccess { "test-only" },
            screen: ScreenContextController(captureFactory: { FeatureScreenCapture() }),
            answerStreamer: { request, delta in
                requests.append(request)
                delta("SAY THIS: Use a loop. EXAMPLE: A Java loop.")
            })
        model.hasKey = true
        model.preview()
        model.mode = .coding
        model.setScreenWatching(false)  // This test exercises the text/editor-only path.
        let question = "Write Java code to reverse a string."
        for text in [question, "Why?"] {
            let finished = expectation(description: text)
            let observer = model.$cards.sink {
                if $0.first?.question == text, $0.first?.finished == true { finished.fulfill() }
            }
            model.ask(text)
            await fulfillment(of: [finished], timeout: 2)
            observer.cancel()
        }
        XCTAssertEqual(model.codingTask, question)
        XCTAssertEqual(requests.first?.codingTask, question)
        XCTAssertTrue(requests.last?.context.contains(question) == true)
        XCTAssertFalse(requests.last?.context.contains("Kafka") == true)
        model.stop()
    }

    func testFortyRapidFastQuestionsUseTheirOwnAudioItemsWithoutProviderFallback() async throws {
        let (model, client, socket) = try await connected(fast: true) { _, _ in
            XCTFail("Fast questions must use the established realtime connection")
        }
        defer { model.stop() }
        let first = expectation(description: "first fast request sent")
        socket.onSend = { if $0 == "response.create" { first.fulfill() } }
        socket.push(["type": "input_audio_buffer.committed", "item_id": "0"])
        emit(socket, id: "0", text: "Explain subject0.")
        await fulfillment(of: [first], timeout: 2)
        socket.onSend = nil
        for index in 1..<40 {
            socket.push(["type": "input_audio_buffer.committed", "item_id": String(index)])
            emit(socket, id: String(index), text: "Explain subject\(index).")
        }
        await barrier(client, socket: socket)
        XCTAssertEqual(model.waitingQuestionCount, 39)
        for index in 0..<40 {
            let request =
                socket.packets.last(where: { $0["type"] as? String == "response.create" })!["response"]
                as! [String: Any]
            let input = request["input"] as! [[String: Any]]
            XCTAssertEqual(input[0]["id"] as? String, String(index))
            let id = "answer-\(index)"
            let next = expectation(description: "fast answer transition \(index)")
            var observer: AnyCancellable?
            if index < 39 {
                socket.onSend = { if $0 == "response.create" { next.fulfill() } }
            } else {
                observer = model.$cards.sink {
                    if $0.first?.question == "Explain subject39.", $0.first?.finished == true {
                        next.fulfill()
                    }
                }
            }
            socket.push([
                "type": "response.created", "response": ["id": id, "metadata": request["metadata"]!],
            ])
            socket.push([
                "type": "response.output_text.delta", "response_id": id,
                "delta": "SAY THIS: Use a transaction. EXAMPLE: Commit atomically.",
            ])
            socket.push(["type": "response.done", "response": ["id": id, "status": "completed"]])
            await fulfillment(of: [next], timeout: 2)
            observer?.cancel()
            socket.onSend = nil
        }
        XCTAssertEqual(socket.packets.filter { $0["type"] as? String == "response.create" }.count, 40)
        XCTAssertEqual(model.waitingQuestionCount, 0)
        XCTAssertEqual(model.cards.count, 10)
    }
}
