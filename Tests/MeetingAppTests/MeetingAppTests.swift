import AVFoundation
import Combine
import MeetingCore
import XCTest

@testable import MeetingAssist

final class MockHTTP: URLProtocol {
    static var status = 200
    static var payload = ""
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let response = HTTPURLResponse(
            url: request.url!, statusCode: Self.status, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "text/event-stream"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        // Split within JSON and UTF-8 characters: the client must handle transport framing.
        let bytes = Array(Self.payload.utf8)
        for i in stride(from: 0, to: bytes.count, by: 7) {
            client?.urlProtocol(self, didLoad: Data(bytes[i..<min(i + 7, bytes.count)]))
        }
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

final class MeetingAppTests: XCTestCase {
    @MainActor
    func testCredentialReadsAreSharedAndCacheResets() async throws {
        var reads = 0
        let credentials = CredentialAccess {
            reads += 1
            await Task.yield()
            return "test-only"
        }
        async let first = credentials.load()
        async let second = credentials.load()
        let values = try await (first, second)
        XCTAssertEqual(values.0, "test-only")
        XCTAssertEqual(values.1, "test-only")
        XCTAssertEqual(reads, 1)
        credentials.replace(with: "replacement-only")
        let replacement = try await credentials.load()
        XCTAssertEqual(replacement, "replacement-only")
        XCTAssertEqual(reads, 1)
        credentials.replace(with: nil)
        let reloaded = try await credentials.load()
        XCTAssertEqual(reloaded, "test-only")
        XCTAssertEqual(reads, 2)
    }
    @MainActor
    func testCredentialRemovalCannotRestoreAnOldRead() async throws {
        let started = expectation(description: "credential read started")
        var pending: CheckedContinuation<String?, Error>?
        let credentials = CredentialAccess {
            try await withCheckedThrowingContinuation { continuation in
                pending = continuation
                started.fulfill()
            }
        }
        let old = Task { try await credentials.load() }
        await fulfillment(of: [started], timeout: 2)
        credentials.replace(with: "new-test-only")
        pending?.resume(returning: "old-test-only")
        do {
            _ = try await old.value
            XCTFail("Invalidated credentials must not be returned")
        } catch { XCTAssertTrue(error is CancellationError) }
        let key = try await credentials.load()
        XCTAssertEqual(key, "new-test-only")
    }
    @MainActor
    func testGlobalAnswerIgnoresStaleTypedQuestion() async {
        let model = MeetingModel()
        model.hasKey = false
        model.question = "old typed question"
        model.answerLatest(useTyped: false)
        XCTAssertTrue(model.error?.contains("Enter a question") ?? false)
        model.answerLatest(useTyped: true)
        XCTAssertTrue(model.showSettings)
    }
    private func session(status: Int = 200, payload: String) -> URLSession {
        MockHTTP.status = status
        MockHTTP.payload = payload
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockHTTP.self]
        return URLSession(configuration: config)
    }
    @MainActor
    func testAnswerStreamingWithRealURLSessionFraming() async throws {
        let http = session(
            payload: """
                event: response.output_text.delta
                data: {"type":"response.output_text.delta","delta":"SAY THIS: café"}

                data: {"type":"response.output_text.delta","delta":". EXAMPLE: Java."}

                data: {"type":"response.completed"}


                """)
        defer { http.invalidateAndCancel() }
        var text = ""
        try await AnswerService.stream(
            key: "test-only", model: "gpt-6-luna", question: "Explain DI", context: "",
            background: "Java", expanded: false, session: http
        ) {
            MainActor.assertIsolated()
            text += $0
        }
        XCTAssertEqual(text, "SAY THIS: café. EXAMPLE: Java.")
    }
    @MainActor
    func testStreamEndingWithoutCompletedEventFails() async {
        let http = session(
            payload: "data: {\"type\":\"response.output_text.delta\",\"delta\":\"partial\"}\n\n")
        defer { http.invalidateAndCancel() }
        do {
            try await AnswerService.stream(
                key: "test-only", model: "gpt-6-luna", question: "Explain DI", context: "", background: "",
                expanded: false, session: http
            ) { _ in }
            XCTFail("Truncated stream should fail")
        } catch { XCTAssertTrue(error.localizedDescription.contains("ended early")) }
    }
    @MainActor
    func testAPIQuotaErrorIsActionableAndBodyNotDisplayed() async {
        let http = session(status: 429, payload: "private body that must not appear")
        defer { http.invalidateAndCancel() }
        do {
            try await AnswerService.stream(
                key: "test-only", model: "gpt-6-luna", question: "Explain DI", context: "", background: "",
                expanded: false, session: http
            ) { _ in XCTFail("Must not yield text") }
            XCTFail("Quota failure should throw")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("billing"))
            XCTAssertFalse(error.localizedDescription.contains("private body"))
        }
    }
    @MainActor
    func testIncompleteModelOutputIsNotReportedAsFinished() async {
        let http = session(payload: "data: {\"type\":\"response.incomplete\"}\n\n")
        defer { http.invalidateAndCancel() }
        do {
            try await AnswerService.stream(
                key: "test-only", model: "gpt-6-luna", question: "Explain DI", context: "", background: "",
                expanded: false, session: http
            ) { _ in }
            XCTFail("Incomplete response should throw")
        } catch { XCTAssertTrue(error.localizedDescription.contains("cut short")) }
    }
    @MainActor
    func testWhitespaceOnlyCompletedStreamFails() async {
        let http = session(
            payload:
                "data: {\"type\":\"response.output_text.delta\",\"delta\":\"  \\n\"}\n\ndata: {\"type\":\"response.completed\"}\n\n"
        )
        defer { http.invalidateAndCancel() }
        do {
            try await AnswerService.stream(
                key: "test-only", model: "gpt-6-luna", question: "Explain DI", context: "", background: "",
                expanded: false, session: http
            ) { _ in }
            XCTFail("Whitespace must not be marked as an answer")
        } catch { XCTAssertTrue(error.localizedDescription.contains("ended early")) }
    }
    @MainActor
    func testDemoAndClearNeverStartRecordingOrNetwork() async {
        let model = MeetingModel()
        model.preview()
        XCTAssertTrue(model.demo)
        XCTAssertFalse(model.listening)
        XCTAssertFalse(model.connecting)
        XCTAssertEqual(model.cards.count, 1)
        XCTAssertTrue(model.cards[0].answer.contains("EXAMPLE:"))
        model.clear()
        XCTAssertTrue(model.turns.isEmpty)
        XCTAssertTrue(model.cards.isEmpty)
        XCTAssertFalse(model.demo)
    }
    @MainActor
    func testMissingKeyOpensSettingsInsteadOfConnecting() async {
        let model = MeetingModel()
        model.hasKey = false
        model.start()
        XCTAssertTrue(model.showSettings)
        XCTAssertFalse(model.connecting)
        XCTAssertFalse(model.listening)
        model.showSettings = false
        model.question = "Explain Spring DI"
        model.answerLatest()
        XCTAssertTrue(model.showSettings)
        XCTAssertFalse(model.answering)
    }
    @MainActor
    func testStartNeedsNoAppDiscoveryOrSelection() async {
        let loaded = expectation(description: "one-click start reaches credential lookup")
        let model = MeetingModel(
            credentials: CredentialAccess {
                loaded.fulfill()
                return nil
            })
        model.hasKey = true
        let failed = expectation(description: "missing saved credential is surfaced")
        let observer = model.$error.compactMap { $0 }.sink { text in
            XCTAssertTrue(text.contains("Save an API key"))
            failed.fulfill()
        }
        model.start()
        await fulfillment(of: [loaded, failed], timeout: 2)
        XCTAssertFalse(model.connecting)
        XCTAssertFalse(model.listening)
        withExtendedLifetime(observer) {}
    }
    @MainActor
    func testClearingWhileListeningIsBlocked() async {
        let model = MeetingModel()
        model.preview()
        model.listening = true
        model.clear()
        XCTAssertEqual(model.cards.count, 1)
        XCTAssertTrue(model.error?.contains("Stop listening") ?? false)
        model.stop()
    }
    func testKeychainIsolatedAccountLifecycle() async throws {
        let account = "unit-test-" + UUID().uuidString
        defer { try? Keychain.delete(account: account) }
        XCTAssertNil(try Keychain.read(account: account))
        XCTAssertFalse(Keychain.contains(account: account))
        try Keychain.save("sk-test-abcdefghijklmnop", account: account)
        XCTAssertTrue(Keychain.contains(account: account))
        let asyncKey = try await Keychain.readAsync(account: account)
        XCTAssertEqual(asyncKey, "sk-test-abcdefghijklmnop")
        XCTAssertEqual(try Keychain.read(account: account), "sk-test-abcdefghijklmnop")
        try Keychain.save("sk-test-replacementabcdefg", account: account)
        XCTAssertEqual(try Keychain.read(account: account), "sk-test-replacementabcdefg")
        try Keychain.delete(account: account)
        XCTAssertNil(try Keychain.read(account: account))
        XCTAssertFalse(Keychain.contains(account: account))
        XCTAssertThrowsError(try Keychain.save("bad", account: account))
    }
    func testStereo48KAudioConvertsToMono24KPCM16() throws {
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: 48000, channels: 2, interleaved: false)!
        let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4800)!
        pcm.frameLength = 4800
        for channel in 0..<2 { for i in 0..<4800 { pcm.floatChannelData![channel][i] = 0.1 } }
        var description: CMAudioFormatDescription?
        XCTAssertEqual(
            CMAudioFormatDescriptionCreate(
                allocator: nil, asbd: format.streamDescription, layoutSize: 0, layout: nil,
                magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &description),
            noErr)
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: 48000), presentationTimeStamp: .zero,
            decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        XCTAssertEqual(
            CMSampleBufferCreate(
                allocator: nil, dataBuffer: nil, dataReady: false, makeDataReadyCallback: nil, refcon: nil,
                formatDescription: description, sampleCount: 4800, sampleTimingEntryCount: 1,
                sampleTimingArray: &timing, sampleSizeEntryCount: 0, sampleSizeArray: nil,
                sampleBufferOut: &sample), noErr)
        let buffer = try XCTUnwrap(sample)
        XCTAssertEqual(
            CMSampleBufferSetDataBufferFromAudioBufferList(
                buffer, blockBufferAllocator: nil, blockBufferMemoryAllocator: nil, flags: 0,
                bufferList: pcm.audioBufferList), noErr)
        XCTAssertEqual(CMSampleBufferSetDataReady(buffer), noErr)
        let frame = try AudioCapture.convert(buffer, microphone: false)
        XCTAssertFalse(frame.microphone)
        XCTAssertEqual(frame.pcm.count, 4800)
        XCTAssertEqual(frame.seconds, 0.1, accuracy: 0.003)
        XCTAssertEqual(frame.rms, 0.1, accuracy: 0.01)
        // Live conversion must retain leftover frames, not discard the resampler tail per chunk.
        let streamingConverter = PCMConverter()
        var streamedBytes = 0
        for _ in 0..<20 {
            streamedBytes += try AudioCapture.convert(
                buffer, microphone: false,
                converterStore: streamingConverter
            ).pcm.count
        }
        XCTAssertLessThanOrEqual(streamedBytes, 20 * 4800)
        XCTAssertGreaterThanOrEqual(streamedBytes, 20 * 4800 - 4096)
    }
}
