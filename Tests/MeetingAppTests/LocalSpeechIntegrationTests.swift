import AVFoundation
import MeetingCore
import Speech
import XCTest

@testable import MeetingAssist

final class LocalSpeechIntegrationTests: XCTestCase {
    func testOptInRealLocalRecognitionOfPythonFixtureWithoutMicrophoneOrPlayback() async throws {
        guard ProcessInfo.processInfo.environment["MEETLY_TEST_LOCAL_SPEECH"] == "1" else {
            throw XCTSkip(
                "Set MEETLY_TEST_LOCAL_SPEECH=1 to transcribe a generated local audio fixture; no microphone, playback, API, or downloads."
            )
        }
        guard #available(macOS 26, *), SpeechTranscriber.isAvailable else {
            throw XCTSkip("Local speech requires a supported macOS 26+ Mac")
        }
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: "en-US"))
        else {
            throw XCTSkip("English local speech is unsupported")
        }
        let transcriber = SpeechTranscriber(locale: locale, preset: .timeIndexedProgressiveTranscription)
        guard await AssetInventory.status(forModules: [transcriber]) == .installed else {
            throw XCTSkip("English speech model is not installed")
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "meetly-python-\(UUID()).aiff")
        defer { try? FileManager.default.removeItem(at: url) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        process.arguments = [
            "-v", "Samantha", "-o", url.path,
            "Python is a programming language used to give computers instructions. Its clear readable style makes it useful for automation, data analysis, and building web applications. For example a Python script can read a file and find all the rows that contain an error.",
        ]
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        let audio = try AVAudioFile(forReading: url)
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let began = Date(timeIntervalSince1970: 100)
        let collection = Task { () throws -> [LocalSpeechEvent] in
            var events: [LocalSpeechEvent] = []
            for try await result in transcriber.results {
                events.append(LocalSpeechEvent.decode(result, began: began))
            }
            return events
        }
        do {
            _ = try await analyzer.analyzeSequence(from: audio)
            try await analyzer.finalizeAndFinishThroughEndOfInput()
            let events = try await collection.value
            XCTAssertFalse(events.isEmpty)
            XCTAssertTrue(
                events.contains { !$0.segments.isEmpty }, "Real word timestamps must reach the event decoder")
            let document = SpeechDocument(SpeechRenderingTests.python)
            var progress = SpeechProgress()
            var positions = Set<Int>()
            for event in events {
                progress.receive(event.text(after: began), final: event.final, document: document)
                if let position = progress.current { positions.insert(position) }
            }
            XCTAssertGreaterThanOrEqual(
                positions.count, 2, "Real local audio should advance across the Python explanation")
            XCTAssertTrue(document.passages[progress.current!].text.contains("Python script"))
            print(
                "Local Python fixture verified: \(events.count) events, \(positions.count) distinct matched passages; no mic, playback, API or downloads."
            )
        } catch {
            collection.cancel()
            await analyzer.cancelAndFinishNow()
            throw error
        }
    }
}
