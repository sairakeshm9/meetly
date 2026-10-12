import XCTest

@testable import MeetingCore

final class MeetingCoreTests: XCTestCase {
    func testByteParserPreservesBlankLinesCRLFAndSplitUnicode() throws {
        var parser = SSEByteParser()
        var events: [String] = []
        for byte in "data: café\r\n\r\ndata: next\n\n".utf8 {
            if let event = try parser.feed(byte) { events.append(event) }
        }
        XCTAssertEqual(events, ["café", "next"])
    }
    func testDetectsTechnicalQuestionsAndRequests() {
        for text in [
            "How does Spring dependency injection work?", "Explain Kafka consumer groups",
            "Could you compare REST and SOAP", "Okay, can you explain JWT validation",
            "What about retries",
        ] {
            XCTAssertTrue(QuestionDetector.isCandidate(text), text)
        }
    }
    func testIgnoresEmptyAndStatements() {
        for text in [
            "", " ", "Hi", "I deployed the service yesterday.", String(repeating: "x", count: 4001),
        ] {
            XCTAssertFalse(QuestionDetector.isCandidate(text), text.prefix(40).description)
        }
    }
    func testNormalizationDeduplicatesCaseAndPunctuation() {
        XCTAssertEqual(
            QuestionDetector.normalized("How does JWT work?"),
            QuestionDetector.normalized("HOW does JWT work."))
    }
    func testBriefFollowUpsUseRecentQuestionButAcknowledgementsDoNot() {
        for text in [
            "And in Java", "An example", "Without built-ins", "With multiple threads", "Time complexity",
            "More details", "Same for SQL", "And what about retries",
        ] {
            XCTAssertTrue(QuestionDetector.isCandidate(text, hasRecentQuestion: true), text)
        }
        for text in [
            "Thanks", "Okay, that helps", "I used Java yesterday", "We did that without annotations", "",
            "Hi",
        ] {
            XCTAssertFalse(QuestionDetector.isCandidate(text, hasRecentQuestion: true), text)
        }
        XCTAssertFalse(QuestionDetector.isCandidate("An example"))
        XCTAssertFalse(QuestionDetector.isCandidate("And in Java"))
        XCTAssertTrue(QuestionDetector.isCandidate("Why?"))
    }
    func testCodingFollowUpRetainsEnoughBudgetForThePreviousCode() throws {
        let data = try APIRequest.answer(
            model: "gpt-6-luna", question: "Without built-ins",
            context: "Previous answer: ```java\nstatic String reverse(String s) {}\n```", background: "")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(body["max_output_tokens"] as? Int, 900)
    }
    func testTranscriptReconcilesCorrectionsAndPreservesCommitOrder() {
        var store = TranscriptStore()
        store.update(id: "a", speaker: "Meeting", text: "", final: false, delta: false)
        store.update(id: "b", speaker: "Meeting", text: "Second", final: true, delta: false)
        store.update(id: "a", speaker: "Meeting", text: "What is cash", final: false, delta: true)
        store.update(id: "a", speaker: "Meeting", text: "What is caching?", final: true, delta: false)
        store.update(id: "a", speaker: "Meeting", text: "stale delta", final: false, delta: true)
        XCTAssertEqual(store.turns.map(\.text), ["What is caching?", "Second"])
        XCTAssertEqual(store.context, "Meeting: What is caching?\nMeeting: Second")
    }
    func testSeparateSpeakerIDsDoNotCollide() {
        var store = TranscriptStore()
        store.update(id: "a", speaker: "You", text: "My response", final: true, delta: false)
        store.update(id: "a", speaker: "Meeting", text: "Their question?", final: true, delta: false)
        XCTAssertEqual(store.turns.count, 2)
        XCTAssertEqual(store.latestMeetingText, "Their question?")
    }
    func testTranscriptMemoryBoundAndPositionRebuild() {
        var store = TranscriptStore()
        for i in 0..<100 {
            store.update(id: "\(i)", speaker: "Meeting", text: "\(i)", final: false, delta: false)
        }
        store.update(id: "99", speaker: "Meeting", text: "final", final: true, delta: false)
        XCTAssertEqual(store.turns.count, 80)
        XCTAssertEqual(store.turns.last?.text, "final")
    }
    func testCodingRequestsIncludingObservedWriteHomophoneAreQuestions() {
        for request in [
            "Write Java code to reverse a string", "Right, Java code to reverse a string",
            "Implement a Kafka consumer", "Show me a SQL query for duplicate emails",
            "Python program to reverse a string",
        ] {
            XCTAssertTrue(QuestionDetector.isCandidate(request), request)
        }
        XCTAssertFalse(QuestionDetector.isCandidate("Right, we deployed the Java code yesterday."))
    }
    func testNaturalCodingRequestsDoNotRequireQuestionPunctuation() {
        for request in [
            "Please write a Java program to reverse a string",
            "Okay, so please create a function to check a palindrome",
            "I need you to implement binary search in Python",
            "For this exercise, can you write a SQL query for the second highest salary",
            "Right a program to find duplicates in an array",
            "C# code to reverse a string", "Go function that removes duplicates",
            "Given an array of integers, return the two indices whose values sum to the target",
            "Reverse a string without using built-in functions",
            "Find the second highest salary from the employee table",
            "Please, debug this function", "Generate a query for duplicate emails",
        ] {
            XCTAssertTrue(QuestionDetector.isCandidate(request), request)
        }
        for statement in [
            "Okay, I wrote a Java program yesterday.", "The function returns a reversed string.",
            "Please wait while I share my screen.", "We need to deploy the code today.",
            "Java code is used in this service.", "Given our schedule, the release is tomorrow.",
        ] {
            XCTAssertFalse(QuestionDetector.isCandidate(statement), statement)
        }
    }
    func testCodingBudgetAndSolutionContractApplyToBothAnswerPaths() throws {
        let data = try APIRequest.answer(
            model: "gpt-6-luna", question: "Please write a Java program to reverse a string",
            context: "", background: "")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(body["max_output_tokens"] as? Int, 900)
        let config = APIRequest.realtimeAnswerConfig(
            transcriptionModel: "gpt-live-transcribe", model: "gpt-realtime-2.1-mini", background: "")
        let session = try XCTUnwrap(config["session"] as? [String: Any])
        XCTAssertEqual(session["max_output_tokens"] as? Int, 900)
        for instructions in [body["instructions"] as? String, session["instructions"] as? String] {
            XCTAssertTrue(instructions?.contains("actual solution in a fenced code block") ?? false)
            XCTAssertTrue(instructions?.contains("sample input and expected output") ?? false)
        }
    }
    func testAnswerBlocksPreserveCodeIndentationDuringStreaming() {
        XCTAssertEqual(AnswerBlock.parse(""), [])
        XCTAssertEqual(
            AnswerBlock.parse("SAY THIS: Use a loop."),
            [
                AnswerBlock(text: "SAY THIS: Use a loop.", isCode: false)
            ])
        let partial = "SAY THIS: Use a loop.\n\nEXAMPLE:\n```java\nstatic void run() {\n    return;\n}"
        let blocks = AnswerBlock.parse(partial)
        XCTAssertEqual(blocks.count, 2)
        XCTAssertEqual(blocks[1], AnswerBlock(text: "static void run() {\n    return;\n}", isCode: true))
        let complete = AnswerBlock.parse(partial + "\n```\nInput: hello → Output: olleh")
        XCTAssertEqual(complete.count, 3)
        XCTAssertFalse(complete[2].isCode)
        XCTAssertEqual(complete[1], blocks[1])
        XCTAssertEqual(AnswerBlock.parse("```python\n```"), [])
    }
    func testRecentContextExcludesPartialAndBoundsLength() {
        var store = TranscriptStore()
        store.update(id: "partial", speaker: "Meeting", text: "incomplete", final: false, delta: true)
        XCTAssertEqual(store.context, "")
        for i in 0..<20 {
            store.update(
                id: "\(i)", speaker: "Meeting", text: String(repeating: "A", count: 1000), final: true,
                delta: false)
        }
        XCTAssertLessThanOrEqual(store.context.count, 6000)
    }
    private let audio = Data(repeating: 0, count: 4800)
    func testSilenceDoesNotUploadOrCommit() {
        var gate = SpeechGate()
        for _ in 0..<100 {
            let result = gate.process(audio, rms: 0, seconds: 0.1)
            XCTAssertTrue(result.audio.isEmpty)
            XCTAssertFalse(result.commit)
        }
    }
    func testSpeechUploadsPreRollAndCommitsExactlyOnce() {
        var gate = SpeechGate()
        _ = gate.process(audio, rms: 0, seconds: 0.1)
        _ = gate.process(audio, rms: 0, seconds: 0.1)
        let start = gate.process(audio, rms: 0.08, seconds: 0.1)
        XCTAssertEqual(start.audio.count, 3)
        for _ in 0..<3 { XCTAssertFalse(gate.process(audio, rms: 0, seconds: 0.1).commit) }
        XCTAssertTrue(gate.process(audio, rms: 0, seconds: 0.2).commit)
        XCTAssertFalse(gate.process(audio, rms: 0, seconds: 1).commit)
    }
    func testFastGateKeepsShortPauseInsideQuestionButCommitsBy400ms() {
        var gate = SpeechGate()
        _ = gate.process(audio, rms: 0.08, seconds: 0.2)
        XCTAssertFalse(gate.process(audio, rms: 0, seconds: 0.3).commit)
        XCTAssertFalse(gate.process(audio, rms: 0.08, seconds: 0.2).commit)
        XCTAssertFalse(gate.process(audio, rms: 0, seconds: 0.3).commit)
        XCTAssertTrue(gate.process(audio, rms: 0, seconds: 0.1).commit)
    }
    func testTimingAcceptsBoldSectionLabelsButStillRequiresUsefulWords() {
        let start = Date()
        var timing = AnswerTiming(requestStartedAt: start)
        timing.observe("**SAY THIS:**", at: start.addingTimeInterval(0.1))
        XCTAssertNil(timing.firstUsefulSeconds)
        timing.observe("**SAY THIS:** Use **constructor injection**.", at: start.addingTimeInterval(0.8))
        XCTAssertEqual(timing.firstUsefulSeconds ?? -1, 0.8, accuracy: 0.001)
    }
    func testTimingIncludesSpeechDetectionAndTranscriptionButExcludesHeading() {
        let ended = Date(timeIntervalSince1970: 100)
        var timing = AnswerTiming(requestStartedAt: ended.addingTimeInterval(0.5), questionEndedAt: ended)
        timing.observe("SAY", at: ended.addingTimeInterval(0.8))
        XCTAssertEqual(timing.firstTextSeconds!, 0.3, accuracy: 0.001)
        timing.observe("SAY THIS:", at: ended.addingTimeInterval(0.9))
        timing.observe("SAY THIS: Dependency injection", at: ended.addingTimeInterval(1))
        XCTAssertNil(timing.firstUsefulSeconds)
        timing.observe("SAY THIS: Dependency injection lets", at: ended.addingTimeInterval(1.2))
        XCTAssertEqual(timing.firstUsefulSeconds!, 1.2, accuracy: 0.001)
        timing.observe("SAY THIS: Dependency injection lets Spring", at: ended.addingTimeInterval(1.4))
        XCTAssertEqual(timing.firstUsefulSeconds!, 1.2, accuracy: 0.001)
        var manual = AnswerTiming(requestStartedAt: ended)
        manual.observe("  ", at: ended)
        XCTAssertNil(manual.firstTextSeconds)
        manual.observe("SAY THIS: Use constructor injection.", at: ended.addingTimeInterval(1))
        XCTAssertEqual(manual.firstUsefulSeconds, 1)
        XCTAssertNil(manual.questionEndedAt)
    }
    func testShortNoiseBurstClearsInsteadOfCommitting() {
        var gate = SpeechGate()
        _ = gate.process(audio, rms: 0.08, seconds: 0.01)
        let result = gate.process(audio, rms: 0, seconds: 0.7)
        XCTAssertTrue(result.clear)
        XCTAssertFalse(result.commit)
    }
    func testLongSpeechHasBoundedTurns() {
        var gate = SpeechGate()
        for _ in 0..<19 { XCTAssertFalse(gate.process(audio, rms: 0.1, seconds: 1).commit) }
        XCTAssertTrue(gate.process(audio, rms: 0.1, seconds: 1).commit)
    }
    func testInvalidFramesAreIgnored() {
        var gate = SpeechGate()
        XCTAssertTrue(gate.process(Data(), rms: 0.1, seconds: 1).audio.isEmpty)
        XCTAssertTrue(gate.process(audio, rms: .nan, seconds: 1).audio.isEmpty)
        XCTAssertTrue(gate.process(audio, rms: 0.1, seconds: -1).audio.isEmpty)
    }
    func testSSEHandlesMultilineDataAndComments() {
        var parser = SSEParser()
        XCTAssertNil(parser.feed(": heartbeat"))
        XCTAssertNil(parser.feed("event: response.output_text.delta"))
        XCTAssertNil(parser.feed("data: first"))
        XCTAssertNil(parser.feed("data:second"))
        XCTAssertEqual(parser.feed(""), "first\nsecond")
        XCTAssertNil(parser.feed(""))
    }
    func testRealtimeEventContracts() throws {
        func parse(_ object: [String: Any]) throws -> RealtimeEvent {
            try RealtimeEvent.parse(JSONSerialization.data(withJSONObject: object))
        }
        XCTAssertEqual(try parse(["type": "session.updated"]), .ready)
        XCTAssertEqual(
            try parse(["type": "input_audio_buffer.committed", "item_id": "a"]), .committed(id: "a"))
        XCTAssertEqual(
            try parse([
                "type": "conversation.item.input_audio_transcription.delta", "item_id": "a", "delta": "How",
            ]), .delta(id: "a", text: "How"))
        XCTAssertEqual(
            try parse([
                "type": "conversation.item.input_audio_transcription.completed", "item_id": "a",
                "transcript": "How?",
            ]), .completed(id: "a", text: "How?"))
        XCTAssertEqual(
            try parse(["type": "conversation.item.input_audio_transcription.delta"]), .ignored)
        XCTAssertEqual(try parse(["type": "error", "error": ["message": "quota"]]), .failure("quota"))
        XCTAssertThrowsError(try RealtimeEvent.parse(Data("bad".utf8)))
    }
    func testTranscriptionConfigUsesClientVADAndDomainHints() throws {
        let body = APIRequest.transcriptionConfig(model: "gpt-live-transcribe")
        let session = try XCTUnwrap(body["session"] as? [String: Any])
        let audio = try XCTUnwrap(session["audio"] as? [String: Any])
        let input = try XCTUnwrap(audio["input"] as? [String: Any])
        XCTAssertTrue(input["turn_detection"] is NSNull)
        let transcription = try XCTUnwrap(input["transcription"] as? [String: Any])
        XCTAssertEqual(transcription["languages"] as? [String], ["en"])
        XCTAssertEqual(transcription["delay"] as? String, "minimal")
        XCTAssertNil(transcription["language"])
        XCTAssertTrue((transcription["keywords"] as? [String] ?? []).contains("Kafka"))
        XCTAssertNoThrow(try JSONSerialization.data(withJSONObject: body))
    }
    func testFastSessionUsesTextOnlyMinimalReasoningAndBoundedBackground() throws {
        let config = APIRequest.realtimeAnswerConfig(
            transcriptionModel: "gpt-live-transcribe", model: "gpt-realtime-2.1-mini",
            background: String(repeating: "A", count: 12000))
        let session = try XCTUnwrap(config["session"] as? [String: Any])
        XCTAssertEqual(session["type"] as? String, "realtime")
        XCTAssertEqual(session["model"] as? String, "gpt-realtime-2.1-mini")
        XCTAssertEqual(session["output_modalities"] as? [String], ["text"])
        XCTAssertEqual((session["reasoning"] as? [String: String])?["effort"], "minimal")
        let instructions = try XCTUnwrap(session["instructions"] as? String)
        XCTAssertTrue(instructions.contains("EXAMPLE:"))
        XCTAssertTrue(instructions.hasSuffix(String(repeating: "A", count: 10000)))
        XCTAssertFalse(instructions.contains(String(repeating: "A", count: 10001)))
        XCTAssertNoThrow(try JSONSerialization.data(withJSONObject: config))
    }
    func testFallbackConfigDoesNotSendUnsupportedLiveHints() throws {
        let body = APIRequest.transcriptionConfig(model: "gpt-4o-mini-transcribe")
        let session = body["session"] as! [String: Any]
        let input = (session["audio"] as! [String: Any])["input"] as! [String: Any]
        let transcription = input["transcription"] as! [String: Any]
        XCTAssertEqual(transcription["language"] as? String, "en")
        XCTAssertNil(transcription["delay"])
        XCTAssertNil(transcription["languages"])
    }
    func testAnswerRequestIsShortStreamedAndDoesNotStore() throws {
        let data = try APIRequest.answer(
            model: "gpt-6-luna", question: "How does JPA work?", context: "previous", background: "Java")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(body["stream"] as? Bool, true)
        XCTAssertEqual(body["store"] as? Bool, false)
        XCTAssertEqual(body["max_output_tokens"] as? Int, 350)
        XCTAssertEqual((body["reasoning"] as? [String: String])?["effort"], "none")
        let instructions = try XCTUnwrap(body["instructions"] as? String)
        XCTAssertTrue(instructions.contains("Never invent"))
        XCTAssertTrue(instructions.contains("untrusted data"))
    }
    func testMissingQuestionAndModelProduceActionableErrors() {
        XCTAssertThrowsError(
            try APIRequest.answer(model: "gpt-6-luna", question: "  ", context: "", background: ""))
        XCTAssertThrowsError(
            try APIRequest.answer(model: "", question: "How?", context: "", background: ""))
    }
    func testSecretsCannotAppearInProviderErrors() {
        let key = "sk-test-abcdefghijklmnop"
        XCTAssertFalse(APIRequest.error(status: 401, key: key, body: Data(key.utf8)).contains(key))
        XCTAssertEqual(SecretRedactor.clean("invalid \(key)", key: key), "invalid [redacted]")
        XCTAssertEqual(SecretRedactor.clean("invalid \(key)"), "invalid [redacted]")
        XCTAssertTrue(APIRequest.error(status: 429, key: key, body: Data()).contains("billing"))
        XCTAssertTrue(APIRequest.error(status: 404, key: key, body: Data()).contains("model"))
    }
}
