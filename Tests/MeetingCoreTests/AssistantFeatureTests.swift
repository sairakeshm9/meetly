import XCTest

@testable import MeetingCore

final class AssistantFeatureTests: XCTestCase {
    func testResumePreservesProjectHistoryAfterFirst400CharactersWhileRedactingSecrets() throws {
        let source =
            String(repeating: "Technical background Java Spring Boot. ", count: 30)
            + "\nPrevious project: Claims service. Investigated a slow PostgreSQL query and added an index."
            + "\nContact: test@example.com. Token: sk-test-abcdefghijklmnop"
        let clean = try ResumeText.prepare(source)
        XCTAssertGreaterThan(clean.count, 400)
        XCTAssertTrue(clean.contains("Previous project: Claims service"))
        XCTAssertTrue(clean.contains("added an index"))
        XCTAssertFalse(clean.contains("test@example.com"))
        XCTAssertFalse(clean.contains("sk-test-"))
        XCTAssertEqual(SecretRedactor.clean(String(repeating: "x", count: 1000)).count, 400)
    }
    func testHistoryKeepsThreeDistinctRequestsAndBoundsEachQuestion() {
        var history = QuestionHistory()
        for i in 0..<8 { history.record(id: "\(i)", text: "question \(i)") }
        XCTAssertEqual(history.questions.map(\.id), ["5", "6", "7"])
        history.record(id: "7", text: "duplicate event")
        XCTAssertFalse(history.context.contains("duplicate"))
        history.record(id: "8", text: String(repeating: "x", count: 4000))
        XCTAssertEqual(history.questions.last?.text.count, 1000)
        XCTAssertLessThan(history.context.count, 3200)
    }
    func testKeywordRangesRespectWordsAndUnicode() {
        let text = "🚀 Java uses SQL and Spring Boot. JavaScript differs; Kafka matters."
        let found = KeywordEmphasis.ranges(in: text).map { String(text[$0]) }
        XCTAssertTrue(found.contains("Java"))
        XCTAssertTrue(found.contains("SQL"))
        XCTAssertTrue(found.contains("Spring Boot"))
        XCTAssertTrue(found.contains("Kafka"))
        XCTAssertEqual(found.filter { $0 == "Java" }.count, 1)
    }
    func testHighlightsMultipleConceptsAcrossSentencesAndBullets() {
        let text =
            "Use constructor injection with interfaces for unit tests.\n"
            + "• Prevent race conditions with optimistic locking and transactions.\n"
            + "• Check log ingestion and timing window before declaring false positives."
        XCTAssertEqual(
            KeywordEmphasis.ranges(in: text).map { String(text[$0]) },
            [
                "constructor injection", "interfaces", "unit tests", "race conditions",
                "optimistic locking", "transactions", "log ingestion", "timing window", "false positives",
            ])
    }
    func testLongestPhrasesCaseAndTechnicalPunctuation() {
        let text = "🚀 CONSTRUCTOR INJECTION: O(n log n), O(1), at-least-once; consumer groups."
        XCTAssertEqual(
            KeywordEmphasis.ranges(in: text).map { String(text[$0]) },
            [
                "CONSTRUCTOR INJECTION", "O(n log n)", "O(1)", "at-least-once", "consumer groups",
            ])
    }
    func testNoPartialWordsOrOrdinaryFillerAndStreamingPhraseCompletion() {
        for text in ["", "This helps us explain it clearly.", "JavaBeans restarts states SQLish éJava"] {
            XCTAssertTrue(KeywordEmphasis.ranges(in: text).isEmpty, text)
        }
        XCTAssertEqual(
            KeywordEmphasis.ranges(in: "Use constructor inj").map { String("Use constructor inj"[$0]) },
            ["constructor"])
        let complete = "Use constructor injection"
        XCTAssertEqual(
            KeywordEmphasis.ranges(in: complete).map { String(complete[$0]) }, ["constructor injection"])
    }
    func testUnclearQuestionReportsReasonAndOnlyContextualWhyIsAllowed() {
        XCTAssertNotNil(QuestionClarity.issue("[inaudible]", hasContext: true))
        XCTAssertNotNil(QuestionClarity.issue("Can you", hasContext: true))
        XCTAssertNotNil(QuestionClarity.issue("Why?", hasContext: false))
        XCTAssertNil(QuestionClarity.issue("Why?", hasContext: true))
        XCTAssertNil(QuestionClarity.issue("How do you prevent race conditions?", hasContext: false))
        let answer = "ISSUE: Missing target language.\nQUESTION: Should I use Java? (Y/N)"
        XCTAssertEqual(QuestionClarity.modelIssue(answer), "Missing target language.")
        XCTAssertEqual(QuestionClarity.clarification(answer), "Should I use Java? (Y/N)")
        XCTAssertNil(QuestionClarity.modelIssue("SAY THIS: Use Java. EXAMPLE: A class."))
        XCTAssertEqual(QuestionClarity.modelIssue("**ISSUE:** Input missing."), "Input missing.")
        XCTAssertEqual(
            QuestionClarity.clarification("**ISSUE:** Input missing.\n**QUESTION:** Should I use JSON?"),
            "Should I use JSON? (Y/N)")
        XCTAssertNil(
            QuestionClarity.clarification("ISSUE: Input missing.\nQUESTION: What is the input format?"))
    }
    func testVisionRequestIncludesImageTaskAndModeWithNoStoredResponse() throws {
        let bytes = Data([1, 2, 3])
        let data = try APIRequest.answer(
            model: "gpt-6-luna", question: "What should I write next?", context: "last three",
            background: "Java", mode: .advancedCoding, codingTask: "Reverse a string", screenImage: bytes)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(body["store"] as? Bool, false)
        XCTAssertEqual(body["max_output_tokens"] as? Int, 4000)
        let instructions = try XCTUnwrap(body["instructions"] as? String)
        XCTAssertTrue(instructions.contains("next navigation step"))
        XCTAssertTrue(instructions.contains("Y/N"))
        XCTAssertTrue(instructions.contains("Bold key technical terms"))
        let input = try XCTUnwrap(body["input"] as? [[String: Any]])
        let content = try XCTUnwrap(input.first?["content"] as? [[String: Any]])
        XCTAssertTrue((content[0]["text"] as? String)?.contains("Reverse a string") == true)
        XCTAssertEqual(
            content[1]["image_url"] as? String, "data:image/jpeg;base64," + bytes.base64EncodedString())
        XCTAssertEqual(content[1]["detail"] as? String, "high")
    }
}
