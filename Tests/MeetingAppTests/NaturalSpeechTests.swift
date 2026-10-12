import AVFoundation
import AppKit
import CoreAudio
import Foundation
import MeetingCore
import XCTest

@testable import MeetingAssist

@MainActor
final class NaturalSpeechTests: XCTestCase {
    func testRepeatedOutputNotificationsDoNotReattachCoreAudioListeners() {
        var devices: [AudioDeviceID] = [1, 2]
        var added = 0
        var removed = 0
        let monitor = AudioOutputMonitor(
            deviceIDs: { devices },
            add: { _, _, _ in
                added += 1
                return noErr
            }, remove: { _, _, _ in removed += 1 })
        monitor.start(device: 1, changed: {})
        let initial = added
        for _ in 0..<100 { monitor.start(device: 1, changed: {}) }
        XCTAssertEqual(added, initial)
        XCTAssertEqual(removed, 0)
        devices.append(3)
        monitor.start(device: 1, changed: {})
        XCTAssertGreaterThan(added, initial)
        XCTAssertEqual(removed, initial)
        monitor.stop()
        XCTAssertEqual(added, removed)
    }
    func testMenuBarIconIsSmallMonochromeLeafWithNoColoredTile() throws {
        let menu = AppIcon.menuBarImage()
        XCTAssertEqual(menu.size, NSSize(width: 18, height: 18))
        XCTAssertTrue(menu.isTemplate)
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(menu.tiffRepresentation)))
        let pixel = try XCTUnwrap(bitmap.colorAt(x: 0, y: 0))
        let rgb = try XCTUnwrap(pixel.usingColorSpace(.deviceRGB))
        XCTAssertEqual(rgb.alphaComponent, 0)
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide {
                let color = try XCTUnwrap(bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB))
                guard color.alphaComponent > 0 else { continue }
                XCTAssertEqual(color.redComponent, color.greenComponent, accuracy: 0.01)
                XCTAssertEqual(color.greenComponent, color.blueComponent, accuracy: 0.01)
            }
        }
    }
    func testSharedBrandMarkKeepsWhiteSymbolAndTransparentCornersInBothThemes() throws {
        for theme in [NSAppearance.Name.aqua, .darkAqua] {
            let appearance = try XCTUnwrap(NSAppearance(named: theme))
            var data: Data?
            appearance.performAsCurrentDrawingAppearance {
                data = BrandMark.image(size: 64).tiffRepresentation
            }
            let bitmap = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(data)))
            XCTAssertEqual(try XCTUnwrap(bitmap.colorAt(x: 0, y: 0)).alphaComponent, 0)
            let symbol = try XCTUnwrap(bitmap.colorAt(x: 32, y: 32)?.usingColorSpace(.deviceRGB))
            XCTAssertGreaterThan(symbol.redComponent, 0.95)
            XCTAssertGreaterThan(symbol.greenComponent, 0.95)
            XCTAssertGreaterThan(symbol.blueComponent, 0.95)
        }
    }
    func testConnectedAirPodsAreChosenEvenWhenMacDefaultRemainsSpeakers() {
        let speakers = AudioOutput(id: 1, name: "MacBook Speakers", headphoneLike: false)
        let pods = AudioOutput(id: 2, name: "AirPods Pro", headphoneLike: true)
        let usb = AudioOutput(id: 3, name: "USB Audio", headphoneLike: true)
        XCTAssertEqual(
            AudioOutput.preferred(defaultOutput: speakers, connected: [usb, speakers, pods]), pods)
        XCTAssertEqual(AudioOutput.preferred(defaultOutput: usb, connected: [usb, pods]), usb)
        XCTAssertEqual(AudioOutput.preferred(defaultOutput: speakers, connected: [speakers]), speakers)
    }
    func testConnectedOutputNameUpdatesWithoutPendingAnswerAndClearsStaleWarning() {
        let domain = "Meetly.Routing.Tests.\(UUID())"
        let defaults = UserDefaults(suiteName: domain)!
        defer { defaults.removePersistentDomain(forName: domain) }
        var route = AudioOutput(id: 1, name: "Speakers", headphoneLike: false)
        let controller = AnswerSpeechController(
            engine: StubLocalSpeech(), output: { route }, monitor: nil, defaults: defaults)
        controller.preview()
        XCTAssertTrue(controller.issue)
        route = AudioOutput(id: 2, name: "AirPods", headphoneLike: true)
        controller.outputChanged()
        XCTAssertEqual(controller.outputName, "AirPods")
        XCTAssertTrue(controller.status.contains("Headphones connected"))
        XCTAssertFalse(controller.issue)
        controller.stop()
    }
    func testNativeBuffersAreOwnedCopiesBeforeAsyncPlayback() throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: 22050, channels: 1)!
        let source = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 2)!
        source.frameLength = 2
        source.floatChannelData![0][0] = 0.5
        source.floatChannelData![0][1] = -0.5
        let copy = try XCTUnwrap(NativeSpeechPCMPlayback.copy(source))
        source.floatChannelData![0][0] = 0
        XCTAssertEqual(copy.floatChannelData![0][0], 0.5)
        XCTAssertEqual(copy.floatChannelData![0][1], -0.5)
    }
    func testMacSynthesisStreamsParagraphsAndCompletesOnce() async throws {
        guard let voice = SpeechVoice.preferred(SpeechVoice.installed()) else {
            throw XCTSkip("Install a US female voice")
        }
        let playback = StubPCM()
        let engine = NativeAnswerSpeechEngine(playback: playback)
        let finished = expectation(description: "native paragraphs finish")
        engine.speak(
            "A transaction groups updates.\nBoth updates succeed together.", voiceID: voice.id, rate: 0.48
        ) { finished.fulfill() }
        await fulfillment(of: [finished], timeout: 10)
        XCTAssertGreaterThan(playback.nativeFrames, 0)
        XCTAssertEqual(playback.finishes, 1)
        engine.stop()
    }
    func testPremiumPreferredAndExplicitSelectionHasSafeFallback() {
        let standard = SpeechVoice(
            id: "standard", name: "Samantha", language: "en-US", female: true, quality: 1)
        let premium = SpeechVoice(id: "premium", name: "Ava", language: "en-US", female: true, quality: 3)
        XCTAssertEqual(SpeechVoice.preferred([standard, premium]), premium)
        XCTAssertEqual(SpeechVoice.preferred([standard, premium], selected: "standard"), standard)
        XCTAssertEqual(SpeechVoice.preferred([standard, premium], selected: "removed"), premium)
    }
    func testSpokenLabelsAndPronunciationDoNotChangeOrdinaryWordsOrCode() {
        let text = AnswerSpeechText.plain(
            "**SUMMARY:** An API groups updates.\n**EXAMPLE:** AWS runs the service.\n**ANALOGY:** Think of a bank.\n```java\nreturn privateValue;\n```"
        )
        XCTAssertTrue(text.contains("An A P I groups updates."))
        XCTAssertTrue(text.contains("For example, A W S runs the service."))
        XCTAssertTrue(text.contains("Think of it this way. Think of a bank."))
        XCTAssertFalse(text.contains("SUMMARY"))
        XCTAssertFalse(text.contains("privateValue"))
        XCTAssertEqual(
            AnswerSpeechText.natural("Answering is useful.\nApproaches differ.\nHTTP uses HTTPS."),
            "Answering is useful.\nApproaches differ.\nH T T P uses H T T P S.")
    }
    func testLongParagraphsSplitWithoutDroppingTextAndAPICombinesShortIdeas() {
        let input = String(repeating: "database ", count: 600).trimmingCharacters(in: .whitespaces)
        let chunks = AnswerSpeechText.paragraphs(input)
        XCTAssertTrue(chunks.allSatisfy { !$0.isEmpty && $0.count <= 1800 })
        XCTAssertEqual(chunks.joined(separator: " "), input)
        XCTAssertEqual(APISpeechRequest.chunks("First idea.\nSecond idea."), ["First idea.\nSecond idea."])
        XCTAssertEqual(AnswerSpeechText.paragraphs(" \n"), [])
        XCTAssertEqual(
            AnswerSpeechText.paragraphs(String(repeating: "x", count: 3601)).map(\.count), [1800, 1800, 1])
    }
    func testAPIRequestUsesStreamingPCMAndBoundedSpeed() throws {
        let request = try APISpeechRequest.make(text: "Hello", voice: "marin", pace: 9, key: "test-only")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: request.httpBody!) as? [String: Any])
        XCTAssertEqual(request.url?.host, "api.openai.com")
        XCTAssertEqual(body["response_format"] as? String, "pcm")
        XCTAssertEqual(body["model"] as? String, APISpeechRequest.model)
        XCTAssertEqual(body["speed"] as? Double, 1.5)
        XCTAssertThrowsError(
            try APISpeechRequest.make(text: "Hello", voice: "invalid", pace: 1, key: "test-only"))
        XCTAssertThrowsError(try APISpeechRequest.make(text: "Hello", voice: "marin", pace: 1, key: ""))
        XCTAssertThrowsError(
            try APISpeechRequest.make(
                text: String(repeating: "x", count: 1801), voice: "marin", pace: 1, key: "test-only"))
    }
    func testRealtimeEventsConfigureVoicePaceAndNeverUploadMicrophone() throws {
        let sessionEvent = RealtimeSpeechEvent.session(voice: "marin", pace: 1.35)
        let session = try XCTUnwrap(sessionEvent["session"] as? [String: Any])
        let audio = try XCTUnwrap(session["audio"] as? [String: Any])
        let output = try XCTUnwrap(audio["output"] as? [String: Any])
        XCTAssertEqual(output["voice"] as? String, "marin")
        XCTAssertEqual(output["speed"] as? Double, 1.35)
        XCTAssertEqual(session["output_modalities"] as? [String], ["audio"])
        let response = try XCTUnwrap(
            RealtimeSpeechEvent.response(text: "Read this text.")["response"] as? [String: Any])
        XCTAssertEqual(response["conversation"] as? String, "none")
        let pcm = Data([0, 0, 255, 127])
        XCTAssertEqual(
            try RealtimeSpeechEvent.audio([
                "type": "response.output_audio.delta", "delta": pcm.base64EncodedString(),
            ]), pcm)
        XCTAssertNil(
            try RealtimeSpeechEvent.audio(["type": "response.output_audio_transcript.delta", "delta": "text"])
        )
        XCTAssertThrowsError(
            try RealtimeSpeechEvent.audio(["type": "response.output_audio.delta", "delta": "invalid"]))
        let request = try APISpeechRequest.make(
            text: "Hello", voice: "marin", pace: 1, key: "test-only", realtime: true)
        XCTAssertEqual(request.url?.scheme, "wss")
        XCTAssertTrue(request.url?.query?.contains("gpt-realtime-2.1-mini") == true)
    }
    func testPCMLittleEndianSignedSamples() {
        XCTAssertEqual(
            NativeSpeechPCMPlayback.samples(Data([0, 0, 0, 128, 255, 127])), [0, -1, Float(32767) / 32768])
        XCTAssertEqual(NativeSpeechPCMPlayback.samples(Data([0])), [])
    }
    func testMacNeverLoadsKeyOrStartsNetwork() {
        let native = StubLocalSpeech()
        let engine = SelectableAnswerSpeechEngine(
            key: {
                XCTFail("Mac voice must not access key")
                return nil
            }, native: native, playback: StubPCM(), stream: { _, _ in XCTFail("Mac voice must not call API") }
        )
        engine.speak("Hello", voiceID: "local", rate: 0.48, finished: {})
        XCTAssertEqual(native.texts, ["Hello"])
        engine.stop()
    }
    func testStreamingStartsBeforeRequestReturnsAndCompletesAfterPlayback() async {
        let pcm = StubPCM()
        let completed = expectation(description: "completed")
        let engine = SelectableAnswerSpeechEngine(
            key: { "test-only" }, native: StubLocalSpeech(), playback: pcm,
            stream: { _, receive in
                try await receive(Data([0, 0]))
                await MainActor.run {
                    XCTAssertEqual(pcm.blocks.count, 1, "PCM delivered before network EOF")
                }
            })
        engine.speak("First.\nSecond.", voiceID: "api:marin", rate: 0.48) { completed.fulfill() }
        await fulfillment(of: [completed], timeout: 2)
        XCTAssertEqual(pcm.finishes, 1)
        engine.stop()
    }
    func testAPIFailureBeforeAudioFallsBackOnceButPartialAudioNeverRepeats() async {
        for partial in [false, true] {
            let native = StubLocalSpeech()
            let pcm = StubPCM()
            let finished = expectation(description: "failure handled")
            let engine = SelectableAnswerSpeechEngine(
                key: { "test-only" }, native: native, playback: pcm,
                stream: { _, receive in
                    if partial { try await receive(Data([0, 0])) }
                    throw MeetingError.message("API voice quota or rate limit reached.")
                })
            engine.fallbackVoiceID = "local"
            var warning = ""
            engine.notice = { warning = $0 }
            engine.speak("Explanation", voiceID: "api:marin", rate: 0.48) { finished.fulfill() }
            await fulfillment(of: [finished], timeout: 2)
            XCTAssertEqual(native.texts, partial ? [] : ["Explanation"])
            XCTAssertTrue(warning.contains(partial ? "Playback stopped" : "Using Mac voice"))
            engine.stop()
        }
    }
    func testCancelDuringAPIRequestCannotPlayLateAudioOrFinishNewRun() async {
        let pcm = StubPCM()
        let started = expectation(description: "request started")
        let ended = expectation(description: "late data rejected")
        var release: CheckedContinuation<Void, Never>?
        let engine = SelectableAnswerSpeechEngine(
            key: { "test-only" }, native: StubLocalSpeech(), playback: pcm,
            stream: { _, receive in
                await withCheckedContinuation { continuation in
                    release = continuation
                    started.fulfill()
                }
                do {
                    try await receive(Data([0, 0]))
                    XCTFail("Late data accepted")
                } catch { ended.fulfill() }
            })
        engine.speak("Old explanation", voiceID: "api:marin", rate: 0.48) {
            XCTFail("Cancelled request completed")
        }
        await fulfillment(of: [started], timeout: 2)
        engine.stop()
        release?.resume()
        await fulfillment(of: [ended], timeout: 2)
        XCTAssertTrue(pcm.blocks.isEmpty)
    }
    func testChoicePersistsAndAPIWorksWithoutInstalledMacVoice() {
        let domain = "Meetly.Voice.Tests.\(UUID())"
        let defaults = UserDefaults(suiteName: domain)!
        defer { defaults.removePersistentDomain(forName: domain) }
        let engine = StubLocalSpeech()
        let controller = AnswerSpeechController(
            engine: engine, output: { AudioOutput(id: 1, name: "Headphones", headphoneLike: true) },
            voices: { [] }, monitor: nil, defaults: defaults)
        XCTAssertEqual(controller.provider, .mac)
        controller.provider = .api
        controller.apiVoice = "coral"
        controller.read("Hello")
        XCTAssertEqual(engine.voiceIDs, ["realtime:coral"])
        let restored = AnswerSpeechController(engine: StubLocalSpeech(), monitor: nil, defaults: defaults)
        XCTAssertEqual(restored.provider, .api)
        XCTAssertEqual(restored.apiVoice, "coral")
        controller.stop()
    }
}

@MainActor
private final class StubLocalSpeech: AnswerSpeechEngine {
    var texts: [String] = []
    var voiceIDs: [String] = []
    func speak(_ text: String, voiceID: String, rate: Float, finished: @escaping () -> Void) {
        texts.append(text)
        voiceIDs.append(voiceID)
        finished()
    }
    func stop() {}
}
@MainActor
private final class StubPCM: SpeechPCMPlayback {
    var blocks: [Data] = []
    var finishes = 0
    var nativeFrames: UInt64 = 0
    func append(_ pcm: Data) throws { blocks.append(pcm) }
    func appendNative(_ pcm: AVAudioPCMBuffer) throws { nativeFrames += UInt64(pcm.frameLength) }
    func finish(_ completion: @escaping () -> Void) {
        finishes += 1
        completion()
    }
    func stop() {}
}
