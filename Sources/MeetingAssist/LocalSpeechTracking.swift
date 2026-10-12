import AVFoundation
import Combine
import CoreAudio
import MeetingCore
import Speech

struct LocalSpeechSegment: Sendable {
    let text: String
    let startedAt: Date
}

struct LocalSpeechEvent: Sendable {
    let text: String
    let final: Bool
    let startedAt: Date
    var segments: [LocalSpeechSegment] = []
    func text(after boundary: Date) -> String {
        if !segments.isEmpty {
            return segments.filter { $0.startedAt >= boundary }.map(\.text).joined(separator: " ")
        }
        return startedAt >= boundary ? text : ""
    }
    @available(macOS 26, *)
    static func decode(_ result: SpeechTranscriber.Result, began: Date) -> Self {
        let segments = result.text.runs.compactMap { run -> LocalSpeechSegment? in
            guard let range = run.audioTimeRange, CMTimeGetSeconds(range.start).isFinite else { return nil }
            return LocalSpeechSegment(
                text: String(result.text[run.range].characters),
                startedAt: began.addingTimeInterval(CMTimeGetSeconds(range.start)))
        }
        return Self(
            text: String(result.text.characters), final: result.isFinal,
            startedAt: began.addingTimeInterval(CMTimeGetSeconds(result.range.start)), segments: segments)
    }
}

@MainActor
final class SpeechInputStatus: ObservableObject {
    @Published var name = "Default microphone"
    @Published var active = false
    @Published var heard = ""
    func clear() {
        active = false
        heard = ""
    }
}

@MainActor
protocol LocalSpeechRecognizing: AnyObject {
    var activity: (@MainActor (String, Bool) -> Void)? { get set }
    func start(
        receive: @escaping @MainActor (LocalSpeechEvent) -> Void,
        failure: @escaping @MainActor (String) -> Void) async throws
    func stop()
}

/// No credentials, network transcription, or meeting-answer dependency.
@MainActor
final class LocalSpeechRecognizer: LocalSpeechRecognizing {
    var activity: (@MainActor (String, Bool) -> Void)?
    private var engine: AVAudioEngine?
    private var results: Task<Void, Never>?
    private var stopAnalysis: (() -> Void)?
    private var configurationObserver: NSObjectProtocol?
    private var run = UUID()
    func start(
        receive: @escaping @MainActor (LocalSpeechEvent) -> Void,
        failure: @escaping @MainActor (String) -> Void
    ) async throws {
        stop()
        guard #available(macOS 26, *) else {
            throw MeetingError.message("Local speech following requires macOS 26 or newer.")
        }
        let id = run
        guard await AVCaptureDevice.requestAccess(for: .audio) else {
            throw MeetingError.message(
                "Microphone access denied. Allow Meetly in System Settings → Privacy & Security → Microphone."
            )
        }
        guard id == run, !Task.isCancelled else { throw CancellationError() }
        let locale = Locale(identifier: "en-US")
        guard SpeechTranscriber.isAvailable,
            let supported = await SpeechTranscriber.supportedLocale(equivalentTo: locale)
        else {
            throw MeetingError.message("On-device English transcription is unavailable on this Mac.")
        }
        let transcriber = SpeechTranscriber(locale: supported, preset: .timeIndexedProgressiveTranscription)
        if let assets = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await assets.downloadAndInstall()
        }
        guard id == run, !Task.isCancelled else { throw CancellationError() }
        let audio = AVAudioEngine()
        let natural = audio.inputNode.outputFormat(forBus: 0)
        guard natural.sampleRate > 0, natural.channelCount > 0,
            let format = await SpeechAnalyzer.bestAvailableAudioFormat(
                compatibleWith: [transcriber], considering: natural),
            let converter = AVAudioConverter(from: natural, to: format)
        else {
            throw MeetingError.message("Microphone format unavailable. Reconnect your headphones and retry.")
        }
        converter.primeMethod = .none
        let pair = AsyncStream<AnalyzerInput>.makeStream(bufferingPolicy: .bufferingOldest(8))
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        try await analyzer.prepareToAnalyze(in: format)
        guard id == run, !Task.isCancelled else {
            await analyzer.cancelAndFinishNow()
            throw CancellationError()
        }
        let began = Date()
        // The input-node tap is serialized; converter state stays on this audio callback.
        let inputName = Self.inputName()
        activity?(inputName, false)
        var meterBuffers = 0
        var samples: Int64 = 0
        audio.inputNode.installTap(onBus: 0, bufferSize: 2048, format: natural) { buffer, _ in
            meterBuffers += 1
            if meterBuffers >= 8 {
                meterBuffers = 0
                let level = Self.hasSignal(buffer)
                Task { @MainActor in if self.run == id { self.activity?(inputName, level) } }
            }
            let capacity = AVAudioFrameCount(
                ceil(Double(buffer.frameLength) * format.sampleRate / natural.sampleRate) + 32)
            guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return }
            var supplied = false
            var conversionError: NSError?
            converter.convert(to: output, error: &conversionError) { _, state in
                guard !supplied else {
                    state.pointee = .noDataNow
                    return nil
                }
                supplied = true
                state.pointee = .haveData
                return buffer
            }
            guard conversionError == nil, output.frameLength > 0 else {
                Task { @MainActor in
                    if self.run == id { failure("Microphone conversion failed. Retry speech following.") }
                }
                return
            }
            let time = CMTime(value: samples, timescale: CMTimeScale(format.sampleRate))
            samples += Int64(output.frameLength)
            if case .dropped = pair.continuation.yield(AnalyzerInput(buffer: output, bufferStartTime: time)) {
                Task { @MainActor in if self.run == id { failure("Speech following is overloaded. Retry.") } }
            }
        }
        engine = audio
        stopAnalysis = {
            pair.continuation.finish()
            Task { await analyzer.cancelAndFinishNow() }
        }
        results = Task {
            do {
                for try await result in transcriber.results {
                    guard self.run == id, !Task.isCancelled else { return }
                    receive(LocalSpeechEvent.decode(result, began: began))
                }
                if self.run == id, !Task.isCancelled { failure("Local speech stream ended. Retry.") }
            } catch {
                if self.run == id, !Task.isCancelled { failure("Local speech recognition stopped. Retry.") }
            }
        }
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: audio, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard self?.run == id else { return }
                failure("Microphone changed. Retry speech following.")
            }
        }
        do {
            try await analyzer.start(inputSequence: pair.stream)
            guard id == run, !Task.isCancelled else { throw CancellationError() }
            try audio.start()
        } catch {
            if id == run { stop() }
            throw error
        }
    }
    nonisolated static func hasSignal(_ buffer: AVAudioPCMBuffer) -> Bool {
        guard let channels = buffer.floatChannelData, buffer.frameLength > 0 else { return false }
        var sum: Float = 0
        for index in 0..<Int(buffer.frameLength) { sum += channels[0][index] * channels[0][index] }
        return sqrt(sum / Float(buffer.frameLength)) > 0.008
    }
    private static func inputName() -> String {
        var device: AudioDeviceID = 0
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var property = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        guard
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject), &property, 0, nil, &size, &device) == noErr
        else { return "Default microphone" }
        var name: CFString = "Default microphone" as CFString
        size = UInt32(MemoryLayout<CFString>.size)
        property.mSelector = kAudioObjectPropertyName
        let result = withUnsafeMutablePointer(to: &name) {
            AudioObjectGetPropertyData(device, &property, 0, nil, &size, $0)
        }
        guard result == noErr else {
            return "Default microphone"
        }
        return name as String
    }
    func stop() {
        run = UUID()
        results?.cancel()
        results = nil
        if let configurationObserver { NotificationCenter.default.removeObserver(configurationObserver) }
        configurationObserver = nil
        engine?.stop()
        engine?.inputNode.removeTap(onBus: 0)
        engine = nil
        stopAnalysis?()
        stopAnalysis = nil
    }
}

@MainActor
final class SpeechFollowingController: ObservableObject {
    @Published private(set) var enabled = false
    @Published private(set) var starting = false
    @Published private(set) var status = ""
    @Published private(set) var issue = false
    @Published private(set) var progress = SpeechProgress()
    @Published private(set) var document = SpeechDocument("")
    @Published private(set) var suspendedForReadAloud = false
    let inputStatus = SpeechInputStatus()
    private let recognizer: any LocalSpeechRecognizing
    private let now: () -> Date
    private var startTask: Task<Void, Never>?
    private var run = UUID()
    private var acceptAfter = Date.distantPast
    private var answerID: UUID?
    private var answer = ""
    private var documentTask: Task<Void, Never>?
    private var documentRevision = UUID()
    private var positions: [UUID: SpeechProgress] = [:]
    private var order: [UUID] = []
    private var speakingObserver: AnyCancellable?
    init(recognizer: (any LocalSpeechRecognizing)? = nil, now: @escaping () -> Date = Date.init) {
        self.recognizer = recognizer ?? LocalSpeechRecognizer()
        self.now = now
        self.recognizer.activity = { [weak self] name, active in
            guard let self, self.enabled else { return }
            self.inputStatus.name = name
            self.inputStatus.active = active
        }
    }
    func observeReadAloud(_ speech: AnswerSpeechController) {
        speakingObserver = speech.$speaking.removeDuplicates().sink { [weak self] speaking in
            self?.setReadAloud(speaking)
        }
    }
    func setReadAloud(_ speaking: Bool) {
        suspendedForReadAloud = speaking
        acceptAfter = now()
        if enabled { updateStatus() }
    }
    func setAnswer(id: UUID?, text: String) {
        if id != answerID {
            savePosition()
            answerID = id
            if answer != text { document = SpeechDocument("") }
            progress = id.flatMap { positions[$0] } ?? SpeechProgress()
            acceptAfter = now()
        }
        guard answer != text else { return }
        answer = text
        documentTask?.cancel()
        documentRevision = UUID()
        let revision = documentRevision
        let worker = Task.detached(priority: .utility) { SpeechDocument(text) }
        documentTask = Task {
            let prepared = await withTaskCancellationHandler {
                await worker.value
            } onCancel: {
                worker.cancel()
            }
            guard !Task.isCancelled, documentRevision == revision else { return }
            document = prepared
            progress.covered = progress.covered.filter { prepared.passages.indices.contains($0) }
            if let current = progress.current, !prepared.passages.indices.contains(current) {
                progress.current = nil
            }
            if enabled { updateStatus() }
        }
        if enabled { updateStatus() }
    }
    func setEnabled(_ value: Bool) {
        stop()
        guard value else { return }
        enabled = true
        starting = true
        status = "Preparing local speech model…"
        let id = run
        startTask = Task {
            do {
                try await recognizer.start(
                    receive: { [weak self] event in
                        guard let self, self.run == id else { return }
                        self.receive(event)
                    },
                    failure: { [weak self] message in
                        guard let self, self.run == id else { return }
                        self.fail(message)
                    })
                guard run == id, !Task.isCancelled else { return }
                starting = false
                updateStatus()
            } catch {
                guard run == id, !Task.isCancelled else { return }
                fail(SecretRedactor.clean(error.localizedDescription))
            }
        }
    }
    func receive(_ event: LocalSpeechEvent) {
        guard enabled, !starting, !suspendedForReadAloud,
            answerID != nil, !document.passages.isEmpty
        else { return }
        let text = event.text(after: acceptAfter).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        inputStatus.heard = String(text.suffix(100))
        var next = progress
        next.receive(text, final: event.final, document: document)
        guard next != progress else { return }
        progress = next
        savePosition()
        updateStatus()
    }
    func pauseScrolling() {
        guard enabled, !progress.manualPause else { return }
        progress.manualPause = true
        savePosition()
        updateStatus()
    }
    func resume() {
        progress.manualPause = false
        acceptAfter = now()
        savePosition()
        updateStatus()
    }
    func resetProgress() {
        progress = SpeechProgress()
        acceptAfter = now()
        savePosition()
        updateStatus()
    }
    func clear() {
        stop()
        positions = [:]
        order = []
        answerID = nil
        answer = ""
        documentTask?.cancel()
        documentRevision = UUID()
        progress = SpeechProgress()
        document = SpeechDocument("")
    }
    func stop() {
        run = UUID()
        startTask?.cancel()
        startTask = nil
        recognizer.stop()
        inputStatus.clear()
        enabled = false
        starting = false
        issue = false
        status = ""
        acceptAfter = now()
    }
    private func fail(_ message: String) {
        stop()
        issue = true
        status = message
    }
    private func savePosition() {
        guard let answerID else { return }
        positions[answerID] = progress
        if !order.contains(answerID) { order.append(answerID) }
        if order.count > 10 { positions.removeValue(forKey: order.removeFirst()) }
    }
    private func updateStatus() {
        if suspendedForReadAloud {
            status = "Following paused while Meetly reads aloud"
        } else if progress.manualPause {
            status = "Auto-scroll held · speech still follows"
        } else if answerID == nil {
            status = "Local microphone on · waiting for an answer"
        } else if document.passages.isEmpty {
            status = "Preparing passage tracking · answer remains available"
        } else if progress.uncertain {
            status = "Tracking uncertain · holding position"
        } else {
            status =
                progress.current.map {
                    "Following your speech locally · passage \($0 + 1)/\(document.passages.count)"
                }
                ?? "Following your speech locally · waiting for a match"
        }
    }
}
