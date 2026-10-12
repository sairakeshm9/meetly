import XCTest

@testable import MeetingCore

final class AnswerQualityTests: XCTestCase {
    func testFollowupDissatisfactionAndInterruptionRouting() {
        for text in ["Why is that better?", "Wait, how does that work?", "Can you clarify the tradeoff?"] {
            XCTAssertEqual(ConversationRouter.intent(text, hasContext: true), .followUp)
        }
        for text in [
            "That is wrong", "Not satisfied with that answer", "That doesn't answer my question", "Try again",
            "Can you give a better answer?", "I don't understand",
        ] {
            XCTAssertEqual(ConversationRouter.intent(text, hasContext: true), .correction)
        }
        XCTAssertTrue(ConversationRouter.isUrgent("Wait, why not?", intent: .followUp))
        XCTAssertTrue(ConversationRouter.isUrgent("Hold on, explain the tradeoff", intent: .followUp))
        XCTAssertTrue(
            AnswerQuality.requiresStrongerModel(intent: .newQuestion, interrupted: true, requested: false))
        XCTAssertTrue(
            AnswerQuality.requiresStrongerModel(intent: .newQuestion, interrupted: false, requested: true))
        XCTAssertFalse(
            AnswerQuality.requiresStrongerModel(intent: .newQuestion, interrupted: false, requested: false))
    }
    func testPrecisionOverridesLongCustomLayoutButPreservesCodeRequirements() throws {
        for mode in [AssistantMode.questions, .coding] {
            let data = try APIRequest.answer(
                model: "gpt-6.1-sol", question: "Why use this?", context: "last answer", background: "",
                mode: mode, template: .custom, customTemplate: "Give a long detailed explanation.",
                precision: true)
            let body = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            let instructions = try XCTUnwrap(body["instructions"] as? String)
            XCTAssertTrue(instructions.hasSuffix(AnswerQuality.guidance))
            XCTAssertTrue(instructions.contains("70–120 words"))
            XCTAssertTrue(instructions.contains("complete relevant commented solution"))
            XCTAssertEqual((body["reasoning"] as? [String: String])?["effort"], "low")
        }
    }
}
