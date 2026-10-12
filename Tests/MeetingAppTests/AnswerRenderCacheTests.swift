import AppKit
import MeetingCore
import XCTest

@testable import MeetingAssist

@MainActor
final class AnswerRenderCacheTests: XCTestCase {
    let source = (0..<60).map { "- Explain subject\($0) with requirement\($0) and useful examples." }.joined(
        separator: "\n")
    func testTrackingCannotChangeOriginalFontOrTextLayoutAndDoesNotReprepare() {
        let cache = AnswerRenderCache()
        let plan = cache.resolve(source, requested: 20, width: 500, height: 160, fit: true)
        XCTAssertEqual(
            plan.size, AnswerTypography.fit(source, requested: 20, width: 500, height: 160, enabled: true))
        XCTAssertEqual(plan.blocks, AnswerBlock.parse(source))
        for _ in 0..<100 { _ = cache.resolve(source, requested: 20, width: 500, height: 160, fit: true) }
        XCTAssertEqual(cache.preparations, 1)
        XCTAssertTrue(String(plan.rows[0].styled.characters).contains("subject59"))
        let doc = SpeechDocument(source)
        let first = plan.rows[0].layout!.minY(doc.passages.first!.plainRange)
        let last = plan.rows[0].layout!.minY(doc.passages.last!.plainRange)
        XCTAssertGreaterThan(last - first, 600)
    }
    func testResizeTextSizeFitAndAnswerChangesRefreshCache() {
        let cache = AnswerRenderCache()
        _ = cache.resolve(source, requested: 15, width: 500, height: 160, fit: true)
        _ = cache.resolve(source, requested: 15, width: 350, height: 160, fit: true)
        _ = cache.resolve(source, requested: 16, width: 350, height: 160, fit: true)
        _ = cache.resolve(source, requested: 16, width: 350, height: 160, fit: false)
        _ = cache.resolve("new answer", requested: 16, width: 350, height: 160, fit: false)
        XCTAssertEqual(cache.preparations, 5)
    }
    func testHighlightsAndScrollObserverCannotInterceptAnyMouseInput() {
        let canvas = SpeechHighlightLayer.HighlightCanvas(frame: NSRect(x: 0, y: 0, width: 500, height: 500))
        let detector = ScrollIntentDetector.IntentView(action: {})
        detector.frame = canvas.frame
        for point in [NSPoint.zero, NSPoint(x: 200, y: 300)] {
            XCTAssertNil(canvas.hitTest(point))
            XCTAssertNil(detector.hitTest(point))
        }
    }
    func testMarkdownUnicodeAndMultilineHighlightRangesRetainBaseText() {
        let source =
            "**Constructor injection** makes testing easier. 🚀\nDatabase constraints prevent duplicate payment events."
        let layout = ProseGlyphLayout(source, size: 15, width: 220)
        let doc = SpeechDocument(source)
        let original = NSAttributedString(attributedString: layout.storage)
        for passage in doc.passages {
            XCTAssertFalse(layout.rectangles(passage.plainRange).isEmpty)
            XCTAssertEqual(
                (layout.storage.string as NSString).substring(with: passage.plainRange), passage.text)
        }
        XCTAssertEqual(
            layout.storage, original,
            "Highlights are drawn separately and must never edit or resize the original text")
        XCTAssertTrue(layout.rectangles(NSRange(location: 5000, length: 1)).isEmpty)
    }
}
