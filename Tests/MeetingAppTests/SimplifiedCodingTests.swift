import Combine
import MeetingCore
import XCTest

@testable import MeetingAssist

@MainActor
final class SimplifiedCodingTests: XCTestCase {
    func testCodingPermissionFailureShowsIssueAndQuestionsClearsCapture() async {
        let capture = FeatureScreenCapture()
        capture.startError = NSError(domain: "permission", code: -3801)
        let screen = ScreenContextController(captureFactory: { capture })
        let model = MeetingModel(screen: screen)
        let failed = expectation(description: "Capture failure is visible")
        let observer = model.$error.dropFirst().sink {
            if $0?.contains("permission") == true { failed.fulfill() }
        }
        model.mode = .coding
        await fulfillment(of: [failed], timeout: 2)
        observer.cancel()
        XCTAssertFalse(screen.enabled)
        XCTAssertNil(screen.snapshot)
        model.mode = .questions
        XCTAssertFalse(model.watchScreen)
        model.stop()
    }

    func testSelectingCodingStartsScreenAndGuidanceAndQuestionsStopsIt() async {
        let capture = FeatureScreenCapture()
        let screen = ScreenContextController(captureFactory: { capture })
        let model = MeetingModel(screen: screen)
        XCTAssertFalse(model.watchScreen)
        model.autoGuide = false
        let ready = expectation(description: "Coding starts capture")
        let observer = screen.$enabled.dropFirst().sink { if $0 { ready.fulfill() } }
        model.mode = .coding
        XCTAssertTrue(model.watchScreen)
        XCTAssertTrue(model.autoGuide)
        await fulfillment(of: [ready], timeout: 2)
        observer.cancel()
        model.setScreenWatching(false)
        model.mode = .coding
        XCTAssertFalse(model.watchScreen, "Repeated sharing signals must preserve an explicit pause")
        model.mode = .questions
        model.mode = .coding
        XCTAssertTrue(model.watchScreen, "Entering Coding again restores defaults")
        model.mode = .questions
        XCTAssertFalse(screen.enabled)
        XCTAssertFalse(model.watchScreen)
        XCTAssertNil(screen.snapshot)
        model.stop()
    }

    func testCompleteSolutionRequirementOverridesCustomTemplateForFollowUps() throws {
        let data = try APIRequest.answer(
            model: "gpt-4.1-mini", question: "Why check before inserting?", context: "last three questions",
            background: "", mode: .coding, codingTask: "Write Java two sum",
            template: .custom, customTemplate: "Never show code.")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let instructions = try XCTUnwrap(body["instructions"] as? String)
        XCTAssertTrue(instructions.contains("complete current solution on every answer"))
        XCTAssertTrue(instructions.contains("FULL SOLUTION:"))
        XCTAssertTrue(instructions.contains("explanatory comments"))
        XCTAssertTrue(instructions.contains("IDE navigation"))
        XCTAssertTrue(instructions.contains("ISSUE/QUESTION takes precedence"))
        XCTAssertGreaterThan(
            try XCTUnwrap(instructions.range(of: "Coding output requirement")?.lowerBound),
            try XCTUnwrap(instructions.range(of: "Never show code.")?.lowerBound))
        XCTAssertEqual(body["max_output_tokens"] as? Int, 4000)
    }
}
