import Combine
import CryptoKit
import MeetingCore
import XCTest

@testable import MeetingAssist

@MainActor
final class UpgradeTests: XCTestCase {
    func testFastFailureWithoutTextFallsBackExactlyOnce() async throws {
        let socket = MockSocket()
        let client = LiveTranscriber { _ in socket }
        try await client.connect(
            key: "test-only", model: "gpt-live-transcribe", realtimeAnswerModel: "gpt-realtime-2.1-mini")
        let fallback = expectation(description: "one fallback")
        var calls = 0
        let model = MeetingModel(
            credentials: CredentialAccess { "test-only" }, meetingClient: client,
            screen: ScreenContextController(captureFactory: { FeatureScreenCapture() }),
            answerStreamer: { request, delta in
                calls += 1
                XCTAssertEqual(request.question, "Explain transactions")
                delta("SAY THIS: Use a transaction. EXAMPLE: Commit atomically.")
                fallback.fulfill()
            })
        model.hasKey = true
        model.listening = true
        defer { model.stop() }
        let requested = expectation(description: "fast request")
        socket.onSend = { if $0 == "response.create" { requested.fulfill() } }
        emit(socket, "one", "Explain transactions")
        await fulfillment(of: [requested], timeout: 2)
        await barrier(client, socket)
        XCTAssertEqual(model.cards.first?.route, "Audio")
        socket.onSend = nil
        let response =
            socket.packets.last(where: { $0["type"] as? String == "response.create" })!["response"]
            as! [String: Any]
        let metadata = response["metadata"] as! [String: String]
        let id = metadata["client_run"]!
        socket.push(["type": "response.created", "response": ["id": id, "metadata": metadata]])
        socket.push(["type": "response.done", "response": ["id": id, "status": "failed"]])
        await fulfillment(of: [fallback], timeout: 2)
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(model.cards.first?.route, "Fallback")
        XCTAssertEqual(model.performance.events["Fast fallback"], 1)
    }
    func testSemanticAudioDoesNotSendLocalCommitOrDropSilentFrames() async throws {
        let socket = MockSocket()
        let client = LiveTranscriber { _ in socket }
        try await client.connect(
            key: "test-only", model: "gpt-4o-mini-transcribe", realtimeAnswerModel: "gpt-realtime-2.1-mini",
            semantic: true)
        defer { client.stop() }
        let uploaded = expectation(description: "continuous semantic audio")
        uploaded.expectedFulfillmentCount = 2
        socket.onSend = { if $0 == "input_audio_buffer.append" { uploaded.fulfill() } }
        client.audio(Data(repeating: 1, count: 1920), rms: 0.1, seconds: 0.04)
        client.audio(Data(repeating: 0, count: 1920), rms: 0, seconds: 0.8)
        await fulfillment(of: [uploaded], timeout: 2)
        XCTAssertFalse(
            socket.packets.contains(where: { $0["type"] as? String == "input_audio_buffer.commit" }))
    }
    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }
    private func emit(_ socket: MockSocket, _ id: String, _ text: String) {
        socket.push([
            "type": "conversation.item.input_audio_transcription.completed", "item_id": id,
            "transcript": text,
        ])
    }
    private func connected(
        answer: @escaping (AnswerRequest, @escaping @MainActor (String) -> Void) async throws -> Void
    ) async throws -> (MeetingModel, LiveTranscriber, MockSocket) {
        let socket = MockSocket()
        let client = LiveTranscriber { _ in socket }
        try await client.connect(key: "test-only", model: "gpt-live-transcribe")
        let model = MeetingModel(
            credentials: CredentialAccess { "test-only" }, meetingClient: client,
            screen: ScreenContextController(captureFactory: { FeatureScreenCapture() }),
            answerStreamer: answer)
        model.hasKey = true
        model.listening = true
        return (model, client, socket)
    }
    private func barrier(_ client: LiveTranscriber, _ socket: MockSocket) async {
        let done = expectation(description: "events processed")
        let handler = client.onEvent
        client.onEvent = { event in
            handler?(event)
            if event == .ignored { done.fulfill() }
        }
        socket.push(["type": "rate_limits.updated"])
        await fulfillment(of: [done], timeout: 2)
        client.onEvent = handler
    }
    func testPinnedAnswerSurvivesMoreThanTenArrivalsAndCanNavigateWithoutChangingContextLimit() async throws {
        let done = expectation(description: "answers finished")
        done.expectedFulfillmentCount = 12
        let model = MeetingModel(
            credentials: CredentialAccess { "test-only" },
            screen: ScreenContextController(captureFactory: { FeatureScreenCapture() }),
            answerStreamer: { _, delta in
                delta("SAY THIS: Use a transaction. EXAMPLE: Commit atomically.")
                done.fulfill()
            })
        model.hasKey = true
        model.ask("Explain first transaction")
        let firstReady = expectation(description: "first card ready")
        let observer = model.$answering.dropFirst().sink { if !$0 { firstReady.fulfill() } }
        await fulfillment(of: [firstReady], timeout: 2)
        observer.cancel()
        let first = try XCTUnwrap(model.activeCard)
        model.selectAnswer(first.id)
        for index in 0..<11 {
            let finished = expectation(description: "card \(index)")
            var started = false
            var recorded = false
            let observation = model.$answering.dropFirst().sink {
                if $0 { started = true }
                if !$0 && started && !recorded {
                    recorded = true
                    finished.fulfill()
                }
            }
            model.ask("Explain transaction \(index)")
            await fulfillment(of: [finished], timeout: 2)
            observation.cancel()
        }
        await fulfillment(of: [done], timeout: 2)
        XCTAssertEqual(model.activeCard?.id, first.id)
        XCTAssertEqual(model.cards.count, 10)
        XCTAssertEqual(model.newAnswersCount, 9)
        model.followNewestAnswer()
        XCTAssertEqual(model.activeCard?.id, model.cards.first?.id)
        XCTAssertFalse(model.readingPinned)
        model.browseAnswer(1)
        XCTAssertTrue(model.readingPinned)
    }
    func testUrgentFollowUpPreemptsActiveRequestButPreservesIndependentQueuedQuestion() async throws {
        let started = expectation(description: "first held")
        let follow = expectation(description: "urgent follow-up starts")
        let drained = expectation(description: "independent queued question starts")
        var release: CheckedContinuation<Void, Never>?
        var requests: [AnswerRequest] = []
        let (model, client, socket) = try await connected { request, delta in
            requests.append(request)
            if requests.count == 1 {
                delta("SAY THIS: A transaction makes changes atomic.")
                await withCheckedContinuation {
                    release = $0
                    started.fulfill()
                }
                try Task.checkCancellation()
            }
            if request.question == "Why?" { follow.fulfill() }
            if request.question == "Explain indexes" { drained.fulfill() }
            delta("SAY THIS: Use isolation. EXAMPLE: Protect a write.")
        }
        defer { model.stop() }
        emit(socket, "one", "Explain transactions")
        await fulfillment(of: [started], timeout: 2)
        emit(socket, "why", "Why?")
        emit(socket, "two", "Explain indexes")
        await fulfillment(of: [follow, drained], timeout: 2)
        await barrier(client, socket)
        release?.resume()
        XCTAssertEqual(requests.map(\.question), ["Explain transactions", "Why?", "Explain indexes"])
        XCTAssertTrue(requests[1].context.contains("Linked request (data):\nExplain transactions"))
        XCTAssertTrue(requests[1].context.contains("A transaction makes changes atomic"))
        XCTAssertNotNil(model.cards.first(where: { $0.question == "Why?" })?.parentID)
        XCTAssertEqual(model.performance.events["Interruption prioritized"], 1)
    }
    func testCorrectionReplacesQueuedTargetWithoutDroppingOtherRequests() async throws {
        var release: CheckedContinuation<Void, Never>?
        let started = expectation(description: "first held")
        let corrected = expectation(description: "corrected request")
        var requests: [String] = []
        let (model, client, socket) = try await connected { request, delta in
            requests.append(request.question)
            if requests.count == 1 {
                await withCheckedContinuation {
                    release = $0
                    started.fulfill()
                }
            }
            delta("SAY THIS: Use a lock. EXAMPLE: Guard writes.")
            if request.question.contains("Correction:") { corrected.fulfill() }
        }
        defer { model.stop() }
        emit(socket, "one", "Explain transactions")
        await fulfillment(of: [started], timeout: 2)
        emit(socket, "two", "Explain database locking")
        emit(socket, "fix", "Actually, optimistic locking")
        await barrier(client, socket)
        XCTAssertFalse(model.cards.first?.superseded ?? true)
        release?.resume()
        await fulfillment(of: [corrected], timeout: 2)
        XCTAssertEqual(requests.count, 2)
        XCTAssertTrue(requests[1].contains("Original request: Explain database locking"))
        XCTAssertTrue(requests[1].contains("Correction: Actually, optimistic locking"))
    }
    func testIncompleteQuestionJoinsContinuationWithoutAnExtraRequest() async throws {
        let answered = expectation(description: "joined request")
        var requests: [String] = []
        let (model, client, socket) = try await connected { request, delta in
            requests.append(request.question)
            delta("SAY THIS: Compare messaging. EXAMPLE: Kafka and MQ.")
            answered.fulfill()
        }
        defer { model.stop() }
        emit(socket, "one", "What is Kafka and")
        await barrier(client, socket)
        XCTAssertTrue(requests.isEmpty)
        emit(socket, "two", "how does it compare with MQ?")
        await fulfillment(of: [answered], timeout: 2)
        XCTAssertEqual(requests, ["What is Kafka and how does it compare with MQ?"])
    }
    func testProjectLibraryEncryptedRoundTripTamperAndDeletion() throws {
        let url = try directory().appendingPathComponent("profile.encrypted")
        let key = SymmetricKey(size: .bits256)
        let store = ProjectLibraryStore(url: url, key: { key })
        let library = ProjectLibrary(
            notes: "Confirmed private incident marker",
            incidents: [.init(project: "Payments", symptom: "Race condition")])
        try store.save(library)
        XCTAssertEqual(try store.load(), library)
        XCTAssertFalse(
            String(decoding: try Data(contentsOf: url), as: UTF8.self).contains("private incident marker"))
        var bytes = try Data(contentsOf: url)
        bytes[bytes.count - 1] ^= 1
        try bytes.write(to: url)
        XCTAssertThrowsError(try store.load())
        try store.delete()
        XCTAssertFalse(store.exists)
    }
    func testEditorBridgeIgnoresDisabledExpiredOversizedAndUnknownFrames() throws {
        let root = try directory()
        let bridge = EditorBridge(directory: root)
        let url = root.appendingPathComponent("vscode.json")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let frame = EditorSnapshot(
            editor: "VS Code", file: "Main.java", language: "java", text: "class Main {}", cursorLine: 1,
            diagnostics: ["Missing return"])
        try encoder.encode(frame).write(to: url)
        bridge.poll()
        XCTAssertNil(bridge.snapshot)
        bridge.start()
        bridge.poll()
        XCTAssertEqual(bridge.snapshot?.text, frame.text)
        bridge.poll(now: Date() + 20)
        XCTAssertNil(bridge.snapshot)
        try Data(repeating: 65, count: 250001).write(to: url)
        bridge.poll()
        XCTAssertNil(bridge.snapshot)
        bridge.stop()
        XCTAssertNil(bridge.current())
    }
    func testConnectedEditorContextAndRelevantEvidenceReachRequestWithoutScreenshot() async throws {
        let root = try directory()
        let bridge = EditorBridge(directory: root)
        let frame = EditorSnapshot(
            editor: "VS Code", file: "Main.java", language: "java", text: "class Main { int count; }",
            cursorLine: 1, diagnostics: ["Missing return"])
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(frame).write(to: root.appendingPathComponent("vscode.json"))
        let answered = expectation(description: "editor answer")
        let model = MeetingModel(
            credentials: CredentialAccess { "test-only" },
            screen: ScreenContextController(captureFactory: { FeatureScreenCapture() }),
            answerStreamer: { request, delta in
                XCTAssertNil(request.screenImage)
                XCTAssertTrue(request.context.contains("Main.java"))
                XCTAssertTrue(request.context.contains("Missing return"))
                XCTAssertTrue(request.context.contains("Race condition"))
                delta("SAY THIS: Guard count. EXAMPLE: Lock the write.")
                answered.fulfill()
            }, editor: bridge)
        model.hasKey = true
        model.mode = .coding
        model.setScreenWatching(false)  // This test exercises the text/editor-only path.
        model.autoGuide = false
        model.incidents = [.init(project: "Payments", symptom: "Race condition")]
        model.setEditorEnabled(true)
        model.ask("Explain the race condition in my code")
        await fulfillment(of: [answered], timeout: 2)
        XCTAssertEqual(model.activeCard?.route, "Editor")
        model.mode = .questions
        XCTAssertFalse(bridge.enabled)
    }
    func testIsolatedJavaCompilationSampleAssertionAndPersonalFileDenial() async throws {
        let compiled = try await CodeValidation.checkJava(
            "public class Main { public static void main(String[] args) { System.out.println(\"hello\"); } }")
        XCTAssertTrue(compiled.successful, compiled.details)
        XCTAssertEqual(compiled.label, "Compiled · tests not run")
        let sample = try await CodeValidation.checkJava(
            "public class Main { public static void main(String[] args) { System.out.println(\"hello\"); } }",
            run: true, expected: "hello")
        XCTAssertTrue(sample.successful, sample.details)
        XCTAssertEqual(sample.label, "Sample assertion passed")
        let bad = try await CodeValidation.checkJava("public class Main { int value = ; }")
        XCTAssertFalse(bad.successful)
        let sentinel = try directory().appendingPathComponent("private.txt")
        try Data("PRIVATE_SENTINEL".utf8).write(to: sentinel)
        let source =
            "public class Main { public static void main(String[] args) throws Exception { System.out.println(java.nio.file.Files.readString(java.nio.file.Path.of(\"\(sentinel.path)\"))); } }"
        let denied = try await CodeValidation.checkJava(source, run: true)
        XCTAssertFalse(denied.successful)
        XCTAssertFalse(denied.details.contains("PRIVATE_SENTINEL"))
    }
    func testAdaptiveComplexQuestionUsesDeeperRequest() async throws {
        let answered = expectation(description: "deep answer")
        let model = MeetingModel(
            credentials: CredentialAccess { "test-only" },
            screen: ScreenContextController(captureFactory: { FeatureScreenCapture() }),
            answerStreamer: { request, delta in
                XCTAssertTrue(request.expanded)
                delta("SAY THIS: Partition work. EXAMPLE: Use shards.")
                answered.fulfill()
            })
        model.hasKey = true
        model.ask("Design a distributed system")
        await fulfillment(of: [answered], timeout: 2)
        XCTAssertEqual(model.activeCard?.route, "Deep")
    }
}
