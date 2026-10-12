import XCTest

@testable import MeetingCore

final class ConversationRelationTests: XCTestCase {
    func testRelatedConceptsNeedNoFollowupStarter() {
        XCTAssertEqual(
            ConversationRelation.match(
                "Which isolation level would you choose?", questions: ["How do you prevent race conditions?"]),
            0)
        XCTAssertEqual(
            ConversationRelation.match(
                "How can I test the constructor with mocks?",
                questions: ["What is dependency injection?", "What is Kafka?", "What is Docker?"]), 0)
        XCTAssertEqual(
            ConversationRelation.match(
                "What happens if the offset is committed early?", questions: ["Explain Kafka consumers"]), 0)
    }
    func testAnswerIntroducedConceptsAndReferencesAreIncluded() {
        XCTAssertEqual(
            ConversationRelation.match(
                "What happens during a rebalance?", questions: ["What is Kafka?"],
                answers: ["A rebalance redistributes partitions."]), 0)
        XCTAssertEqual(
            ConversationRelation.match("Would that still be safe?", questions: ["Topic A", "Topic B"]), 1)
        XCTAssertEqual(
            ConversationRelation.match("Are there downsides?", questions: ["Explain dependency injection"]), 0
        )
    }
    func testExplicitTopicChangesResetRelationEvenWithSharedWords() {
        XCTAssertNil(
            ConversationRelation.match(
                "New topic: explain Java arrays", questions: ["Explain Java dependency injection"]))
        XCTAssertEqual(
            ConversationRouter.intent("New topic: explain Java arrays", hasContext: true), .newQuestion)
    }
    func testDistinctDefinitionsRemainIndependentAndWindowIsBounded() {
        XCTAssertNil(ConversationRelation.match("What is Docker?", questions: ["What is Kafka?"]))
        XCTAssertNil(
            ConversationRelation.match("What is a linked list?", questions: ["Explain HTTP endpoints"]))
        XCTAssertNil(
            ConversationRelation.match(
                "Explain injection",
                questions: [
                    "Explain dependency injection", "What is Kafka?", "What is Docker?", "What is HTTP?",
                ]))
        XCTAssertNil(ConversationRelation.match("Why?", questions: []))
    }
    func testLongTopicRetainsOpeningConstraintsWhileKeepingOnlyThreeFullQuestions() {
        var history = QuestionHistory()
        history.record(
            id: "0",
            text: "Design inventory reservations: must prevent overselling without distributed locks",
            continuesTopic: false)
        for index in 1...20 {
            history.record(id: "\(index)", text: "How does step \(index) work?", continuesTopic: true)
        }
        XCTAssertEqual(history.questions.count, 3)
        XCTAssertTrue(history.topicContext.contains("without distributed locks"))
        XCTAssertFalse(history.context.contains("step 1 work"))
        XCTAssertLessThanOrEqual(history.topicContext.count, 2400)
        XCTAssertLessThan(history.context.count, 5800)
        XCTAssertNotNil(
            ConversationRelation.match("Explain inventory reservations", questions: [history.topicContext]))
        history.record(id: "21", text: "New topic: explain Java arrays", continuesTopic: false)
        XCTAssertFalse(history.topicContext.contains("inventory"))
        XCTAssertTrue(history.topicContext.contains("Java arrays"))
    }
    func testTopicNotesBoundHugeInputsAndDoNotTreatDuplicatesAsCorrections() {
        var history = QuestionHistory()
        for index in 0..<100 {
            history.record(
                id: "\(index)",
                text: "Actually must use constraint \(index) " + String(repeating: "x", count: 6000),
                continuesTopic: index > 0)
        }
        XCTAssertLessThanOrEqual(history.context.count, 5500)
        XCTAssertTrue(history.topicContext.contains("constraint 99"))
        let context = history.context
        history.record(id: "99", text: "New topic: other", continuesTopic: false)
        XCTAssertEqual(history.context, context)
    }

    func testWrappedCorrectionKeepsNewConstraintAfterItLeavesRecentHistory() {
        var history = QuestionHistory()
        let original = "Design inventory reservations " + String(repeating: "old detail ", count: 80)
        history.record(id: "0", text: original, continuesTopic: false)
        history.record(
            id: "1",
            text: ConversationRouter.correcting(
                "Actually must use PostgreSQL instead of Redis", previous: original), continuesTopic: true)
        for index in 2...10 {
            history.record(id: "\(index)", text: "How does step \(index) work?", continuesTopic: true)
        }
        XCTAssertTrue(history.topicContext.contains("must use PostgreSQL instead of Redis"))
        XCTAssertFalse(history.questions.contains { $0.id == "1" })
    }

}
