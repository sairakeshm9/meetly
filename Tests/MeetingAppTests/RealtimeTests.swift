import MeetingCore
import XCTest

@testable import MeetingAssist

@MainActor
final class MockSocket: @preconcurrency RealtimeSocket {
    var packets: [[String: Any]] = []
    var queued: [URLSessionWebSocketTask.Message] = []
    var waiting: CheckedContinuation<URLSessionWebSocketTask.Message, Error>?
    var onSend: ((String) -> Void)?
    var reject: String?
    var autoHandshake = true
    var closed = false
    func resume() {}
    func send(_ message: URLSessionWebSocketTask.Message) async throws {
        guard !closed else { throw CancellationError() }
        guard case .string(let text) = message,
            let packet = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]
        else { return }
        packets.append(packet)
        let type = packet["type"] as? String ?? ""
        if type == "session.update" && autoHandshake {
            if let reject {
                push(["type": "error", "error": ["message": reject]])
            } else {
                push(["type": "session.updated"])
            }
        }
        onSend?(type)
    }
    func receive() async throws -> URLSessionWebSocketTask.Message {
        if closed { throw CancellationError() }
        if !queued.isEmpty { return queued.removeFirst() }
        return try await withCheckedThrowingContinuation { waiting = $0 }
    }
    func push(_ event: [String: Any]) {
        let message = URLSessionWebSocketTask.Message.string(
            String(decoding: try! JSONSerialization.data(withJSONObject: event), as: UTF8.self))
        if let waiting {
            self.waiting = nil
            waiting.resume(returning: message)
        } else {
            queued.append(message)
        }
    }
    func close() {
        closed = true
        waiting?.resume(throwing: CancellationError())
        waiting = nil
    }
}

final class RealtimeTests: XCTestCase {
    @MainActor
    func testCancellingAnOldHandshakeCannotCloseNewConnection() async throws {
        let first = MockSocket()
        first.autoHandshake = false
        let second = MockSocket()
        let sent = expectation(description: "first handshake sent")
        first.onSend = { if $0 == "session.update" { sent.fulfill() } }
        var calls = 0
        let client = LiveTranscriber { _ in
            calls += 1
            return calls == 1 ? first : second
        }
        let old = Task { try await client.connect(key: "test-only", model: "gpt-live-transcribe") }
        await fulfillment(of: [sent], timeout: 2)
        client.stop()
        try await client.connect(key: "test-only", model: "gpt-live-transcribe")
        do {
            try await old.value
            XCTFail("Old handshake must be cancelled")
        } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertFalse(second.closed)
        client.stop()
    }
    @MainActor
    func testHandshakeOrderedUploadCommitAndStop() async throws {
        let socket = MockSocket()
        let client = LiveTranscriber { request in
            XCTAssertEqual(request.url?.query, "intent=transcription")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-only")
            return socket
        }
        try await client.connect(key: "test-only", model: "gpt-live-transcribe")
        XCTAssertEqual(socket.packets.first?["type"] as? String, "session.update")
        let committed = expectation(description: "ordered commit sent")
        socket.onSend = { if $0 == "input_audio_buffer.commit" { committed.fulfill() } }
        let pcm = Data(repeating: 0, count: 4800)
        client.audio(pcm, rms: 0.1, seconds: 0.1)
        client.audio(pcm, rms: 0, seconds: 0.7)
        await fulfillment(of: [committed], timeout: 2)
        XCTAssertEqual(
            socket.packets.map { $0["type"] as? String },
            [
                "session.update", "input_audio_buffer.append", "input_audio_buffer.append",
                "input_audio_buffer.commit",
            ])
        client.stop()
        XCTAssertTrue(socket.closed)
        let count = socket.packets.count
        client.audio(pcm, rms: 0.1, seconds: 1)
        XCTAssertEqual(socket.packets.count, count)
    }
    @MainActor
    func testTranscriptionCallbackAndSecretRedaction() async throws {
        let socket = MockSocket()
        let client = LiveTranscriber { _ in socket }
        try await client.connect(key: "test-only", model: "gpt-live-transcribe")
        let completed = expectation(description: "final transcript delivered")
        let failure = expectation(description: "error surfaced")
        client.onEvent = { event in
            if case .completed(let id, let text) = event {
                XCTAssertEqual(id, "a")
                XCTAssertEqual(text, "Explain Kafka")
                completed.fulfill()
            }
        }
        client.onFailure = { text in
            XCTAssertFalse(text.contains("sk-test-abcdefghijklmnop"))
            failure.fulfill()
        }
        socket.push([
            "type": "conversation.item.input_audio_transcription.completed", "item_id": "a",
            "transcript": "Explain Kafka",
        ])
        await fulfillment(of: [completed], timeout: 2)
        socket.push(["type": "error", "error": ["message": "invalid sk-test-abcdefghijklmnop"]])
        await fulfillment(of: [failure], timeout: 2)
        XCTAssertTrue(socket.closed)
    }
    @MainActor
    func testSpeechEndTimingFollowsCommittedItemsAndClearsOnRestart() async throws {
        let socket = MockSocket()
        let client = LiveTranscriber { _ in socket }
        try await client.connect(key: "test-only", model: "gpt-live-transcribe")
        let sent = expectation(description: "two commits uploaded")
        sent.expectedFulfillmentCount = 2
        socket.onSend = { if $0 == "input_audio_buffer.commit" { sent.fulfill() } }
        let pcm = Data(repeating: 0, count: 4800)
        let first = Date(timeIntervalSince1970: 100)
        let second = first.addingTimeInterval(1)
        for end in [first, second] {
            client.audio(pcm, rms: 0.1, seconds: 0.1, capturedAt: end)
            client.audio(pcm, rms: 0, seconds: 0.4, capturedAt: end.addingTimeInterval(0.4))
        }
        await fulfillment(of: [sent], timeout: 2)
        let delivered = expectation(description: "out-of-order completions retain timing")
        delivered.expectedFulfillmentCount = 2
        client.onEvent = { event in
            if case .completed(let id, _) = event {
                XCTAssertEqual(client.speechEndedAt(for: id), id == "a" ? first : second)
                delivered.fulfill()
            }
        }
        for id in ["a", "b"] { socket.push(["type": "input_audio_buffer.committed", "item_id": id]) }
        for id in ["b", "a"] {
            socket.push([
                "type": "conversation.item.input_audio_transcription.completed", "item_id": id,
                "transcript": "What is Spring?",
            ])
        }
        await fulfillment(of: [delivered], timeout: 2)
        XCTAssertNil(client.speechEndedAt(for: "a"))
        client.stop()
        XCTAssertNil(client.speechEndedAt(for: "b"))
    }
    @MainActor
    func testRejectedHandshakeDoesNotStartAudio() async {
        let socket = MockSocket()
        socket.reject = "model unavailable"
        let client = LiveTranscriber { _ in socket }
        do {
            try await client.connect(key: "test-only", model: "gpt-live-transcribe")
            XCTFail("Rejected session must throw")
        } catch { XCTAssertTrue(error.localizedDescription.contains("model unavailable")) }
        XCTAssertTrue(socket.closed)
        XCTAssertEqual(socket.packets.count, 1)
    }
    @MainActor
    func testRestartUsesFreshSocketAndResetsSpeechGate() async throws {
        let first = MockSocket()
        let second = MockSocket()
        var count = 0
        let client = LiveTranscriber { _ in
            count += 1
            return count == 1 ? first : second
        }
        try await client.connect(key: "test-only", model: "gpt-live-transcribe")
        client.audio(Data(repeating: 0, count: 4800), rms: 0.1, seconds: 0.1)
        client.stop()
        try await client.connect(key: "test-only", model: "gpt-live-transcribe")
        client.audio(Data(repeating: 0, count: 4800), rms: 0, seconds: 1)
        XCTAssertTrue(first.closed)
        XCTAssertEqual(second.packets.count, 1)
        client.stop()
    }
}
