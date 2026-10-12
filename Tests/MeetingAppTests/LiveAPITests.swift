import AVFoundation
import Combine
import MeetingCore
import XCTest

@testable import MeetingAssist

// Opt-in only: these tests use paid API calls. Normal local checks and CI skip them.
final class LiveAPITests: XCTestCase {
    @MainActor
    func testLiveAdvancedCodingUsesScreenshotAndDefaultsToJava() async throws {
        let key = try suppliedKey()
        let screenshot = try ScreenSnapshot.read(ScreenContextTests.editorImage())
        var answer = ""
        try await AnswerService.stream(
            key: key, model: "gpt-6-luna",
            question:
                "Show the next navigation step and code change to complete this task from the visible editor.",
            context: "", background: Profile.context, expanded: false, mode: .advancedCoding,
            codingTask: "Reverse a string without built-ins", screenImage: screenshot.jpeg
        ) { answer += $0 }
        XCTAssertTrue(answer.contains("Main.java"))
        XCTAssertTrue(answer.lowercased().contains("```java"))
        XCTAssertTrue(answer.contains("EXAMPLE:"))
        let code = AnswerBlock.parse(answer).filter(\.isCode).map(\.text).joined(separator: "\n")
        XCTAssertTrue(code.contains("charAt") || code.contains("toCharArray"))
        XCTAssertTrue(code.contains("//") || code.contains("/*"), answer)
        print("Live screenshot-based IDE navigation and Java coding guidance passed")
    }
    private func suppliedKey() throws -> String {
        guard let key = ProcessInfo.processInfo.environment["MEETING_ASSIST_LIVE_TEST_KEY"],
            !key.isEmpty
        else { throw XCTSkip("Live API tests require an explicitly supplied test credential.") }
        return key
    }
    @MainActor
    private func feedSpeech(_ path: String, to client: LiveTranscriber) async throws {
        let file = try AVAudioFile(
            forReading: URL(fileURLWithPath: path), commonFormat: .pcmFormatInt16, interleaved: true)
        XCTAssertEqual(file.processingFormat.sampleRate, 24000)
        XCTAssertEqual(file.processingFormat.channelCount, 1)
        let buffer = try XCTUnwrap(
            AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
        try file.read(into: buffer)
        let values = try XCTUnwrap(buffer.int16ChannelData?[0])
        for offset in stride(from: 0, to: Int(buffer.frameLength), by: 960) {
            let count = min(960, Int(buffer.frameLength) - offset)
            var sum = 0.0
            for index in offset..<(offset + count) {
                let value = Double(values[index]) / 32768
                sum += value * value
            }
            let seconds = Double(count) / 24000
            client.audio(
                Data(bytes: values + offset, count: count * 2), rms: sqrt(sum / Double(count)),
                seconds: seconds)
            try await Task.sleep(for: .seconds(seconds))
        }
    }
    @MainActor
    func testLiveSpokenFollowUpAfterThreeSecondPauseGetsItsOwnAnswer() async throws {
        let key = try suppliedKey()
        guard let firstPath = ProcessInfo.processInfo.environment["MEETING_ASSIST_LIVE_AUDIO_PATH"],
            let followPath = ProcessInfo.processInfo.environment["MEETING_ASSIST_FOLLOWUP_AUDIO_PATH"]
        else { throw XCTSkip("Follow-up check requires two mono PCM16 24 kHz question WAVs.") }
        let client = LiveTranscriber()
        try await client.connect(
            key: key, model: "gpt-live-transcribe", realtimeAnswerModel: "gpt-realtime-2.1-mini",
            background: Profile.context)
        let model = MeetingModel(credentials: CredentialAccess { key }, meetingClient: client)
        model.hasKey = true
        model.listening = true
        defer { model.stop() }
        let finished = expectation(description: "both spoken questions answered")
        var recorded = false
        let observer = model.$cards.sink { cards in
            guard cards.count == 2, cards.allSatisfy({ $0.finished || $0.interrupted }), !recorded else {
                return
            }
            recorded = true
            finished.fulfill()
        }
        // Audio goes directly to the connection, never through the Mac speakers or active meeting.
        try await feedSpeech(firstPath, to: client)
        for _ in 0..<75 {
            client.audio(Data(repeating: 0, count: 1920), rms: 0, seconds: 0.04)
            try await Task.sleep(for: .milliseconds(40))
        }
        try await feedSpeech(followPath, to: client)
        for _ in 0..<12 {
            client.audio(Data(repeating: 0, count: 1920), rms: 0, seconds: 0.04)
            try await Task.sleep(for: .milliseconds(40))
        }
        await fulfillment(of: [finished], timeout: 30)
        observer.cancel()
        XCTAssertEqual(model.cards.count, 2)
        XCTAssertTrue(
            model.cards.allSatisfy { $0.finished && !$0.interrupted && $0.answer.contains("EXAMPLE:") })
        XCTAssertTrue(model.cards.last?.question.lowercased().contains("dependency") == true)
        XCTAssertTrue(model.cards.first?.question.lowercased().contains("example") == true)
        XCTAssertTrue(model.cards.first?.answer.lowercased().contains("```java") == true)
        let followUpAnswer = model.cards.first?.answer.lowercased() ?? ""
        XCTAssertTrue(
            followUpAnswer.contains("inject") || followUpAnswer.contains("dependenc"),
            "The follow-up example must stay on the dependency-injection topic")
        print(
            "Live spoken follow-up after a three-second pause returned its own Java dependency-injection example"
        )
    }
    @MainActor
    func testLiveBriefAnswerIncludesExample() async throws {
        let key = try suppliedKey()
        var answer = ""
        var firstToken: Double?
        let start = Date()
        try await AnswerService.stream(
            key: key, model: "gpt-6-luna",
            question: "Explain dependency injection in Spring Boot with a tiny example.",
            context: "", background: Profile.context, expanded: false
        ) { delta in
            if firstToken == nil { firstToken = Date().timeIntervalSince(start) }
            answer += delta
        }
        XCTAssertTrue(answer.contains("EXAMPLE:"))
        XCTAssertFalse(answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        if let firstToken { print(String(format: "Live answer first text: %.2f seconds", firstToken)) }
    }
    @MainActor
    func testLiveResumeAnalysisAndExperienceAnswersStayGrounded() async throws {
        let key = try suppliedKey()
        let source = """
            Technical background: Java, Spring Boot, PostgreSQL, Kafka.
            Current project: Payments service. Built Spring Boot APIs backed by PostgreSQL.
            Previous project: Notifications. Implemented Kafka consumers for notification delivery.
            """
        let analysis = try await ResumeService.analyze(key: key, model: "gpt-6-luna", text: source)
        XCTAssertTrue(analysis.skills.contains(where: { $0.lowercased() == "java" }))
        XCTAssertFalse(analysis.projects.isEmpty)
        XCTAssertTrue(analysis.incidents.isEmpty, "Responsibilities must not become personal incidents")
        var hypothetical = ""
        try await AnswerService.stream(
            key: key, model: "gpt-6-luna",
            question: "Share a real production bottleneck you faced on the current project.",
            context: "", background: analysis.context(currentProject: "Payments service", notes: ""),
            expanded: false
        ) { hypothetical += $0 }
        XCTAssertTrue(
            hypothetical.replacingOccurrences(of: "**", with: "").contains("Hypothetical scenario:"),
            hypothetical)
        XCTAssertTrue(hypothetical.contains("EXAMPLE:"), hypothetical)
        var grounded = ""
        let notes =
            "Payments service: I investigated Kafka lag. EXPLAIN showed a slow unindexed lookup. I added the missing database index and validated the lookup plan and replayed test events; the backlog cleared. No measured percentages are available."
        try await AnswerService.stream(
            key: key, model: "gpt-6-luna",
            question: "Share the actual Kafka lag issue you faced on the Payments project.",
            context: "", background: analysis.context(currentProject: "Payments service", notes: notes),
            expanded: false
        ) { grounded += $0 }
        XCTAssertTrue(grounded.lowercased().contains("index"))
        XCTAssertFalse(grounded.contains("Hypothetical scenario:"))
        XCTAssertFalse(grounded.contains("%"))
        XCTAssertTrue(grounded.contains("EXAMPLE:"))
        print("Live resume analysis and fact/hypothetical experience answer checks passed")
    }
    @MainActor
    func testLiveCodingAnswersContainSolutionsAndExamples() async throws {
        let key = try suppliedKey()
        for (language, question, expected) in [
            ("java", "Please write a Java function to reverse a string. Show hello as the input.", "olleh"),
            (
                "sql",
                "Write a SQL query for the second highest distinct salary in employees. Example salaries: 100, 200, 200, 300.",
                "200"
            ),
        ] {
            var answer = ""
            try await AnswerService.stream(
                key: key, model: "gpt-6-luna", question: question, context: "", background: Profile.context,
                expanded: false
            ) { answer += $0 }
            XCTAssertTrue(answer.contains("SAY THIS:"))
            XCTAssertTrue(answer.contains("EXAMPLE:"))
            XCTAssertTrue(answer.lowercased().contains("```" + language))
            XCTAssertTrue(answer.contains(expected))
            let code = AnswerBlock.parse(answer).filter(\.isCode).map(\.text).joined(separator: "\n")
            XCTAssertFalse(code.isEmpty)
            if language == "java" { XCTAssertTrue(code.contains("String")) }
            if language == "sql" { XCTAssertTrue(code.uppercased().contains("SELECT")) }
            print("Live coding solution and example passed for \(language)")
        }
    }
    @MainActor
    func testLiveSpokenCodingRequestAutomaticallyReturnsCode() async throws {
        let key = try suppliedKey()
        guard let path = ProcessInfo.processInfo.environment["MEETING_ASSIST_CODING_AUDIO_PATH"] else {
            throw XCTSkip("Spoken coding check requires a mono PCM16 24 kHz coding request WAV.")
        }
        let file = try AVAudioFile(
            forReading: URL(fileURLWithPath: path), commonFormat: .pcmFormatInt16, interleaved: true)
        XCTAssertEqual(file.processingFormat.sampleRate, 24000)
        XCTAssertEqual(file.processingFormat.channelCount, 1)
        let buffer = try XCTUnwrap(
            AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
        try file.read(into: buffer)
        let values = try XCTUnwrap(buffer.int16ChannelData?[0])
        let client = LiveTranscriber()
        try await client.connect(
            key: key, model: "gpt-live-transcribe", realtimeAnswerModel: "gpt-realtime-2.1-mini",
            background: Profile.context)
        let model = MeetingModel(credentials: CredentialAccess { key }, meetingClient: client)
        model.hasKey = true
        model.listening = true
        model.autoAnswer = true
        defer { model.stop() }
        let finished = expectation(description: "spoken coding task answered automatically")
        var recorded = false
        var answer = ""
        var question = ""
        let observer = model.$cards.sink { cards in
            guard let card = cards.first, card.finished || card.interrupted, !recorded else { return }
            recorded = true
            XCTAssertFalse(card.interrupted)
            answer = card.answer
            question = card.question
            finished.fulfill()
        }
        // Inject sample audio into the live connection without playing it into the user's meeting.
        for offset in stride(from: 0, to: Int(buffer.frameLength), by: 960) {
            let count = min(960, Int(buffer.frameLength) - offset)
            var sum = 0.0
            for index in offset..<(offset + count) {
                let value = Double(values[index]) / 32768
                sum += value * value
            }
            let seconds = Double(count) / 24000
            client.audio(
                Data(bytes: values + offset, count: count * 2), rms: sqrt(sum / Double(count)),
                seconds: seconds)
            try await Task.sleep(for: .seconds(seconds))
        }
        for _ in 0..<12 {
            client.audio(Data(repeating: 0, count: 1920), rms: 0, seconds: 0.04)
            try await Task.sleep(for: .milliseconds(40))
        }
        await fulfillment(of: [finished], timeout: 30)
        withExtendedLifetime(observer) {}
        XCTAssertTrue(question.lowercased().contains("reverse"))
        XCTAssertTrue(answer.contains("EXAMPLE:"))
        XCTAssertTrue(answer.lowercased().contains("```java"))
        XCTAssertTrue(AnswerBlock.parse(answer).contains(where: \.isCode))
        XCTAssertTrue(answer.contains("olleh"))
        print("Live spoken coding task automatically returned Java code and input/output example")
    }
    @MainActor
    func testLiveQuestionEndToUsefulAnswerLatency() async throws {
        let key = try suppliedKey()
        guard let path = ProcessInfo.processInfo.environment["MEETING_ASSIST_LIVE_AUDIO_PATH"] else {
            throw XCTSkip("Latency benchmark requires a mono PCM16 24 kHz question WAV.")
        }
        let file = try AVAudioFile(
            forReading: URL(fileURLWithPath: path), commonFormat: .pcmFormatInt16, interleaved: true)
        XCTAssertEqual(file.processingFormat.sampleRate, 24000)
        XCTAssertEqual(file.processingFormat.channelCount, 1)
        let buffer = try XCTUnwrap(
            AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
        try file.read(into: buffer)
        let values = try XCTUnwrap(buffer.int16ChannelData?[0])
        var frames: [(Data, Double, Double)] = []
        for offset in stride(from: 0, to: Int(buffer.frameLength), by: 960) {
            let count = min(960, Int(buffer.frameLength) - offset)
            var sum = 0.0
            for index in offset..<(offset + count) {
                let value = Double(values[index]) / 32768
                sum += value * value
            }
            frames.append(
                (
                    Data(bytes: values + offset, count: count * 2), sqrt(sum / Double(count)),
                    Double(count) / 24000
                ))
        }
        let client = LiveTranscriber()
        defer { client.stop() }
        let direct = ProcessInfo.processInfo.environment["MEETING_ASSIST_DIRECT_AUDIO"] == "1"
        try await client.connect(
            key: key, model: "gpt-live-transcribe",
            realtimeAnswerModel: direct ? "gpt-realtime-2.1-mini" : nil, background: Profile.context)
        let trials = min(
            5, max(1, Int(ProcessInfo.processInfo.environment["MEETING_ASSIST_LATENCY_TRIALS"] ?? "3") ?? 3))
        for trial in 1...trials {
            let finished = expectation(description: "paced speech transcribed and answered")
            var handled = false
            var answer = ""
            var measured: AnswerTiming?
            var answerTask: Task<Void, Never>?
            let model =
                direct ? MeetingModel(credentials: CredentialAccess { key }, meetingClient: client) : nil
            model?.hasKey = true
            model?.listening = true
            model?.autoAnswer = true
            var recorded = false
            let observer = model?.$cards.sink { cards in
                guard let card = cards.first, card.finished || card.interrupted, !recorded else { return }
                recorded = true
                answer = card.answer
                measured = card.timing
                XCTAssertFalse(card.interrupted)
                finished.fulfill()
            }
            let modelHandler = client.onEvent
            client.onFailure = { message in XCTFail(message) }
            client.onEvent = { event in
                if direct { modelHandler?(event) }
                guard case .completed(let id, let question) = event, !handled else { return }
                handled = true
                XCTAssertTrue(question.lowercased().contains("dependency"))
                let endedAt = client.speechEndedAt(for: id)
                XCTAssertNotNil(endedAt)
                print(
                    String(
                        format: "Latency trial %d: transcript final %.2fs after speech", trial,
                        Date().timeIntervalSince(endedAt ?? Date())))
                if direct { return }
                answerTask = Task {
                    defer { finished.fulfill() }
                    var timing = AnswerTiming(requestStartedAt: Date(), questionEndedAt: endedAt)
                    do {
                        let record: (String) -> Void = { delta in
                            answer += delta
                            timing.observe(answer, at: Date())
                        }
                        try await AnswerService.stream(
                            key: key, model: "gpt-6-luna", question: question,
                            context: "", background: Profile.context, expanded: false, onDelta: record)
                        measured = timing
                    } catch { XCTFail(SecretRedactor.clean(error.localizedDescription, key: key)) }
                }
            }
            // Pace input at real playback speed, so the measurement includes endpoint detection.
            for (pcm, rms, seconds) in frames {
                client.audio(pcm, rms: rms, seconds: seconds)
                try await Task.sleep(for: .seconds(seconds))
            }
            for _ in 0..<12 {
                client.audio(Data(repeating: 0, count: 1920), rms: 0, seconds: 0.04)
                try await Task.sleep(for: .milliseconds(40))
            }
            await fulfillment(of: [finished], timeout: 30)
            answerTask?.cancel()
            withExtendedLifetime((model, observer)) {}
            XCTAssertTrue(answer.contains("EXAMPLE:"))
            let useful = try XCTUnwrap(measured?.firstUsefulSeconds, answer)
            print(
                String(
                    format:
                        "Latency trial %d: first useful answer %.2fs after speech (first token %.2fs after request)",
                    trial, useful, measured?.firstTextSeconds ?? -1))
        }
    }
    @MainActor
    func testLiveTranscriptionHandshake() async throws {
        let key = try suppliedKey()
        let client = LiveTranscriber()
        defer { client.stop() }
        try await client.connect(key: key, model: "gpt-live-transcribe")
        if let path = ProcessInfo.processInfo.environment["MEETING_ASSIST_LIVE_AUDIO_PATH"] {
            let file = try AVAudioFile(
                forReading: URL(fileURLWithPath: path), commonFormat: .pcmFormatInt16,
                interleaved: true)
            XCTAssertEqual(file.processingFormat.sampleRate, 24000)
            XCTAssertEqual(file.processingFormat.channelCount, 1)
            let buffer = try XCTUnwrap(
                AVAudioPCMBuffer(
                    pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
            try file.read(into: buffer)
            let values = try XCTUnwrap(buffer.int16ChannelData?[0])
            let completed = expectation(description: "synthetic question transcribed")
            var transcript = ""
            var completedOnce = false
            client.onEvent = { event in
                if case .completed(_, let text) = event, !completedOnce {
                    completedOnce = true
                    transcript = text
                    completed.fulfill()
                }
            }
            client.onFailure = { message in XCTFail(message) }
            for offset in stride(from: 0, to: Int(buffer.frameLength), by: 2400) {
                let count = min(2400, Int(buffer.frameLength) - offset)
                var sum = 0.0
                for index in offset..<(offset + count) {
                    let value = Double(values[index]) / 32768
                    sum += value * value
                }
                client.audio(
                    Data(bytes: values + offset, count: count * 2),
                    rms: sqrt(sum / Double(count)), seconds: Double(count) / 24000)
            }
            for _ in 0..<8 {
                client.audio(Data(repeating: 0, count: 4800), rms: 0, seconds: 0.1)
            }
            await fulfillment(of: [completed], timeout: 20)
            XCTAssertTrue(transcript.lowercased().contains("dependency"))
            XCTAssertTrue(transcript.lowercased().contains("spring"))
        }
    }
}
