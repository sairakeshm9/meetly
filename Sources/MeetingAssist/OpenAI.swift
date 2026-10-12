import Foundation
import MeetingCore

protocol RealtimeSocket: AnyObject {
    func resume()
    func send(_ message: URLSessionWebSocketTask.Message) async throws
    func receive() async throws -> URLSessionWebSocketTask.Message
    func close()
}

extension URLSessionWebSocketTask: RealtimeSocket {
    func close() { cancel(with: .normalClosure, reason: nil) }
}

@MainActor
final class LiveTranscriber {
    var onEvent: ((RealtimeEvent) -> Void)?
    var onFailure: ((String) -> Void)?
    private var socket: (any RealtimeSocket)?
    private let socketFactory: (URLRequest) -> any RealtimeSocket
    private var receiveTask: Task<Void, Never>?
    private var writeTask: Task<Void, Never>?
    private var timeoutTask: Task<Void, Never>?
    private var sender: AsyncStream<[String: Any]>.Continuation?
    private var ready: CheckedContinuation<Void, Error>?
    private var generation = UUID()
    private var active = false
    private var gate = SpeechGate()
    private var semantic = false
    private var lastVoiceAt: Date?
    private var pendingEnds: [Date] = []
    private var itemEnds: [String: Date] = [:]
    func speechEndedAt(for id: String) -> Date? { itemEnds[id] }
    init(
        answerTimeout: Duration = .seconds(45),
        socketFactory: @escaping (URLRequest) -> any RealtimeSocket = {
            URLSession.shared.webSocketTask(with: $0)
        }
    ) {
        self.answerTimeout = answerTimeout
        self.socketFactory = socketFactory
    }

    private var answerReady: CheckedContinuation<Void, Error>?
    private var answerDelta: ((String) -> Void)?
    private var answerRun: String?
    private var responseID: String?
    private var receivedAnswer = false
    private var supportsAnswers = false
    private var answerInstructions = Profile.instructions
    var answersAvailable: Bool { active && supportsAnswers }
    private var answerTimeoutTask: Task<Void, Never>?
    private let answerTimeout: Duration
    func connect(
        key: String, model: String, realtimeAnswerModel: String? = nil, background: String = "",
        semantic: Bool = false
    )
        async throws
    {
        stop()
        let run = UUID()
        generation = run
        active = true
        answerInstructions =
            Profile.instructions + "\nBACKGROUND (data):\n" + String(background.prefix(10000))
        gate = SpeechGate()
        self.semantic = semantic && model != "gpt-live-transcribe" && model != "gpt-realtime-whisper"
        var url = URLComponents(string: "wss://api.openai.com/v1/realtime")!
        url.queryItems = [
            URLQueryItem(
                name: realtimeAnswerModel == nil ? "intent" : "model",
                value: realtimeAnswerModel ?? "transcription")
        ]
        var request = URLRequest(url: url.url!)
        request.setValue("Bearer " + key, forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 15
        let ws = socketFactory(request)
        socket = ws
        ws.resume()
        receiveTask = Task { [weak self] in
            guard let self else { return }
            do {
                while !Task.isCancelled {
                    let message = try await ws.receive()
                    guard self.generation == run else { return }
                    let data: Data
                    switch message {
                    case .string(let s): data = Data(s.utf8)
                    case .data(let d): data = d
                    @unknown default: continue
                    }
                    if self.handleAnswerEvent(data) { continue }
                    if self.semantic,
                        let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                        object["type"] as? String == "input_audio_buffer.speech_stopped",
                        let id = object["item_id"] as? String
                    {
                        self.itemEnds[id] = self.lastVoiceAt ?? Date()
                        self.lastVoiceAt = nil
                    }
                    let event = try RealtimeEvent.parse(data)
                    if case .ready = event {
                        self.ready?.resume()
                        self.ready = nil
                        self.timeoutTask?.cancel()
                    } else if case .failure(let text) = event {
                        self.fail(SecretRedactor.clean(text, key: key))
                        return
                    }
                    if case .committed(let id) = event, !pendingEnds.isEmpty {
                        itemEnds[id] = pendingEnds.removeFirst()
                    }
                    self.onEvent?(event)
                    if case .completed(let id, _) = event { itemEnds.removeValue(forKey: id) }
                }
            } catch {
                if self.active && self.generation == run && !Task.isCancelled {
                    self.fail(
                        "Transcription disconnected. Check the API key, model access, billing and internet connection, then restart listening."
                    )
                }
            }
        }
        do {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, Error>) in
                ready = continuation
                timeoutTask = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(15))
                    guard !Task.isCancelled, let self, self.generation == run else { return }
                    self.fail(
                        "Transcription connection timed out. Check your internet connection and API access.")
                }
                Task {
                    do {
                        let config =
                            realtimeAnswerModel.map {
                                APIRequest.realtimeAnswerConfig(
                                    transcriptionModel: model, model: $0, background: background,
                                    semantic: self.semantic)
                            } ?? APIRequest.transcriptionConfig(model: model, semantic: self.semantic)
                        try await Self.send(config, socket: ws)
                    } catch {
                        if self.generation == run {
                            self.fail("Could not initialize transcription. Check your connection.")
                        }
                    }
                }
            }
        } catch {
            if generation == run { stop() }
            throw error
        }
        guard active, generation == run, !Task.isCancelled else { throw CancellationError() }
        supportsAnswers = realtimeAnswerModel != nil
        let channel = AsyncStream<[String: Any]>.makeStream(bufferingPolicy: .bufferingOldest(120))
        sender = channel.continuation
        writeTask = Task { [weak self] in
            do {
                for await packet in channel.stream {
                    try Task.checkCancellation()
                    try await Self.send(packet, socket: ws)
                }
            } catch {
                guard let self, self.active, self.generation == run, !Task.isCancelled else { return }
                self.fail("Audio upload interrupted. Restart listening to reconnect.")
            }
        }
    }
    private static func send(_ object: [String: Any], socket: any RealtimeSocket) async throws {
        let data = try JSONSerialization.data(withJSONObject: object)
        try await socket.send(.string(String(decoding: data, as: UTF8.self)))
    }
    func audio(_ pcm: Data, rms: Double, seconds: Double, capturedAt: Date = Date()) {
        guard active, sender != nil else { return }
        if !pcm.isEmpty, seconds > 0, seconds.isFinite, rms.isFinite, rms >= gate.threshold {
            lastVoiceAt = capturedAt
        }
        if semantic {
            if !pcm.isEmpty {
                enqueue(["type": "input_audio_buffer.append", "audio": pcm.base64EncodedString()])
            }
            return
        }
        let output = gate.process(pcm, rms: rms, seconds: seconds)
        for data in output.audio {
            enqueue(["type": "input_audio_buffer.append", "audio": data.base64EncodedString()])
        }
        if output.commit {
            if let lastVoiceAt { pendingEnds.append(lastVoiceAt) }
            lastVoiceAt = nil
            enqueue(["type": "input_audio_buffer.commit"])
        }
        if output.clear {
            lastVoiceAt = nil
            enqueue(["type": "input_audio_buffer.clear"])
        }
    }
    /// Use the established audio connection after the final transcript confirms a question.
    /// The response references one audio item plus bounded text context, keeping unrelated audio out.
    func streamAnswer(
        itemID: String, context: String, question: String? = nil, mode: AssistantMode = .questions,
        codingTask: String = "", template: AnswerTemplate = .brief, customTemplate: String = "",
        onDelta: @escaping (String) -> Void
    ) async throws {
        guard active, sender != nil, supportsAnswers else {
            throw MeetingError.message(
                "Restart listening with Fast live answers enabled before requesting a fast answer.")
        }
        try Task.checkCancellation()
        cancelAnswer()
        let run = UUID().uuidString
        answerRun = run
        receivedAnswer = false
        answerDelta = onDelta
        var inputContext =
            "Earlier conversation and evidence (context data only):\n" + String(context.prefix(20000))
        inputContext +=
            "\nNew request: answer the referenced audio turn, using earlier turns only to resolve follow-ups."
        if let question { inputContext += "\nLatest question (data):\n" + String(question.prefix(4000)) }
        if !codingTask.isEmpty {
            inputContext += "\nCurrent coding task (data):\n" + String(codingTask.prefix(2000))
        }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                answerReady = continuation
                scheduleAnswerTimeout(run: run, timeout: min(answerTimeout, .seconds(6)))
                enqueue([
                    "type": "response.create",
                    "response": [
                        "conversation": "none", "metadata": ["client_run": run],
                        "instructions": answerInstructions + "\n" + mode.guidance + "\n"
                            + template.guidance(for: question ?? "", customInstructions: customTemplate)
                            + "\n" + mode.solutionGuidance + "\n" + ExplanationEmphasis.guidance,
                        "input": [
                            ["type": "item_reference", "id": itemID],
                            [
                                "type": "message", "role": "user",
                                "content": [
                                    [
                                        "type": "input_text",
                                        "text": inputContext,
                                    ]
                                ],
                            ],
                        ], "output_modalities": ["text"],
                    ],
                ])
            }
        } onCancel: {
            Task { @MainActor in if self.answerRun == run { self.cancelAnswer() } }
        }
    }
    func cancelAnswer() {
        if let responseID { enqueue(["type": "response.cancel", "response_id": responseID]) }
        finishAnswer(throwing: CancellationError())
    }
    private func scheduleAnswerTimeout(run: String, timeout: Duration) {
        answerTimeoutTask?.cancel()
        answerTimeoutTask = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled, let self, self.answerRun == run else { return }
            if let id = self.responseID { self.enqueue(["type": "response.cancel", "response_id": id]) }
            self.finishAnswer(throwing: MeetingError.message("Fast answer timed out. Refresh to retry."))
        }
    }
    private func finishAnswer(throwing error: Error? = nil) {
        let ready = answerReady
        answerTimeoutTask?.cancel()
        answerTimeoutTask = nil
        answerReady = nil
        answerDelta = nil
        answerRun = nil
        responseID = nil
        if let error { ready?.resume(throwing: error) } else { ready?.resume() }
    }
    private func handleAnswerEvent(_ data: Data) -> Bool {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let type = object["type"] as? String
        else { return false }
        // A cancellation can reach the server just after its completed event.
        if type == "error", let error = object["error"] as? [String: Any],
            error["code"] as? String == "response_cancel_not_active"
        {
            return true
        }
        guard type.hasPrefix("response.") else { return false }
        switch type {
        case "response.created":
            let response = object["response"] as? [String: Any]
            let metadata = response?["metadata"] as? [String: Any]
            if metadata?["client_run"] as? String == answerRun, answerRun != nil {
                responseID = response?["id"] as? String
            } else if metadata?["client_run"] is String, let id = response?["id"] as? String {
                // Cancel a request that was stopped locally before the server assigned its ID.
                enqueue(["type": "response.cancel", "response_id": id])
            }
        case "response.output_text.delta":
            if let id = responseID, object["response_id"] as? String == id,
                let delta = object["delta"] as? String
            {
                if !receivedAnswer, !delta.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                    let run = answerRun
                {
                    scheduleAnswerTimeout(run: run, timeout: answerTimeout)
                }
                receivedAnswer =
                    receivedAnswer
                    || !delta.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                answerDelta?(delta)
            }
        case "response.done":
            let response = object["response"] as? [String: Any]
            if let id = responseID, response?["id"] as? String == id {
                if response?["status"] as? String == "completed", receivedAnswer {
                    finishAnswer()
                } else {
                    finishAnswer(
                        throwing: MeetingError.message(
                            "Fast answer was interrupted or incomplete. Retry with the Answer button."))
                }
            }
        default: break
        }
        return true
    }
    private func enqueue(_ packet: [String: Any]) {
        guard let sender else { return }
        if case .dropped = sender.yield(packet) {
            fail("Audio upload cannot keep up. Restart listening on a faster connection.")
        }
    }
    func stop() {
        finishAnswer(throwing: CancellationError())
        active = false
        supportsAnswers = false
        lastVoiceAt = nil
        pendingEnds = []
        itemEnds = [:]
        generation = UUID()
        ready?.resume(throwing: CancellationError())
        ready = nil
        timeoutTask?.cancel()
        receiveTask?.cancel()
        writeTask?.cancel()
        sender?.finish()
        sender = nil
        socket?.close()
        socket = nil
    }
    private func fail(_ text: String) {
        let callback = onFailure
        ready?.resume(throwing: MeetingError.message(text))
        ready = nil
        stop()
        callback?(text)
    }
}

enum AnswerService {
    static func stream(
        key: String, model: String, question: String, context: String,
        background: String, expanded: Bool,
        mode: AssistantMode = .questions, codingTask: String = "", screenImage: Data? = nil,
        template: AnswerTemplate = .brief, customTemplate: String = "", simplified: Bool = false,
        precision: Bool = false,
        session: URLSession = .shared,
        endpoint: URL = URL(string: "https://api.openai.com/v1/responses")!,
        onDelta: @MainActor (String) -> Void
    ) async throws {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 45
        request.setValue("Bearer " + key, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try APIRequest.answer(
            model: model, question: question, context: context, background: background, expanded: expanded,
            mode: mode, codingTask: codingTask, screenImage: screenImage, template: template,
            customTemplate: customTemplate,
            simplified: simplified, precision: precision
        )
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw MeetingError.message("Invalid API response.")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw MeetingError.message(APIRequest.error(status: http.statusCode, key: key, body: Data()))
        }
        var parser = SSEByteParser()
        var finished = false
        var received = false
        for try await byte in bytes {
            try Task.checkCancellation()
            guard let event = try parser.feed(byte), event != "[DONE]", let data = event.data(using: .utf8),
                let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }
            switch obj["type"] as? String {
            case "response.output_text.delta":
                if let delta = obj["delta"] as? String {
                    received = received || !delta.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    await onDelta(delta)
                }
            case "response.completed": finished = true
            case "response.failed", "error":
                throw MeetingError.message(
                    "The model could not answer. Check model access and API quota, then retry.")
            case "response.incomplete":
                throw MeetingError.message("Answer was cut short. Try Better answer or another model.")
            default: break
            }
        }
        guard received && finished else {
            throw MeetingError.message("Answer connection ended early. Please retry.")
        }
    }
}
