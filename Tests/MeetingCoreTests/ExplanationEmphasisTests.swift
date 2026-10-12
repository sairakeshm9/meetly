import XCTest

@testable import MeetingCore

final class ExplanationEmphasisTests: XCTestCase {
    private func cues(_ text: String) -> [String] {
        ExplanationEmphasis.ranges(in: text).map { String(text[$0]) }
    }
    func testDefinitionAndBenefitAreHighlightedBeyondProductNames() {
        XCTAssertTrue(
            cues("Java is a programming language used to build applications.").contains(
                "programming language"))
        let found = cues("Spring Boot provides sensible defaults and reduces setup work for web services.")
        XCTAssertTrue(found.contains("provides sensible defaults"))
        XCTAssertTrue(found.contains("reduces setup work"))
    }
    func testAnnotationsAndTheirPurposeAreHighlightedWithoutFixedVocabulary() {
        let found = cues("@GetMapping handles HTTP GET requests for the selected URL.")
        XCTAssertTrue(found.contains("@GetMapping"))
        XCTAssertTrue(found.contains("handles HTTP GET requests"))
        XCTAssertTrue(
            cues("@InventedAnnotation prevents repeated work for this operation.").contains(
                "prevents repeated work"))
    }
    func testEverySectionInLongAnswerGetsCuesWithBoundedDensity() {
        let line = "- The service stores a durable checkpoint and prevents repeated work during recovery.\n"
        let text =
            "SAY THIS:\n" + String(repeating: line, count: 40)
            + "\nEXAMPLE:\nA worker retries failed delivery after a network interruption."
        let found = cues(text)
        XCTAssertEqual(found.filter { $0 == "stores a durable checkpoint" }.count, 40)
        XCTAssertEqual(found.filter { $0 == "prevents repeated work" }.count, 40, "\(found.prefix(8))")
        XCTAssertTrue(found.contains("retries failed delivery"))
        XCTAssertLessThan(found.joined(separator: " ").count, text.count)
    }
    func testModelCuesAreNotOverwrittenOrExpandedIntoWholeSentence() {
        let text = "The service provides a durable checkpoint and prevents repeated work during recovery."
        let preferred = text.range(of: "durable checkpoint")!
        let ranges = ExplanationEmphasis.ranges(in: text, preferred: [preferred])
        XCTAssertFalse(ranges.contains { $0.overlaps(preferred) })
        XCTAssertTrue(ranges.contains { String(text[$0]) == "prevents repeated work" })
        XCTAssertLessThanOrEqual(ranges.count, 2)
    }
    func testNegationStaysWithActionAndCuesDoNotEndOnDanglingArticles() {
        XCTAssertTrue(
            cues("This does not prevent repeated work in another worker.").contains(
                "not prevent repeated work"))
        XCTAssertTrue(
            cues("A worker retries failed delivery after a network interruption.").contains(
                "retries failed delivery"))
    }
    func testEmptyPlainAndUnicodeTextPreserveValidRanges() {
        XCTAssertTrue(cues("").isEmpty)
        XCTAssertTrue(cues("We can talk about this later.").isEmpty)
        XCTAssertTrue(
            cues("🚀 The worker prevents repeated charges for café orders.").contains(
                "prevents repeated charges"))
        let partial = "The worker handles HTTP"
        XCTAssertEqual(cues(partial).first, "handles HTTP")
        XCTAssertTrue(cues(partial + " GET requests.").contains("handles HTTP GET requests"))
    }
    func testCustomAndRefreshRequestsKeepExplanationGuidanceLast() throws {
        for simplified in [false, true] {
            let data = try APIRequest.answer(
                model: "test", question: "Explain Spring", context: "", background: "", template: .custom,
                customTemplate: "Only bullet points.", simplified: simplified)
            let body = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            let instructions = try XCTUnwrap(body["instructions"] as? String)
            XCTAssertTrue(instructions.hasSuffix(ExplanationEmphasis.guidance))
        }
    }
}
