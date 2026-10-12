import XCTest

@testable import MeetingCore

final class UpgradeCoreTests: XCTestCase {
    func testIntentRoutingDoesNotTreatAcknowledgementsAsQuestions() {
        for s in ["Thanks", "Okay", "Yes", "No", "Got it", "Thanks, that helps."] {
            XCTAssertEqual(ConversationRouter.intent(s, hasContext: true), .acknowledgement)
        }
        for s in ["Why?", "What if there are two users?", "Without annotations", "And in Java", "An example"]
        {
            XCTAssertEqual(ConversationRouter.intent(s, hasContext: true), .followUp)
        }
        XCTAssertEqual(
            ConversationRouter.intent("Actually, optimistic locking", hasContext: true), .correction)
        XCTAssertEqual(ConversationRouter.intent("Explain transactions", hasContext: true), .newQuestion)
        XCTAssertEqual(ConversationRouter.intent("What is Kafka and", hasContext: true), .incomplete)
        XCTAssertEqual(ConversationRouter.intent("Can you", hasContext: true), .incomplete)
        XCTAssertFalse(ConversationRouter.isUrgent("An example", intent: .followUp))
        XCTAssertTrue(ConversationRouter.isUrgent("Why?", intent: .followUp))
    }
    func testCorrectionPreservesOriginalButExplicitlyDiscardsIncompatibleAssumptions() {
        let text = ConversationRouter.correcting(
            "Actually use optimistic locking", previous: "Explain database locking")
        XCTAssertTrue(text.contains("Original request: Explain database locking"))
        XCTAssertTrue(text.contains("Correction: Actually use optimistic locking"))
        XCTAssertTrue(text.contains("Discard incompatible assumptions"))
    }
    func testCueAndExampleKeepCodeIntactDuringStreaming() {
        XCTAssertEqual(AnswerLayers.cue("SAY THIS: Use **locking**."), "Use **locking**.")
        XCTAssertEqual(
            AnswerLayers.cue("SAY THIS:\nUse locking.\n\nEXAMPLE:\n```java\n  return 1;\n```"), "Use locking."
        )
        XCTAssertEqual(
            AnswerLayers.example("SAY THIS: Use locking. EXAMPLE: ```java\n  return 1;\n```"),
            "```java\n  return 1;\n```")
        XCTAssertEqual(AnswerLayers.cue("ISSUE: Topic missing"), "ISSUE: Topic missing")
    }
    func testRetrievalUsesRelevantConfirmedFactsAndNeverFillsUnknownOutcome() {
        let library = ProjectLibrary(incidents: [
            .init(
                project: "Monitoring", symptom: "False alerts from delayed CloudWatch logs",
                action: "Created Lambda to check logs using an LLM"),
            .init(project: "Payments", symptom: "Race condition in database queries"),
        ])
        let sources = library.retrieve("How did you handle false alerts and CloudWatch latency?")
        XCTAssertEqual(sources.first?.label, "Your confirmed experience · Monitoring")
        XCTAssertFalse(sources.contains(where: { $0.label.contains("Payments") }))
        XCTAssertTrue(sources.first?.text.contains("Confirmed outcome: Not supplied") == true)
        XCTAssertTrue(library.retrieve("Explain CSS flexbox").isEmpty)
        XCTAssertLessThanOrEqual(
            library.retrieve("Race condition database queries false alerts", limit: 40).count, 2)
    }
    func testLedgerSeparatesRoutesBoundsSamplesAndExcludesFailures() {
        var ledger = PerformanceLedger()
        XCTAssertNil(ledger.percentile(0.5))
        for value in 1...20 {
            ledger.record(route: "Audio", firstUseful: Double(value), total: Double(value + 1), failed: false)
        }
        ledger.record(route: "Editor", firstUseful: 100, total: 110, failed: false)
        ledger.record(route: "Audio", firstUseful: 300, total: 310, failed: true)
        XCTAssertEqual(ledger.percentile(0.5, route: "Audio"), 10)
        XCTAssertEqual(ledger.percentile(0.95, route: "Audio"), 19)
        ledger.event("Correction")
        ledger.event("Correction")
        XCTAssertEqual(ledger.events["Correction"], 2)
        for _ in 0..<300 { ledger.record(route: "Typed", firstUseful: 1, total: 2, failed: false) }
        XCTAssertEqual(ledger.samples.count, 200)
    }
    func testSilentAudioFramesAreHealthyButStoppedFramesAreNot() {
        let start = Date(timeIntervalSince1970: 1000)
        XCTAssertNil(AudioHealth.issue(now: start + 30, lastFrame: start + 29, startedAt: start))
        XCTAssertNil(AudioHealth.issue(now: start + 10, lastFrame: start, startedAt: start))
        XCTAssertNotNil(AudioHealth.issue(now: start + 30, lastFrame: start + 1, startedAt: start))
    }
    func testSemanticContractIsManualForUnsupportedModelsAndDoesNotAutoAnswer() {
        for model in ["gpt-live-transcribe", "gpt-realtime-whisper"] {
            let config = APIRequest.transcriptionConfig(model: model, semantic: true)
            let session = config["session"] as! [String: Any]
            let input = (session["audio"] as! [String: Any])["input"] as! [String: Any]
            XCTAssertTrue(input["turn_detection"] is NSNull)
        }
        let config = APIRequest.realtimeAnswerConfig(
            transcriptionModel: "gpt-4o-mini-transcribe", model: "gpt-realtime-2.1-mini", background: "",
            semantic: true)
        let session = config["session"] as! [String: Any]
        let input = (session["audio"] as! [String: Any])["input"] as! [String: Any]
        let vad = input["turn_detection"] as! [String: Any]
        XCTAssertEqual(vad["type"] as? String, "semantic_vad")
        XCTAssertEqual(vad["create_response"] as? Bool, false)
        XCTAssertEqual(vad["interrupt_response"] as? Bool, false)
    }
}
