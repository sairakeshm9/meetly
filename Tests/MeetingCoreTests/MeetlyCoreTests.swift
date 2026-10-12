import XCTest

@testable import MeetingCore

final class MeetlyCoreTests: XCTestCase {
    func testTemplatesReachRequestAndRefreshOverridesDetail() throws {
        func request(_ template: AnswerTemplate, simple: Bool = false) throws -> [String: Any] {
            try JSONSerialization.jsonObject(
                with: APIRequest.answer(
                    model: "gpt-6-luna", question: "Compare Kafka and MQ", context: "", background: "",
                    template: template, simplified: simple)) as! [String: Any]
        }
        let brief = try request(.brief)
        XCTAssertTrue((brief["instructions"] as! String).contains("compact Markdown table"))
        XCTAssertTrue((brief["instructions"] as! String).contains("little background knowledge"))
        XCTAssertTrue((brief["instructions"] as! String).contains("must contain a Markdown table"))
        XCTAssertFalse(
            AnswerTemplate.brief.guidance(for: "What is Kafka?").contains("must contain a Markdown table"))
        let layered = try request(.layered)
        XCTAssertTrue((layered["instructions"] as! String).contains("three sections in order"))
        XCTAssertEqual(layered["max_output_tokens"] as? Int, 900)
        let refreshed = try request(.layered, simple: true)
        XCTAssertTrue((refreshed["instructions"] as! String).contains("Refresh override"))
        XCTAssertFalse((refreshed["instructions"] as! String).contains("three sections in order"))
    }
    func testCustomTemplateIsBoundedAndRefreshIgnoresItsFormat() throws {
        XCTAssertEqual(
            AnswerTemplate.normalizedCustom("  Explain first, then show a diagram.  "),
            "Explain first, then show a diagram.")
        XCTAssertEqual(AnswerTemplate.normalizedCustom(String(repeating: "x", count: 2500)).count, 2000)
        let format = "Use SUMMARY and ANALOGY, then code when needed."
        let body =
            try JSONSerialization.jsonObject(
                with: APIRequest.answer(
                    model: "gpt-6-luna", question: "Compare two lists", context: "", background: "",
                    template: .custom, customTemplate: format)) as! [String: Any]
        let instructions = body["instructions"] as! String
        XCTAssertTrue(instructions.contains(format))
        XCTAssertFalse(instructions.contains("must contain a Markdown table"))
        let refresh =
            try JSONSerialization.jsonObject(
                with: APIRequest.answer(
                    model: "gpt-6-luna", question: "What is Kafka?", context: "", background: "",
                    template: .custom, customTemplate: format, simplified: true)) as! [String: Any]
        XCTAssertFalse((refresh["instructions"] as! String).contains(format))
        XCTAssertTrue((refresh["instructions"] as! String).contains("Refresh override"))
    }
    func testSolUsesSupportedReasoningAndEnoughRoomForCode() throws {
        let body =
            try JSONSerialization.jsonObject(
                with: APIRequest.answer(
                    model: "gpt-6.1-sol", question: "Write Java code", context: "", background: "",
                    mode: .coding)) as! [String: Any]
        XCTAssertEqual((body["reasoning"] as? [String: String])?["effort"], "low")
        XCTAssertEqual(body["max_output_tokens"] as? Int, 4000)
    }
    func testTablesRenderSeparatelyWithoutBreakingCodeOrStreamedFragments() throws {
        let source =
            "SAY THIS:\n| Type | Use |\n| --- | --- |\n| Kafka | Events |\n| MQ | Tasks |\n\n- Pick the tool for the workload.\n\nEXAMPLE:\n```java\nreturn a || b;\n```"
        let blocks = AnswerBlock.parse(source)
        let table = try XCTUnwrap(
            blocks.compactMap { $0.isCode ? nil : MarkdownAnswerTable.parse($0.text) }.first)
        XCTAssertEqual(table.headers, ["Type", "Use"])
        XCTAssertEqual(table.rows, [["Kafka", "Events"], ["MQ", "Tasks"]])
        XCTAssertEqual(blocks.last?.text, "return a || b;")
        XCTAssertEqual(blocks.last?.isCode, true)
        XCTAssertNil(MarkdownAnswerTable.parse("| Type | Use |"))
        XCTAssertNil(MarkdownAnswerTable.parse("| A | B |\n| bad | separator |"))
        XCTAssertEqual(AnswerLayers.cue("SAY THIS: - One point\nDETAIL: Long explanation"), "- One point")
    }
    func testSharingSignalsDoNotTreatHiddenToolbarAsSharingEnded() {
        XCTAssertEqual(SharingSignal.fromVisibleText("You are screen sharing\nStop Share"), .started)
        XCTAssertEqual(SharingSignal.fromVisibleText("You're presenting\nStop presenting"), .started)
        XCTAssertEqual(SharingSignal.fromVisibleText("public class Main {}"), .unknown)
        XCTAssertEqual(SharingSignal.fromVisibleText("Mute Participants Share Screen"), .stopped)
        XCTAssertEqual(SharingSignal.fromVisibleText("Screen sharing ended"), .stopped)
        XCTAssertEqual(SharingSignal.fromVisibleText("Share Screen"), .unknown)
    }
}
