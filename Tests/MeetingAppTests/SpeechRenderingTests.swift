import AVFoundation
import AppKit
import MeetingCore
import SwiftUI
import XCTest

@testable import MeetingAssist

final class SpeechRenderingTests: XCTestCase {
    static let python = """
        SAY THIS:
        - Python is a programming language used to give computers instructions. Its clear, readable style makes it useful for tasks like automation, data analysis, and building web applications.
        - For example, a Python script can read a file and find all the rows that contain an error.
        """
    @MainActor
    func testNativeProsePreservesOriginalCharactersEmphasisAndTypography() {
        let source =
            "SAY THIS:\n- **Python** gives computers instructions. 🚀 Use `print()` for output.\n- Read files to find error rows."
        let document = SpeechDocument(source)
        let original = AnswerTypography.emphasized(source)
        let rendered = NativeAnswerFormatting.prose(source, size: 15)
        XCTAssertEqual(rendered.string, String(original.characters))
        let python = (rendered.string as NSString).range(of: "Python")
        let font = rendered.attribute(.font, at: python.location, effectiveRange: nil) as! NSFont
        XCTAssertEqual(font.pointSize, 15)
        XCTAssertTrue(NSFontManager.shared.traits(of: font).contains(.boldFontMask))
        let paragraph =
            rendered.attribute(.paragraphStyle, at: python.location, effectiveRange: nil) as! NSParagraphStyle
        XCTAssertEqual(paragraph.lineSpacing, 3)
        for passage in document.passages {
            XCTAssertEqual((rendered.string as NSString).substring(with: passage.plainRange), passage.text)
        }
        XCTAssertEqual(NativeAnswerFormatting.prose("", size: 15).string, "")
    }
    func testExactReportedPythonAnswerTracksEachSentence() {
        let document = SpeechDocument(Self.python)
        var progress = SpeechProgress()
        let readings = [
            "Python is a programming language used to give computers instructions.",
            "Its clear readable style makes it useful for tasks like automation data analysis and building web applications.",
            "For example a Python script can read a file and find all the rows that contain an error.",
        ]
        var matched = Set<Int>()
        for spoken in readings {
            progress.receive(spoken, final: true, document: document)
            XCTAssertFalse(progress.uncertain)
            if let position = progress.current { matched.insert(position) }
        }
        XCTAssertEqual(matched.count, 3)
        XCTAssertEqual(progress.covered, matched)
    }
    func testAnswerClicksNeverPauseButActualScrollActionsDo() {
        XCTAssertFalse(
            SpeechScrollIntent.pauses(
                type: .leftMouseDown, key: 0, inside: true, scrollbar: false, focused: true))
        XCTAssertTrue(
            SpeechScrollIntent.pauses(
                type: .leftMouseDown, key: 0, inside: true, scrollbar: true, focused: false))
        XCTAssertTrue(
            SpeechScrollIntent.pauses(
                type: .scrollWheel, key: 0, inside: true, scrollbar: false, focused: false))
        XCTAssertFalse(
            SpeechScrollIntent.pauses(
                type: .scrollWheel, key: 0, inside: false, scrollbar: false, focused: true))
        XCTAssertTrue(
            SpeechScrollIntent.pauses(
                type: .keyDown, key: 121, inside: false, scrollbar: false, focused: true))
        XCTAssertFalse(
            SpeechScrollIntent.pauses(
                type: .keyDown, key: 121, inside: true, scrollbar: false, focused: false))
    }
    func testInputMeterRecognizesSilentAndNonSilentBuffers() throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 32)!
        buffer.frameLength = 32
        for index in 0..<32 { buffer.floatChannelData![0][index] = 0 }
        XCTAssertFalse(LocalSpeechRecognizer.hasSignal(buffer))
        for index in 0..<32 { buffer.floatChannelData![0][index] = 0.04 }
        XCTAssertTrue(LocalSpeechRecognizer.hasSignal(buffer))
    }
}
