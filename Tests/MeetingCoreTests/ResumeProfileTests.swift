import XCTest

@testable import MeetingCore

final class ResumeProfileTests: XCTestCase {
    private let resume =
        "Java engineer, 2021-2024. Built a Spring Boot payments service. Investigated Kafka consumer lag and fixed a slow database query."
    func testContactScrubbingPreservesDatesAndTechnicalFacts() throws {
        let text = try ResumeText.prepare(
            resume + "\nEmail: example@example.test\nPhone: +1 (555) 123-4567\nhttps://example.test/profile")
        XCTAssertFalse(text.contains("example@example"))
        XCTAssertFalse(text.contains("555"))
        XCTAssertFalse(text.contains("https://"))
        XCTAssertTrue(text.contains("2021-2024"))
        XCTAssertTrue(text.contains("slow database query"))
    }
    func testEmptyOrOversizedTextFailsUsefully() {
        for source in ["", "  ", "Just a name", String(repeating: "x", count: 120001)] {
            XCTAssertThrowsError(try ResumeText.prepare(source))
        }
    }
    func testAnalysisUsesStrictSchemaAndUntrustedDataBoundary() throws {
        let data = try ResumeRequest.body(model: "gpt-6-luna", text: resume)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(body["store"] as? Bool, false)
        let text = try XCTUnwrap(body["text"] as? [String: Any])
        let format = try XCTUnwrap(text["format"] as? [String: Any])
        XCTAssertEqual(format["type"] as? String, "json_schema")
        XCTAssertEqual(format["strict"] as? Bool, true)
        let schema = try XCTUnwrap(format["schema"] as? [String: Any])
        XCTAssertEqual(schema["additionalProperties"] as? Bool, false)
        XCTAssertTrue((body["instructions"] as? String)?.contains("untrusted data") ?? false)
        XCTAssertTrue((body["instructions"] as? String)?.contains("empty incidents array") ?? false)
        XCTAssertThrowsError(try ResumeRequest.body(model: "", text: resume))
    }
    func testUnsupportedEvidenceAndSkillsAreDropped() {
        let analysis = ResumeAnalysis(
            skills: ["Java", "Quantum networking", " "],
            projects: [
                .init(
                    name: "Payments", summary: "Spring service",
                    evidence: "Built a Spring Boot payments service."),
                .init(name: "Invented", summary: "Not in resume", evidence: "Reduced latency by 99 percent."),
            ],
            incidents: [
                .init(
                    project: "Payments", issue: "Consumer lag",
                    evidence: "Investigated Kafka consumer lag and fixed a slow database query."),
                .init(
                    project: "Invented", issue: "Network outage", evidence: "A three-hour outage occurred."),
            ])
        let grounded = analysis.grounded(in: resume)
        XCTAssertEqual(grounded.skills, ["Java"])
        XCTAssertEqual(grounded.projects.map(\.name), ["Payments"])
        XCTAssertEqual(grounded.incidents.map(\.issue), ["Consumer lag"])
    }
    func testCompletedResponseDecodesAndRejectsTruncatedRefusedOrInvalidResponses() throws {
        let analysis = ResumeAnalysis(skills: ["Java"], projects: [], incidents: [])
        let json = String(decoding: try JSONEncoder().encode(analysis), as: UTF8.self)
        let valid = try JSONSerialization.data(withJSONObject: [
            "status": "completed", "output": [["content": [["type": "output_text", "text": json]]]],
        ])
        XCTAssertEqual(try ResumeRequest.decode(valid, source: resume), analysis)
        for body in [
            ["status": "incomplete"],
            ["status": "completed", "output": [["content": [["type": "refusal", "refusal": "no"]]]]],
            ["status": "completed", "output": []],
        ] as [[String: Any]] {
            XCTAssertThrowsError(
                try ResumeRequest.decode(JSONSerialization.data(withJSONObject: body), source: resume))
        }
        XCTAssertThrowsError(try ResumeRequest.decode(Data("invalid".utf8), source: resume))
    }
    func testContextPrioritizesRealNotesAndSelectedProjectWithinBudget() {
        let analysis = ResumeAnalysis(
            skills: ["Java"],
            projects: (0..<12).map {
                .init(
                    name: "Project \($0)", summary: String(repeating: "description ", count: 100),
                    evidence: String(repeating: "evidence ", count: 100))
            }, incidents: [])
        let context = analysis.context(
            currentProject: "Project 10", notes: "Real incident: payment timeouts; added a database index.")
        XCTAssertLessThanOrEqual(context.count, 8500)
        XCTAssertTrue(context.contains("Real incident: payment timeouts"))
        XCTAssertTrue(context.contains("Project: Project 10"))
        XCTAssertTrue(context.contains("Do not invent personal incident history"))
        XCTAssertLessThan(
            context.range(of: "Project: Project 10")!.lowerBound,
            context.range(of: "Project: Project 0")!.lowerBound)
    }
    func testExperienceRequestsTriggerAndPromptKeepsScenariosSeparateFromFacts() {
        for question in [
            "Share a real-time production issue you faced in your project",
            "Discuss a bottleneck from your previous project",
            "Tell us about an incident in your current project",
            "Give an example of troubleshooting Kafka consumer lag",
        ] { XCTAssertTrue(QuestionDetector.isCandidate(question), question) }
        XCTAssertFalse(QuestionDetector.isCandidate("I investigated consumer lag yesterday."))
        XCTAssertTrue(Profile.instructions.contains("Hypothetical scenario:"))
        XCTAssertTrue(
            Profile.instructions.contains(
                "symptom -> bottleneck/root cause -> diagnosis -> fix -> validation"))
        XCTAssertTrue(Profile.instructions.contains("Use first person only for facts supported"))
    }
}
