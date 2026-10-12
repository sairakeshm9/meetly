import AVFoundation
import AudioToolbox
import Foundation
import MeetingCore

enum SpeechProvider: String, CaseIterable, Identifiable {
    case mac, api
    var id: String { rawValue }
    var label: String { self == .mac ? "Mac · Free, offline" : "API · Natural, paid" }
}

enum APIVoiceMode: String, CaseIterable, Identifiable {
    case realtime, budget
    var id: String { rawValue }
    var label: String { self == .realtime ? "Realtime Mini · Live streaming" : "Mini TTS · Budget" }
}

enum APISpeechRequest {
    static let voices = ["marin", "coral", "shimmer"]
    static let realtimeModel = "gpt-realtime-2.1-mini"
    static let model = "gpt-4o-mini-tts-2025-12-15"
    static func make(text: String, voice: String, pace: Double, key: String, realtime: Bool = false) throws
        -> URLRequest
    {
        guard !key.isEmpty else { throw MeetingError.message("API key missing. Add it in Meetly Settings.") }
        guard voices.contains(voice), !text.isEmpty, text.count <= 1800 else {
            throw MeetingError.message("Invalid voice or speech text.")
        }
        var request = URLRequest(
            url: URL(
                string: realtime
                    ? "wss://api.openai.com/v1/realtime?model=gpt-realtime-2.1-mini"
                    : "https://api.openai.com/v1/audio/speech")!)
        request.httpMethod = realtime ? "GET" : "POST"
        request.timeoutInterval = 20
        request.setValue("Bearer " + key, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": realtime ? realtimeModel : model, "voice": voice, "input": text,
            "response_format": "pcm",
            "speed": SpeechPace.normalized(pace),
            "instructions":
                "Speak in natural American English, like a helpful woman explaining to a colleague. Use relaxed conversational intonation and short pauses between ideas. Clearly pronounce technical terms. Read only the supplied text; do not add words.",
        ])
        return request
    }
    static func chunks(_ text: String) -> [String] {
        var chunks: [String] = []
        for paragraph in AnswerSpeechText.paragraphs(text) {
            if let last = chunks.last, last.count + paragraph.count + 1 <= 1800 {
                chunks[chunks.count - 1] = last + "\n" + paragraph
            } else {
                chunks.append(paragraph)
            }
        }
        return chunks
    }
    static func failure(status: Int) -> String {
        switch status {
        case 401, 403: return "API voice key/access rejected. Check Meetly Settings."
        case 429: return "API voice quota or rate limit reached."
        default: return "API voice unavailable (HTTP \(status))."
        }
    }
}

// Run byte collection off the UI actor; deliver 100 ms PCM blocks without waiting for the full file.
struct APISpeechStream {
    let session: URLSession
    init(session: URLSession = .shared) { self.session = session }
    func stream(_ request: URLRequest, receive: @escaping (Data) async throws -> Void) async throws {
        if request.url?.scheme == "wss" {
            try await RealtimeSpeechStream(session: session).stream(request, receive: receive)
            return
        }
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw MeetingError.message(
                APISpeechRequest.failure(status: (response as? HTTPURLResponse)?.statusCode ?? 0))
        }
        let type = http.value(forHTTPHeaderField: "Content-Type")?.lowercased() ?? ""
        guard type.contains("audio/") || type.contains("octet-stream") else {
            throw MeetingError.message("API voice returned an unexpected audio format.")
        }
        var block = Data()
        var total = 0
        for try await byte in bytes {
            try Task.checkCancellation()
            block.append(byte)
            total += 1
            guard total <= 8_640_000 else {
                throw MeetingError.message("API voice exceeded the playback limit.")
            }
            if block.count == 4800 {
                try await receive(block)
                block.removeAll(keepingCapacity: true)
            }
        }
        guard total > 0, total.isMultiple(of: 2) else {
            throw MeetingError.message("API voice audio was empty or incomplete.")
        }
        if !block.isEmpty { try await receive(block) }
    }
}

@MainActor
protocol SpeechPCMPlayback: AnyObject {
    func append(_ pcm: Data) throws
    func appendNative(_ pcm: AVAudioPCMBuffer) throws
    func finish(_ completion: @escaping () -> Void)
    func stop()
}

@MainActor
final class NativeSpeechPCMPlayback: SpeechPCMPlayback {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let apiFormat = AVAudioFormat(standardFormatWithSampleRate: 24000, channels: 1)!
    private var format: AVAudioFormat?
    private let output: () -> AudioOutput
    private var device: UInt32 = 0
    private var running = false
    private var run = UUID()
    init(output: @escaping () -> AudioOutput = AudioOutput.preferredHeadphones) {
        self.output = output
        engine.attach(player)
    }
    static func samples(_ data: Data) -> [Float] {
        guard data.count.isMultiple(of: 2) else { return [] }
        let bytes = Array(data)
        return stride(from: 0, to: bytes.count, by: 2).map {
            Float(Int16(bitPattern: UInt16(bytes[$0]) | UInt16(bytes[$0 + 1]) << 8)) / 32768
        }
    }
    func append(_ pcm: Data) throws {
        let samples = Self.samples(pcm)
        guard !samples.isEmpty,
            let buffer = AVAudioPCMBuffer(
                pcmFormat: apiFormat, frameCapacity: AVAudioFrameCount(samples.count)),
            let channel = buffer.floatChannelData?[0]
        else { throw MeetingError.message("Cannot prepare API voice playback.") }
        buffer.frameLength = buffer.frameCapacity
        for (index, sample) in samples.enumerated() { channel[index] = sample }
        try appendNative(buffer)
    }
    func appendNative(_ buffer: AVAudioPCMBuffer) throws {
        let route = output()
        guard route.headphoneLike, route.id != 0 else {
            throw MeetingError.message("Connect headphones for Meetly audio.")
        }
        if !running {
            // Route only this app's engine. Do not change the Mac's default output for other apps.
            guard let unit = engine.outputNode.audioUnit else {
                throw MeetingError.message("Cannot open Meetly audio output.")
            }
            var selected = route.id
            guard
                AudioUnitSetProperty(
                    unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &selected,
                    UInt32(MemoryLayout<UInt32>.size)) == noErr
            else {
                throw MeetingError.message(
                    "Cannot route Meetly to connected headphones. Select them in Mac Sound settings.")
            }
            device = route.id
            format = buffer.format
            engine.connect(player, to: engine.mainMixerNode, format: buffer.format)
            try engine.start()
            running = true
        }
        guard device == route.id, format == buffer.format else {
            throw MeetingError.message("Headphone output changed; playback stopped.")
        }
        player.scheduleBuffer(buffer)
        if !player.isPlaying { player.play() }
    }
    static func copy(_ source: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let result = AVAudioPCMBuffer(pcmFormat: source.format, frameCapacity: source.frameLength)
        else { return nil }
        result.frameLength = source.frameLength
        let input = UnsafeMutableAudioBufferListPointer(source.mutableAudioBufferList)
        let output = UnsafeMutableAudioBufferListPointer(result.mutableAudioBufferList)
        for (from, to) in zip(input, output) {
            guard let src = from.mData, let dst = to.mData else { return nil }
            memcpy(dst, src, Int(from.mDataByteSize))
        }
        return result
    }
    func finish(_ completion: @escaping () -> Void) {
        guard running, let format, let tail = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1) else {
            completion()
            return
        }
        tail.frameLength = 1
        for channel in UnsafeMutableAudioBufferListPointer(tail.mutableAudioBufferList) {
            if let pointer = channel.mData { memset(pointer, 0, Int(channel.mDataByteSize)) }
        }
        let token = run
        player.scheduleBuffer(tail, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.run == token else { return }
                self.stop()
                completion()
            }
        }
    }
    func stop() {
        run = UUID()
        player.stop()
        engine.stop()
        running = false
        format = nil
        engine.disconnectNodeOutput(player)
    }
}

@MainActor
final class SelectableAnswerSpeechEngine: AnswerSpeechEngine {
    var notice: ((String) -> Void)?
    var fallbackVoiceID: String?
    private let native: any AnswerSpeechEngine
    private let playback: any SpeechPCMPlayback
    private let key: () async throws -> String?
    private let stream: (URLRequest, @escaping (Data) async throws -> Void) async throws -> Void
    private var task: Task<Void, Never>?
    private var run = UUID()
    init(
        key: @escaping () async throws -> String?, native: (any AnswerSpeechEngine)? = nil,
        playback: (any SpeechPCMPlayback)? = nil,
        stream: @escaping (URLRequest, @escaping (Data) async throws -> Void) async throws -> Void = {
            request, receive in
            try await APISpeechStream().stream(request, receive: receive)
        }
    ) {
        self.key = key
        self.native = native ?? NativeAnswerSpeechEngine()
        self.playback = playback ?? NativeSpeechPCMPlayback()
        self.stream = stream
        if let local = self.native as? NativeAnswerSpeechEngine {
            local.notice = { [weak self] message in self?.notice?(message) }
        }
    }
    func speak(_ text: String, voiceID: String, rate: Float, finished: @escaping () -> Void) {
        stop()
        guard voiceID.hasPrefix("api:") || voiceID.hasPrefix("realtime:") else {
            native.speak(text, voiceID: voiceID, rate: rate, finished: finished)
            return
        }
        let token = run
        let realtime = voiceID.hasPrefix("realtime:")
        let voice = String(voiceID.split(separator: ":").last ?? "marin")
        task = Task { [weak self] in
            guard let self else { return }
            var started = false
            do {
                let credential = try await key() ?? ""
                try Task.checkCancellation()
                for paragraph in APISpeechRequest.chunks(text) {
                    let request = try APISpeechRequest.make(
                        text: paragraph, voice: voice, pace: Double(rate) / 0.48, key: credential,
                        realtime: realtime)
                    try await stream(request) { [weak self] data in
                        try await MainActor.run {
                            guard let self, self.run == token, !Task.isCancelled else {
                                throw CancellationError()
                            }
                            try self.playback.append(data)
                            started = true
                        }
                    }
                }
                guard run == token, !Task.isCancelled else { return }
                playback.finish { [weak self] in
                    guard self?.run == token else { return }
                    finished()
                }
            } catch {
                guard run == token, !Task.isCancelled else { return }
                playback.stop()
                // Never replay an explanation after a partially audible stream fails.
                let reason = (error as? MeetingError)?.localizedDescription ?? "API voice connection failed."
                if !started, let fallbackVoiceID {
                    notice?(reason + " Using Mac voice for this answer.")
                    native.speak(text, voiceID: fallbackVoiceID, rate: rate, finished: finished)
                } else {
                    notice?(
                        reason
                            + (started
                                ? " Playback stopped; preview to retry." : " Choose an installed Mac voice."))
                    finished()
                }
            }
        }
    }
    func stop() {
        run = UUID()
        task?.cancel()
        task = nil
        native.stop()
        playback.stop()
    }
}
