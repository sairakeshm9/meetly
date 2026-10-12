import Combine
import MeetingCore
import XCTest

@testable import MeetingAssist

final class FastAnswerTests: XCTestCase {
    @MainActor
    private func responseCreated(_ socket: MockSocket, id: String) {
        let request = socket.packets.last { $0["type"] as? String == "response.create" }!
        let response = request["response"] as! [String: Any]
        socket.push(["type": "response.created", "response": ["id": id, "metadata": response["metadata"]!]])
    }
    @MainActor
    func testFinalQuestionUsesEstablishedAudioConnectionAndStatementStaysQuiet() async {
        let socket = MockSocket()
        let client = LiveTranscriber { request in
            XCTAssertEqual(request.url?.query, "model=gpt-realtime-2.1-mini")
            return socket
        }
        do {
            try await client.connect(
                key: "test-only", model: "gpt-live-transcribe", realtimeAnswerModel: "gpt-realtime-2.1-mini",
                background: Profile.context)
        } catch {
            XCTFail(error.localizedDescription)
            return
        }
        let model = MeetingModel(credentials: CredentialAccess { "test-only" }, meetingClient: client)
        model.hasKey = true
        model.listening = true
        let finished = expectation(description: "automatic fast answer shown and finished")
        let observer = model.$cards.sink { cards in
            if let card = cards.first, card.finished {
                XCTAssertEqual(card.question, "What is dependency injection?")
                XCTAssertEqual(
                    card.answer, "SAY THIS: Spring supplies dependencies. EXAMPLE: Use constructor injection."
                )
                XCTAssertNotNil(card.timing?.firstUsefulSeconds)
                XCTAssertNotNil(card.timing?.questionEndedAt)
                finished.fulfill()
            }
        }
        socket.onSend = { type in
            if type == "input_audio_buffer.commit" {
                socket.push(["type": "input_audio_buffer.committed", "item_id": "q"])
                // Partial text must not cause generation.
                socket.push([
                    "type": "conversation.item.input_audio_transcription.delta", "item_id": "q",
                    "delta": "What is",
                ])
                socket.push([
                    "type": "conversation.item.input_audio_transcription.completed", "item_id": "q",
                    "transcript": "What is dependency injection?",
                ])
            } else if type == "response.create" {
                let response = socket.packets.last!["response"] as! [String: Any]
                XCTAssertEqual(response["conversation"] as? String, "none")
                let input = response["input"] as! [[String: Any]]
                XCTAssertEqual(input[0]["id"] as? String, "q")
                self.responseCreated(socket, id: "answer")
                socket.push([
                    "type": "response.output_text.delta", "response_id": "other", "delta": "Must be ignored",
                ])
                socket.push([
                    "type": "response.output_text.delta", "response_id": "answer",
                    "delta": "SAY THIS: Spring supplies dependencies. EXAMPLE: Use constructor injection.",
                ])
                socket.push(["type": "response.done", "response": ["id": "answer", "status": "completed"]])
            }
        }
        let pcm = Data(repeating: 0, count: 4800)
        client.audio(pcm, rms: 0.1, seconds: 0.1)
        client.audio(pcm, rms: 0, seconds: 0.4)
        await fulfillment(of: [finished], timeout: 2)
        XCTAssertEqual(socket.packets.filter { $0["type"] as? String == "response.create" }.count, 1)
        let heard = expectation(description: "statement and disabled-auto question are transcribed")
        heard.expectedFulfillmentCount = 2
        let turnObserver = model.$turns.sink { turns in
            if turns.last?.final == true, ["Meeting:statement", "Meeting:disabled"].contains(turns.last?.id) {
                heard.fulfill()
            }
        }
        socket.push([
            "type": "conversation.item.input_audio_transcription.completed", "item_id": "statement",
            "transcript": "Thanks, that helps.",
        ])
        model.autoAnswer = false
        socket.push([
            "type": "conversation.item.input_audio_transcription.completed", "item_id": "disabled",
            "transcript": "Explain Kafka partitions.",
        ])
        await fulfillment(of: [heard], timeout: 2)
        XCTAssertEqual(socket.packets.filter { $0["type"] as? String == "response.create" }.count, 1)
        withExtendedLifetime((observer, turnObserver)) {}
        model.stop()
    }
    @MainActor
    func testPreparedTextStaysHiddenUntilFinalQuestionAndStatementIsDiscarded() async throws {
        let socket = MockSocket()
        let client = LiveTranscriber { _ in socket }
        try await client.connect(
            key: "test-only", model: "gpt-live-transcribe", realtimeAnswerModel: "gpt-realtime-2.1-mini")
        let model = MeetingModel(credentials: CredentialAccess { "test-only" }, meetingClient: client)
        model.hasKey = true
        model.listening = true
        var marker: XCTestExpectation?
        let handler = client.onEvent
        client.onEvent = { event in
            handler?(event)
            if event == .ignored {
                marker?.fulfill()
                marker = nil
            }
        }
        socket.onSend = { type in
            if type == "response.create" {
                let id = UUID().uuidString
                self.responseCreated(socket, id: id)
                socket.push([
                    "type": "response.output_text.delta", "response_id": id,
                    "delta": "SAY THIS: Spring supplies dependencies. EXAMPLE: Use constructor injection.",
                ])
                socket.push(["type": "response.done", "response": ["id": id, "status": "completed"]])
                socket.push(["type": "rate_limits.updated"])
            }
        }
        for (item, text) in [("q", "What is dependency injection?"), ("statement", "Thanks, that helps.")] {
            let buffered = expectation(description: "prepared answer events processed")
            marker = buffered
            socket.push(["type": "input_audio_buffer.committed", "item_id": item])
            await fulfillment(of: [buffered], timeout: 2)
            XCTAssertEqual(model.cards.count, item == "q" ? 0 : 1)
            let delivered = expectation(description: "final transcript accepted")
            let observer = model.$turns.sink { turns in
                if turns.last?.id == "Meeting:" + item, turns.last?.final == true { delivered.fulfill() }
            }
            socket.push([
                "type": "conversation.item.input_audio_transcription.completed", "item_id": item,
                "transcript": text,
            ])
            await fulfillment(of: [delivered], timeout: 2)
            observer.cancel()
            XCTAssertEqual(model.cards.count, 1)
            XCTAssertEqual(model.cards.first?.question, "What is dependency injection?")
            XCTAssertTrue(model.cards.first?.answer.contains("EXAMPLE:") ?? false)
        }
        XCTAssertEqual(socket.packets.filter { $0["type"] as? String == "response.create" }.count, 2)
        model.autoAnswer = false
        let disabled = expectation(description: "disabled-auto committed turn processed")
        marker = disabled
        socket.push(["type": "input_audio_buffer.committed", "item_id": "disabled"])
        socket.push(["type": "rate_limits.updated"])
        await fulfillment(of: [disabled], timeout: 2)
        XCTAssertEqual(socket.packets.filter { $0["type"] as? String == "response.create" }.count, 2)
        model.stop()
    }
    @MainActor
    func testSpokenPoliteCodingRequestsDisplayPreparedCode() async throws {
        let socket = MockSocket()
        let client = LiveTranscriber { _ in socket }
        try await client.connect(
            key: "test-only", model: "gpt-live-transcribe", realtimeAnswerModel: "gpt-realtime-2.1-mini")
        let model = MeetingModel(credentials: CredentialAccess { "test-only" }, meetingClient: client)
        model.hasKey = true
        model.listening = true
        let answer =
            "SAY THIS: Reverse the characters.\nEXAMPLE:\n```java\nstatic String reverse(String s) {\n    return new StringBuilder(s).reverse().toString();\n}\n```\nInput: hello; Output: olleh."
        socket.onSend = { type in
            guard type == "response.create" else { return }
            let responseID = UUID().uuidString
            self.responseCreated(socket, id: responseID)
            socket.push([
                "type": "response.output_text.delta", "response_id": responseID, "delta": answer,
            ])
            socket.push(["type": "response.done", "response": ["id": responseID, "status": "completed"]])
        }
        for (index, question) in [
            "Please write a Java program to reverse a string",
            "Okay, so generate a SQL query to find the second highest salary",
        ].enumerated() {
            let finished = expectation(description: "coding request automatically displayed")
            var recorded = false
            let observer = model.$cards.sink { cards in
                guard let card = cards.first, card.question == question, card.finished, !recorded else {
                    return
                }
                recorded = true
                XCTAssertEqual(card.answer, answer)
                XCTAssertFalse(card.interrupted)
                XCTAssertTrue(AnswerBlock.parse(card.answer).contains(where: \.isCode))
                finished.fulfill()
            }
            let id = "coding-\(index)"
            socket.push(["type": "input_audio_buffer.committed", "item_id": id])
            socket.push([
                "type": "conversation.item.input_audio_transcription.completed", "item_id": id,
                "transcript": question,
            ])
            await fulfillment(of: [finished], timeout: 2)
            observer.cancel()
        }
        XCTAssertEqual(model.cards.count, 2)
        model.stop()
    }
    @MainActor
    func testIncompleteFastAnswerFailsAndStopCancelsPendingAnswer() async throws {
        let socket = MockSocket()
        let client = LiveTranscriber { _ in socket }
        try await client.connect(
            key: "test-only", model: "gpt-live-transcribe", realtimeAnswerModel: "gpt-realtime-2.1-mini")
        socket.onSend = { type in
            if type == "response.create" {
                self.responseCreated(socket, id: "answer")
                socket.push([
                    "type": "response.output_text.delta", "response_id": "answer", "delta": "Partial",
                ])
                socket.push(["type": "response.done", "response": ["id": "answer", "status": "incomplete"]])
            }
        }
        do {
            try await client.streamAnswer(itemID: "q", context: "") { _ in }
            XCTFail("Incomplete answer must fail")
        } catch { XCTAssertTrue(error.localizedDescription.contains("incomplete")) }
        let sent = expectation(description: "next answer requested")
        socket.onSend = { if $0 == "response.create" { sent.fulfill() } }
        let pending = Task { try await client.streamAnswer(itemID: "q2", context: "") { _ in } }
        await fulfillment(of: [sent], timeout: 2)
        client.stop()
        do {
            try await pending.value
            XCTFail("Stop must cancel answer")
        } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertFalse(client.answersAvailable)
    }
    @MainActor
    func testFastAnswerTimesOutWithoutStoppingTranscription() async throws {
        let socket = MockSocket()
        let client = LiveTranscriber(answerTimeout: .milliseconds(100)) { _ in socket }
        try await client.connect(
            key: "test-only", model: "gpt-live-transcribe", realtimeAnswerModel: "gpt-realtime-2.1-mini")
        let cancelled = expectation(description: "timeout cancellation transmitted")
        socket.onSend = {
            if $0 == "response.create" { self.responseCreated(socket, id: "answer") }
            if $0 == "response.cancel" { cancelled.fulfill() }
        }
        do {
            try await client.streamAnswer(itemID: "q", context: "") { _ in }
            XCTFail("Must time out")
        } catch { XCTAssertTrue(error.localizedDescription.contains("timed out")) }
        await fulfillment(of: [cancelled], timeout: 2)
        XCTAssertTrue(client.answersAvailable)
        XCTAssertTrue(socket.packets.contains { $0["type"] as? String == "response.cancel" })
        client.stop()
    }
    @MainActor
    func testCancellationBeforeServerCreatesResponseCancelsItsEventualID() async throws {
        let socket = MockSocket()
        let client = LiveTranscriber { _ in socket }
        try await client.connect(
            key: "test-only", model: "gpt-live-transcribe", realtimeAnswerModel: "gpt-realtime-2.1-mini")
        let sent = expectation(description: "request sent")
        socket.onSend = { if $0 == "response.create" { sent.fulfill() } }
        let pending = Task {
            try await client.streamAnswer(itemID: "q", context: "") { _ in
                XCTFail("Cancelled output must not appear")
            }
        }
        await fulfillment(of: [sent], timeout: 2)
        client.cancelAnswer()
        do {
            try await pending.value
            XCTFail("Must cancel")
        } catch { XCTAssertTrue(error is CancellationError) }
        let cancelled = expectation(description: "late response cancelled")
        socket.onSend = { if $0 == "response.cancel" { cancelled.fulfill() } }
        responseCreated(socket, id: "late")
        await fulfillment(of: [cancelled], timeout: 2)
        socket.push([
            "type": "error", "error": ["code": "response_cancel_not_active", "message": "Already completed"],
        ])
        XCTAssertTrue(client.answersAvailable)
        client.stop()
    }
    @MainActor
    func testTranscriptionOnlyConnectionRejectsFastAnswer() async throws {
        let socket = MockSocket()
        let client = LiveTranscriber { _ in socket }
        try await client.connect(key: "test-only", model: "gpt-live-transcribe")
        do {
            try await client.streamAnswer(itemID: "q", context: "") { _ in }
            XCTFail("Requires fast session")
        } catch { XCTAssertTrue(error.localizedDescription.contains("Fast live answers")) }
        XCTAssertEqual(socket.packets.count, 1)
        client.stop()
    }
}
