import AppKit
import MeetingCore
import XCTest

@testable import MeetingAssist

final class PresentationTests: XCTestCase {
    func testMarkdownAndAutomaticKeywordsRenderBoldWithoutShowingMarkers() {
        let rendered = AnswerTypography.emphasized(
            "Use **constructor injection** in Java. 🚀 SQL avoids duplicates.")
        XCTAssertEqual(
            String(rendered.characters), "Use constructor injection in Java. 🚀 SQL avoids duplicates.")
        let bold = rendered.runs.filter { $0.inlinePresentationIntent?.contains(.stronglyEmphasized) == true }
            .map { String(rendered[$0.range].characters) }.joined()
        XCTAssertTrue(bold.contains("constructor injection"))
        XCTAssertTrue(bold.contains("Java"))
        XCTAssertTrue(bold.contains("SQL"))
    }
    func testModelSelectedPhraseOutsideVocabularyReceivesAccent() {
        let rendered = AnswerTypography.emphasized("Use **bounded work queues** to keep it manageable.")
        let selected = rendered.runs.filter {
            $0.inlinePresentationIntent?.contains(.stronglyEmphasized) == true
        }
        XCTAssertEqual(selected.map { String(rendered[$0.range].characters) }.joined(), "bounded work queues")
        XCTAssertTrue(selected.allSatisfy { $0.foregroundColor == MeetlyPalette.accent })
    }
    func testAutomaticEmphasisPreservesItalicAndInlineCode() {
        let rendered = AnswerTypography.emphasized("Use *Java* and `HashMap` for lookups.")
        XCTAssertEqual(String(rendered.characters), "Use Java and HashMap for lookups.")
        let java = rendered.runs.first { String(rendered[$0.range].characters) == "Java" }
        XCTAssertTrue(java?.inlinePresentationIntent?.contains(.emphasized) == true)
        XCTAssertTrue(java?.inlinePresentationIntent?.contains(.stronglyEmphasized) == true)
        let code = rendered.runs.first { String(rendered[$0.range].characters) == "HashMap" }
        XCTAssertTrue(code?.inlinePresentationIntent?.contains(.code) == true)
        XCTAssertFalse(code?.inlinePresentationIntent?.contains(.stronglyEmphasized) == true)
        XCTAssertNil(code?.foregroundColor)
    }
    func testAllConceptsAreAccentedWhileConnectiveProseStaysPlain() {
        let source = "Use transactions and optimistic locking to avoid race conditions."
        let rendered = AnswerTypography.emphasized(source)
        XCTAssertEqual(String(rendered.characters), source)
        let bold = rendered.runs.filter { $0.inlinePresentationIntent?.contains(.stronglyEmphasized) == true }
        XCTAssertEqual(
            bold.map { String(rendered[$0.range].characters) },
            ["transactions", "optimistic locking", "avoid race conditions"])
        XCTAssertTrue(bold.allSatisfy { $0.foregroundColor == MeetlyPalette.accent })
        XCTAssertTrue(
            rendered.runs.contains {
                String(rendered[$0.range].characters) == " to " && $0.foregroundColor == nil
            })
    }
    func testScreenshotStyleExplanationHighlightsPurposeThroughout() {
        let source =
            "Java is a programming language used to build applications.\n"
            + "Spring Boot provides sensible defaults and reduces setup work for web services.\n"
            + "@GetMapping handles HTTP GET requests for a URL.\n"
            + "Each service can deploy independently and scale separately."
        let rendered = AnswerTypography.emphasized(source)
        let bold = rendered.runs.filter { $0.inlinePresentationIntent?.contains(.stronglyEmphasized) == true }
            .map { String(rendered[$0.range].characters) }
        for cue in [
            "programming language", "provides sensible defaults", "reduces setup work",
            "handles HTTP GET requests", "deploy independently", "scale separately",
        ] {
            XCTAssertTrue(bold.contains(cue), "Missing cue: \(cue), got \(bold)")
        }
        XCTAssertEqual(String(rendered.characters), source)
    }
    func testLongAnswersStayReadableAndSmallerManualSizeIsRespected() {
        let long = String(
            repeating: "The service prevents repeated charges for customer orders.\n", count: 80)
        XCTAssertEqual(AnswerTypography.fit(long, requested: 20, width: 250, height: 70, enabled: true), 14)
        XCTAssertEqual(AnswerTypography.fit(long, requested: 11, width: 250, height: 70, enabled: true), 11)
    }
    func testAutoFitShrinksLongContentButNeverBelowReadableFloor() {
        let text = String(repeating: "Java and SQL can handle a database transaction. ", count: 30)
        XCTAssertLessThan(
            AnswerTypography.fit(text, requested: 22, width: 420, height: 160, enabled: true), 22)
        XCTAssertGreaterThanOrEqual(
            AnswerTypography.fit(text, requested: 22, width: 100, height: 60, enabled: true), 14)
        XCTAssertEqual(AnswerTypography.fit(text, requested: 22, width: 420, height: 160, enabled: false), 22)
        XCTAssertEqual(
            AnswerTypography.fit("Brief answer", requested: 15, width: 800, height: 300, enabled: true), 15)
    }
    func testCodeHeightIsIncludedInFittingAndCodeIndentationIsUnchanged() {
        let code = "```java\n" + (1...30).map { "    // line \($0)" }.joined(separator: "\n") + "\n```"
        XCTAssertEqual(AnswerTypography.fit(code, requested: 20, width: 600, height: 80, enabled: true), 14)
        XCTAssertTrue(AnswerBlock.parse(code).first?.text.hasPrefix("    // line 1") == true)
    }
    @MainActor
    func testManualTextControlsAreBoundedAndDisableFit() {
        let model = MeetingModel()
        let oldSize = model.textSize
        let oldFit = model.autoFit
        defer {
            model.textSize = oldSize
            model.autoFit = oldFit
        }
        model.textSize = 15
        model.autoFit = true
        model.adjustTextSize(1)
        XCTAssertEqual(model.textSize, 16)
        XCTAssertFalse(model.autoFit)
        model.adjustTextSize(100)
        XCTAssertEqual(model.textSize, 28)
        model.adjustTextSize(-100)
        XCTAssertEqual(model.textSize, 10)
    }
}
