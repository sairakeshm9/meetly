import Combine
import CoreAudio
import MeetingCore
import XCTest

@testable import MeetingAssist

@MainActor
final class AnswerSpeechTests: XCTestCase {
    private func isolatedDefaults() -> UserDefaults {
        let name = "Meetly.Audio.Tests.\(UUID())"
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        return defaults
    }
    private let voice = SpeechVoice(
        id: "female-us", name: "Samantha", language: "en-US", female: true, quality: 1)
    private let headset = AudioOutput(id: 42, name: "AirPods", headphoneLike: true)

    func testVoiceSelectionRequiresAmericanFemaleVoice() {
        let male = SpeechVoice(id: "male", name: "Alex", language: "en-US", female: false, quality: 3)
        let british = SpeechVoice(id: "uk", name: "UK", language: "en-GB", female: true, quality: 3)
        XCTAssertNil(SpeechVoice.preferred([male, british]))
        XCTAssertEqual(SpeechVoice.preferred([male, british, voice]), voice)
        let other = SpeechVoice(id: "aaa", name: "Other", language: "en-US", female: true, quality: 1)
        XCTAssertEqual(SpeechVoice.preferred([other, voice]), voice)
        XCTAssertEqual(SpeechVoice.preferred([voice, other]), voice)
    }

    func testReadAloudRemovesMarkupAndKeepsCodeOnScreen() {
        let text = AnswerSpeechText.plain("- **Transactions** group updates.\n\n```java\nreturn secret;\n```")
        XCTAssertTrue(text.contains("Transactions group updates."))
        XCTAssertTrue(text.contains("Code example is shown on screen."))
        XCTAssertFalse(text.contains("secret"))
        XCTAssertFalse(text.contains("**"))
        XCTAssertEqual(AnswerSpeechText.plain("  \n"), "")
    }

    func testMissingAnswerVoiceOrHeadphonesDoesNotStartAudio() {
        let engine = TestSpeechEngine()
        let empty = AnswerSpeechController(
            engine: engine, output: { self.headset }, voices: { [self.voice] }, monitor: nil,
            defaults: isolatedDefaults())
        empty.read(" ")
        XCTAssertTrue(empty.issue)
        let speakers = AnswerSpeechController(
            engine: engine, output: { .unavailable }, voices: { [self.voice] }, monitor: nil,
            defaults: isolatedDefaults())
        speakers.read("Hello")
        XCTAssertTrue(speakers.issue)
        let noVoice = AnswerSpeechController(
            engine: engine, output: { self.headset }, voices: { [] }, monitor: nil,
            defaults: isolatedDefaults())
        noVoice.read("Hello")
        XCTAssertTrue(noVoice.issue)
        XCTAssertTrue(engine.texts.isEmpty)
    }

    func testStopAndStaleCompletionCannotFinishNewPlayback() {
        let engine = TestSpeechEngine()
        let reader = AnswerSpeechController(
            engine: engine, output: { self.headset }, voices: { [self.voice] }, monitor: nil,
            defaults: isolatedDefaults())
        reader.read("First")
        let old = engine.completions[0]
        reader.read("Second")
        old()
        XCTAssertTrue(reader.speaking)
        engine.completions[1]()
        XCTAssertFalse(reader.speaking)
        reader.read("Third")
        reader.stop()
        engine.completions[2]()
        XCTAssertFalse(reader.speaking)
        XCTAssertEqual(reader.status, "")
    }

    func testOutputDisconnectStopsPlayback() {
        let engine = TestSpeechEngine()
        var route = headset
        let reader = AnswerSpeechController(
            engine: engine, output: { route }, voices: { [self.voice] }, monitor: nil,
            defaults: isolatedDefaults())
        reader.read("An answer")
        route = .unavailable
        reader.outputChanged()
        XCTAssertFalse(reader.speaking)
        XCTAssertTrue(reader.issue)
        XCTAssertTrue(reader.status.contains("Playback stopped"))
    }

    func testAutomaticModeReadsEachNewAnswerOnceAndPersistsUntilOff() {
        let saved = isolatedDefaults()
        let engine = TestSpeechEngine()
        let reader = AnswerSpeechController(
            engine: engine, output: { self.headset }, voices: { [self.voice] }, monitor: nil, defaults: saved)
        let first = UUID()
        reader.offer("Silent while off", id: first)
        XCTAssertTrue(engine.texts.isEmpty)
        reader.setEnabled(true)
        reader.offer("First answer", id: first)
        reader.offer("First answer", id: first)
        engine.completions[0]()
        reader.offer("Second answer", id: UUID())
        XCTAssertEqual(engine.texts, ["First answer", "Second answer"])
        reader.setEnabled(false)
        reader.offer("Silent after off", id: UUID())
        XCTAssertEqual(engine.texts.count, 2)
        XCTAssertFalse(reader.speaking)
        XCTAssertFalse(saved.bool(forKey: "automaticAnswerAudio"))
        reader.setEnabled(true)
        let restored = AnswerSpeechController(engine: TestSpeechEngine(), monitor: nil, defaults: saved)
        XCTAssertTrue(restored.enabled)
    }

    func testConnectingHeadphonesAutomaticallyReadsLatestWaitingAnswer() {
        let engine = TestSpeechEngine()
        var route = AudioOutput.unavailable
        let reader = AnswerSpeechController(
            engine: engine, output: { route }, voices: { [self.voice] }, monitor: nil,
            defaults: isolatedDefaults())
        reader.setEnabled(true)
        reader.offer("Old question", id: UUID())
        reader.offer("Latest follow-up", id: UUID())
        XCTAssertTrue(engine.texts.isEmpty)
        route = headset
        reader.outputChanged()
        XCTAssertEqual(engine.texts, ["Latest follow-up"])
        reader.outputChanged()
        XCTAssertEqual(engine.texts.count, 1)
        route = .unavailable
        reader.outputChanged()
        XCTAssertFalse(reader.speaking)
        XCTAssertTrue(reader.enabled)
        reader.stop()
        route = headset
        reader.outputChanged()
        XCTAssertEqual(engine.texts.count, 1, "Stopping clears pending narration")
    }

    func testPaceIsBoundedPersistedAndAppliedToCurrentAndFutureAudio() {
        let saved = isolatedDefaults()
        let engine = TestSpeechEngine()
        let reader = AnswerSpeechController(
            engine: engine, output: { self.headset }, voices: { [self.voice] }, monitor: nil, defaults: saved)
        reader.setEnabled(true)
        reader.pace = 0.65
        reader.offer("Approach explanation", id: UUID())
        XCTAssertEqual(engine.rates[0], SpeechPace.rate(0.65))
        reader.pace = 1.5
        reader.applyPace()
        XCTAssertEqual(engine.rates[1], SpeechPace.rate(1.5))
        XCTAssertGreaterThan(engine.rates[1], engine.rates[0])
        XCTAssertEqual(
            AnswerSpeechController(engine: TestSpeechEngine(), monitor: nil, defaults: saved).pace, 1.5)
        XCTAssertEqual(SpeechPace.normalized(.nan), 1)
        XCTAssertEqual(SpeechPace.normalized(-1), 0.65)
        XCTAssertEqual(SpeechPace.normalized(10), 1.5)
    }

    func testCodingNarrationKeepsApproachFollowupsAndCommentsButOmitsExecutableLines() {
        let text = AnswerSpeechText.plain(
            "Use a map for constant-time lookup.\n```java\n// Store each key once.\nMap<String, Integer> lookup = new HashMap<>();\n/* Avoid duplicate processing. */\nreturn lookup;\n```\nWhy? It avoids repeated scans."
        )
        XCTAssertTrue(text.contains("constant-time lookup"))
        XCTAssertTrue(text.contains("Store each key once."))
        XCTAssertTrue(text.contains("Avoid duplicate processing."))
        XCTAssertTrue(text.contains("avoids repeated scans"))
        XCTAssertFalse(text.contains("HashMap"))
        XCTAssertFalse(text.contains("return lookup"))
        XCTAssertEqual(
            AnswerSpeechText.codeComments(
                "String url = \"https://private\"; // Explain the lookup.\nlookup.get(key); /* Constant-time read. */"
            ), "Explain the lookup. Constant-time read.")
        XCTAssertEqual(
            AnswerSpeechText.codeComments(
                "# Explain Python.\nprint('secret')\n-- Explain SQL.\nSELECT secret;"),
            "Explain Python. Explain SQL.")
    }

    func testWiredUSBAndBluetoothRoutesAreRecognizedWithoutBrandName() {
        XCTAssertEqual(AudioOutput.displayName("Mac Speakers", source: "Mac Speakers"), "Mac Speakers")
        XCTAssertEqual(AudioOutput.displayName("Audio", source: "Headphones"), "Audio · Headphones")
        XCTAssertTrue(
            AudioOutput.isHeadphoneLike(
                name: "Generic", source: "", transport: kAudioDeviceTransportTypeBuiltIn,
                terminals: [kAudioStreamTerminalTypeHeadphones]))
        XCTAssertTrue(
            AudioOutput.isHeadphoneLike(
                name: "USB Audio", source: "", transport: kAudioDeviceTransportTypeUSB))
        XCTAssertTrue(
            AudioOutput.isHeadphoneLike(
                name: "Wireless", source: "", transport: kAudioDeviceTransportTypeBluetooth))
        XCTAssertFalse(
            AudioOutput.isHeadphoneLike(
                name: "MacBook Speakers", source: "", transport: kAudioDeviceTransportTypeBuiltIn))
    }

    func testCompletedModelAnswersAutomaticallyNarrateButFailuresDoNot() async {
        let engine = TestSpeechEngine()
        let saved = isolatedDefaults()
        let reader = AnswerSpeechController(
            engine: engine, output: { self.headset }, voices: { [self.voice] }, monitor: nil, defaults: saved)
        reader.setEnabled(true)
        let narrated = expectation(description: "answer automatically narrated")
        engine.onSpeak = { narrated.fulfill() }
        let model = MeetingModel(
            credentials: CredentialAccess { "test-only" },
            answerStreamer: { _, delta in
                delta("A transaction groups updates together.")
            }, appearanceDefaults: saved, speech: reader)
        model.hasKey = true
        model.ask("What is a transaction?")
        await fulfillment(of: [narrated], timeout: 2)
        XCTAssertEqual(engine.texts, ["A transaction groups updates together."])
        model.stop()
        XCTAssertTrue(reader.enabled, "Stopping a session does not disable the saved Audio mode")
    }

    func testFailedAnswerDoesNotStartAutomaticNarration() async {
        let engine = TestSpeechEngine()
        let saved = isolatedDefaults()
        let reader = AnswerSpeechController(
            engine: engine, output: { self.headset }, voices: { [self.voice] }, monitor: nil, defaults: saved)
        reader.setEnabled(true)
        let model = MeetingModel(
            credentials: CredentialAccess { "test-only" },
            answerStreamer: { _, delta in
                delta("Partial answer that must not be narrated")
                throw MeetingError.message("Synthetic answer failure")
            }, appearanceDefaults: saved, speech: reader)
        model.hasKey = true
        let failed = expectation(description: "failed request finishes")
        model.ask("What is a transaction?")
        let observer = model.$answering.dropFirst().sink { if !$0 { failed.fulfill() } }
        await fulfillment(of: [failed], timeout: 2)
        observer.cancel()
        XCTAssertTrue(engine.texts.isEmpty)
        XCTAssertTrue(model.activeCard?.interrupted == true)
        model.stop()
    }

    func testThemeSelectionSurvivesRestart() {
        let name = "Meetly.Theme.Tests.\(UUID())"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let model = MeetingModel(appearanceDefaults: defaults)
        model.theme = .light
        XCTAssertEqual(MeetingModel(appearanceDefaults: defaults).theme, .light)
        model.theme = .dark
        XCTAssertEqual(MeetingModel(appearanceDefaults: defaults).theme, .dark)
    }
}

@MainActor
private final class TestSpeechEngine: AnswerSpeechEngine {
    var onSpeak: (() -> Void)?
    var rates: [Float] = []
    var texts: [String] = []
    var completions: [() -> Void] = []
    func speak(_ text: String, voiceID: String, rate: Float, finished: @escaping () -> Void) {
        rates.append(rate)
        texts.append(text)
        completions.append(finished)
        onSpeak?()
    }
    func stop() {}
}
