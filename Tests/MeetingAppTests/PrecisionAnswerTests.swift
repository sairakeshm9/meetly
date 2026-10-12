import Combine
import MeetingCore
import XCTest

@testable import MeetingAssist

@MainActor
final class PrecisionAnswerTests: XCTestCase {
    func testTypedFollowupUsesStrongerModelAndRelevantAnswerWithoutExpanding() async {
        let first = expectation(description: "ordinary")
        let followup = expectation(description: "followup")
        var calls = 0
        let model = MeetingModel(
            credentials: CredentialAccess { "test-only" },
            answerStreamer: { request, delta in
                calls += 1
                if calls == 1 {
                    XCTAssertFalse(request.precision)
                    delta("Use constructor injection because dependencies are explicit.")
                    first.fulfill()
                } else {
                    XCTAssertEqual(request.model, "stronger-test-model")
                    XCTAssertTrue(request.precision)
                    XCTAssertFalse(request.expanded)
                    XCTAssertTrue(request.context.contains("dependencies are explicit"))
                    delta("Constructor injection makes required dependencies visible and testable.")
                    followup.fulfill()
                }
            })
        model.hasKey = true
        let old = model.followupAnswerModel
        defer {
            model.followupAnswerModel = old
            model.stop()
        }
        model.followupAnswerModel = "stronger-test-model"
        model.ask("Explain dependency injection")
        await fulfillment(of: [first], timeout: 3)
        model.ask("Why is that better?")
        await fulfillment(of: [followup], timeout: 3)
        XCTAssertEqual(model.activeCard?.route, "Precision")
        XCTAssertNotNil(model.activeCard?.parentID)
    }
    func testBetterAnswerTargetsPinnedCardAndExcludesUnrelatedLatestAnswer() async {
        let done = expectation(description: "better")
        let model = MeetingModel(
            credentials: CredentialAccess { "test-only" },
            answerStreamer: { request, delta in
                XCTAssertTrue(request.precision)
                XCTAssertFalse(request.expanded)
                XCTAssertEqual(request.question, "Explain transactions")
                XCTAssertTrue(request.context.contains("Original selected explanation"))
                XCTAssertFalse(request.context.contains("UNRELATED_NEWEST_ANSWER"))
                delta("A transaction makes related updates succeed or fail together.")
                done.fulfill()
            })
        model.hasKey = true
        var selected = AnswerCard(question: "Explain transactions")
        selected.answer = "Original selected explanation"
        selected.finished = true
        var newest = AnswerCard(question: "Explain arrays")
        newest.answer = "UNRELATED_NEWEST_ANSWER"
        newest.finished = true
        model.cards = [newest, selected]
        model.selectedCardID = selected.id
        model.explainMore()
        await fulfillment(of: [done], timeout: 3)
        XCTAssertEqual(model.activeCard?.parentID, selected.id)
        model.stop()
    }
    func testInterruptionUsesStrongerModelAndIgnoresCancelledLateText() async {
        let first = expectation(description: "held")
        let second = expectation(description: "interruption")
        var release: CheckedContinuation<Void, Never>?
        var calls = 0
        let model = MeetingModel(
            credentials: CredentialAccess { "test-only" },
            answerStreamer: { request, delta in
                calls += 1
                if calls == 1 {
                    delta("Partial first explanation")
                    await withCheckedContinuation {
                        release = $0
                        first.fulfill()
                    }
                    delta("STALE_LATE_TEXT")
                } else {
                    XCTAssertTrue(request.precision)
                    XCTAssertFalse(request.expanded)
                    delta("Answer the interruption directly.")
                    second.fulfill()
                }
            })
        model.hasKey = true
        model.ask("Explain transactions")
        await fulfillment(of: [first], timeout: 3)
        model.ask("Wait, why not optimistic locking?")
        await fulfillment(of: [second], timeout: 3)
        release?.resume()
        XCTAssertEqual(model.activeCard?.route, "Precision")
        XCTAssertFalse(model.activeCard?.answer.contains("STALE_LATE_TEXT") == true)
        model.stop()
    }
    func testUnavailableStrongerModelReportsFailureWithoutCheapFallback() async {
        let failed = expectation(description: "model unavailable")
        var calls = 0
        let model = MeetingModel(
            credentials: CredentialAccess { "test-only" },
            answerStreamer: { request, _ in
                calls += 1
                XCTAssertTrue(request.precision)
                failed.fulfill()
                throw MeetingError.message("Model unavailable")
            })
        model.hasKey = true
        var card = AnswerCard(question: "Explain transactions")
        card.answer = "Prior answer"
        card.finished = true
        model.cards = [card]
        model.explainMore()
        await fulfillment(of: [failed], timeout: 3)
        XCTAssertEqual(calls, 1)
        model.stop()
    }
    func testFullyWordedRelatedQuestionLinksToOlderOfLastThreeTopics() async {
        let answered = expectation(description: "four answers")
        answered.expectedFulfillmentCount = 4
        var calls = 0
        let model = MeetingModel(
            credentials: CredentialAccess { "test-only" },
            answerStreamer: { request, delta in
                calls += 1
                if calls == 4 {
                    XCTAssertTrue(request.precision)
                    XCTAssertTrue(
                        request.context.contains("Constructor injection makes dependencies explicit"))
                    XCTAssertFalse(request.context.contains("UNRELATED_DOCKER_ANSWER"))
                }
                delta(
                    calls == 1
                        ? "Constructor injection makes dependencies explicit"
                        : calls == 3 ? "UNRELATED_DOCKER_ANSWER" : "A short answer")
                answered.fulfill()
            })
        model.hasKey = true
        // Synchronize on each completed card rather than sleeping between questions.
        for question in [
            "What is dependency injection?", "What is Kafka?", "What is Docker?",
            "How can I test the constructor with mocks?",
        ] {
            let finished = expectation(description: question)
            var delivered = false
            let observer = model.$cards.sink { cards in
                if cards.first?.question == question, cards.first?.finished == true, !delivered {
                    delivered = true
                    finished.fulfill()
                }
            }
            model.ask(question)
            await fulfillment(of: [finished], timeout: 3)
            observer.cancel()
        }
        await fulfillment(of: [answered], timeout: 3)
        XCTAssertEqual(model.activeCard?.parentID, model.cards.last?.id)
        model.stop()
    }
    func testFollowupModelPreferencePersists() {
        let name = "MeetlyPrecisionTests-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let model = MeetingModel(appearanceDefaults: defaults)
        XCTAssertEqual(model.followupAnswerModel, "gpt-6.1-sol")
        model.followupAnswerModel = "stronger-test-model"
        XCTAssertEqual(MeetingModel(appearanceDefaults: defaults).followupAnswerModel, "stronger-test-model")
    }
    func testLongDiscussionKeepsOlderRequirementAndExplicitTopicChangeClearsIt() async {
        let root = "Design inventory reservations: must prevent overselling without distributed locks"
        let questions = [
            root, "Why?", "An example?", "Are there downsides?", "How would it scale?",
            "Explain inventory reservations", "New topic: explain Java arrays",
        ]
        var calls = 0
        let model = MeetingModel(
            credentials: CredentialAccess { "test-only" },
            answerStreamer: { request, delta in
                calls += 1
                if calls == 6 {
                    XCTAssertTrue(request.precision)
                    XCTAssertTrue(request.context.contains("without distributed locks"))
                }
                if calls == 7 {
                    XCTAssertFalse(request.precision)
                    XCTAssertFalse(request.context.contains("overselling"))
                    XCTAssertFalse(request.context.contains("without distributed locks"))
                }
                delta("Short explanation for this request.")
            })
        model.hasKey = true
        for question in questions {
            let finished = expectation(description: question)
            var delivered = false
            let observer = model.$cards.sink { cards in
                if cards.first?.question == question, cards.first?.finished == true, !delivered {
                    delivered = true
                    finished.fulfill()
                }
            }
            model.ask(question)
            await fulfillment(of: [finished], timeout: 3)
            observer.cancel()
        }
        XCTAssertEqual(calls, questions.count)
        model.stop()
    }

}
