import XCTest

@testable import MeetingCore

final class SpeechAlignmentTests: XCTestCase {
    let source = """
        SAY THIS:
        - Constructor injection makes dependencies explicit and testable.
        - A unique database constraint prevents duplicate payment events.
        - Retry failed messages after a temporary network error.
        EXAMPLE:
        A payment event ID prevents a second charge.
        """
    func testOwnWordsMapToConceptWithoutReadingVerbatim() {
        let doc = SpeechDocument(source)
        let match = doc.match(
            "Passing dependencies through the constructor makes testing easier", current: nil)
        XCTAssertNotNil(match)
        XCTAssertTrue(doc.passages[match!].text.contains("Constructor injection"))
    }
    func testSkipAheadRepeatAndReturnDoNotMarkSkippedPartsCovered() {
        let doc = SpeechDocument(source)
        var progress = SpeechProgress()
        progress.receive("Constructor injection makes dependencies testable", final: true, document: doc)
        let original = progress.current!
        progress.receive("Retry failed messages after network errors", final: true, document: doc)
        let later = progress.current!
        XCTAssertGreaterThan(later, original)
        XCTAssertEqual(progress.covered.count, 2)
        progress.receive("Retry failed messages after network errors", final: true, document: doc)
        XCTAssertEqual(progress.current, later)
        progress.receive("Constructor injection makes dependencies testable", final: true, document: doc)
        XCTAssertEqual(progress.current, original)
        XCTAssertEqual(progress.covered.count, 2)
    }
    func testPartialDoesNotMarkCoveredAndUnclearSpeechHoldsPosition() {
        let doc = SpeechDocument(source)
        var progress = SpeechProgress()
        progress.receive(
            "Unique database constraint prevents duplicate payments", final: false, document: doc)
        XCTAssertNotNil(progress.current)
        XCTAssertTrue(progress.covered.isEmpty)
        let position = progress.current
        progress.receive("hmm well anyway", final: true, document: doc)
        XCTAssertEqual(progress.current, position)
        XCTAssertTrue(progress.uncertain)
        XCTAssertTrue(progress.covered.isEmpty)
    }
    func testOppositeMeaningAndGenericTermsDoNotCountAsCovered() {
        let doc = SpeechDocument(
            "Use database locks for concurrent updates.\nAvoid database locks for concurrent updates.")
        let positive = doc.match("Use database locks for concurrent updates", current: nil)
        let negative = doc.match("Avoid database locks for concurrent updates", current: nil)
        XCTAssertNotNil(positive)
        XCTAssertNotNil(negative)
        XCTAssertNotEqual(positive, negative)
        XCTAssertNil(
            SpeechDocument("Use database locks for concurrent updates.").match(
                "Do not use database locks for concurrent updates", current: nil))
        XCTAssertNil(doc.match("yes the", current: nil))
        XCTAssertNil(doc.match("database", current: nil))
    }
    func testAmbiguousRepeatedTextHoldsUnlessNearCurrentPassage() {
        let doc = SpeechDocument(
            "A database constraint prevents duplicates.\nNetwork retries handle failures.\nA database constraint prevents duplicates."
        )
        XCTAssertNil(doc.match("A database constraint prevents duplicates", current: nil))
        XCTAssertEqual(doc.match("A database constraint prevents duplicates", current: 2), 2)
    }
    func testManualScrollHoldStillFollowsSpeechWithoutMovingViewport() {
        let doc = SpeechDocument(source)
        var progress = SpeechProgress()
        progress.manualPause = true
        progress.receive("Constructor injection makes dependencies testable", final: true, document: doc)
        XCTAssertNotNil(progress.current)
        XCTAssertEqual(progress.covered.count, 1)
        XCTAssertTrue(progress.manualPause)
    }
    func testMarkdownCodeAndTablesPreserveRenderingAndStablePrefixIDs() {
        let code = "```java\n// Retry failed network messages\nvoid retry() { }\n```"
        let doc = SpeechDocument("**Constructor injection** makes dependencies testable.\n" + code)
        XCTAssertEqual(doc.passages.last?.kind, .code)
        XCTAssertTrue(doc.blocks.first!.text.contains("**Constructor injection**"))
        XCTAssertTrue(doc.passages.first!.text.contains("Constructor injection"))
        XCTAssertFalse(doc.passages.first!.text.contains("**"))
        let longer = SpeechDocument(
            "**Constructor injection** makes dependencies testable.\n" + code
                + "\nA unique constraint prevents duplicates.")
        XCTAssertEqual(Array(longer.passages.prefix(doc.passages.count)), doc.passages)
        XCTAssertEqual(doc.match("Retry failed network messages", current: nil), doc.passages.last?.id)
        let table = SpeechDocument("| Choice | Benefit |\n| --- | --- |\n| Locks | Consistency |")
        XCTAssertEqual(table.passages.first?.kind, .table)
        XCTAssertTrue(SpeechDocument("").passages.isEmpty)
    }
    func testLongAnswerIndexesAndFindsDistantPassage() {
        let text = (0..<400).map { "Discuss subject\($0) and requirement\($0) carefully." }.joined(
            separator: "\n")
        let doc = SpeechDocument(text)
        XCTAssertEqual(doc.match("Explain subject390 and requirement390", current: 1), 390)
        measure {
            for _ in 0..<30 { _ = doc.match("Explain subject390 and requirement390", current: 1) }
        }
    }
    func testScrollOnlyMovesWhenNeededAndAllowed() {
        XCTAssertTrue(
            SpeechScrollPolicy.shouldScroll(
                enabled: true, manualPause: false, readAloud: false, uncertain: false, passageMinY: 350,
                viewportHeight: 400))
        XCTAssertTrue(
            SpeechScrollPolicy.shouldScroll(
                enabled: true, manualPause: false, readAloud: false, uncertain: false, passageMinY: -10,
                viewportHeight: 400))
        for flags in [
            (false, false, false, false), (true, true, false, false), (true, false, true, false),
            (true, false, false, true),
        ] {
            XCTAssertFalse(
                SpeechScrollPolicy.shouldScroll(
                    enabled: flags.0, manualPause: flags.1, readAloud: flags.2, uncertain: flags.3,
                    passageMinY: 350, viewportHeight: 400))
        }
        XCTAssertFalse(
            SpeechScrollPolicy.shouldScroll(
                enabled: true, manualPause: false, readAloud: false, uncertain: false, passageMinY: 120,
                viewportHeight: 400))
        XCTAssertFalse(
            SpeechScrollPolicy.shouldScroll(
                enabled: true, manualPause: false, readAloud: false, uncertain: false, passageMinY: nil,
                viewportHeight: 400))
    }

    func testGrowingContinuousSpeechFollowsLatestPhraseRatherThanEarlierWords() {
        let doc = SpeechDocument(source)
        var progress = SpeechProgress()
        let first = "Constructor injection makes dependencies explicit and testable."
        progress.receive(first, final: false, document: doc)
        let start = progress.current!
        progress.receive(
            first + " A unique database constraint prevents duplicate payment events.", final: false,
            document: doc)
        XCTAssertGreaterThan(progress.current!, start)
        XCTAssertTrue(doc.passages[progress.current!].text.contains("unique database"))
    }

    func testEarlierNegationDoesNotBlockNextPositiveSentenceAndCurlyContractionsAreSafe() {
        let doc = SpeechDocument(
            "Avoid locks for concurrent updates.\nUse database transactions to group payment events.")
        XCTAssertEqual(
            doc.match(
                "Avoid locks for concurrent updates. Use database transactions to group payment events.",
                current: 0), 1)
        XCTAssertNil(
            SpeechDocument("Use database locks for concurrent updates.").match(
                "Don’t use database locks for concurrent updates", current: nil))
    }

}
