import AVFoundation
import MeetingCore

struct SpeechVoice: Equatable {
    let id: String
    let name: String
    let language: String
    let female: Bool
    let quality: Int
    var label: String {
        "\(name) · \(quality >= 3 ? "Premium" : quality == 2 ? "Enhanced" : "Standard")"
    }
    static func preferred(_ voices: [Self], selected: String = "") -> Self? {
        if let chosen = voices.first(where: { $0.id == selected && $0.language == "en-US" && $0.female }) {
            return chosen
        }
        return voices.filter { $0.language == "en-US" && $0.female }.sorted {
            if $0.quality != $1.quality { return $0.quality > $1.quality }
            if ($0.name == "Samantha") != ($1.name == "Samantha") {
                return $0.name == "Samantha"
            }
            return $0.id < $1.id
        }.first
    }
    static func installed() -> [Self] {
        AVSpeechSynthesisVoice.speechVoices().map {
            Self(
                id: $0.identifier, name: $0.name, language: $0.language, female: $0.gender == .female,
                quality: $0.quality.rawValue)
        }
    }
}

enum SpeechPace {
    static func normalized(_ value: Double) -> Double {
        value.isFinite ? min(1.5, max(0.65, value)) : 1
    }
    static func rate(_ multiplier: Double) -> Float {
        Float(0.48 * normalized(multiplier))
    }
}

enum AnswerSpeechText {
    // Ignore quoted literals and executable text; retain standalone and inline comments.
    static func codeComments(_ code: String) -> String {
        var inBlock = false
        var comments: [String] = []
        for line in code.components(separatedBy: .newlines) {
            let characters = Array(line)
            var index = 0
            var quote: Character?
            var comment = ""
            while index < characters.count {
                let character = characters[index]
                let next: Character? = index + 1 < characters.count ? characters[index + 1] : nil
                if inBlock {
                    if character == "*", next == "/" {
                        inBlock = false
                        index += 2
                        comment += " "
                        continue
                    }
                    comment.append(character)
                } else if let quoted = quote {
                    if character == "\\" {
                        index += 2
                        continue
                    }
                    if character == quoted { quote = nil }
                } else if character == "\"" || character == "'" || character == "`" {
                    quote = character
                } else if character == "/", next == "*" {
                    inBlock = true
                    index += 2
                    continue
                } else if (character == "/" && next == "/") || character == "#"
                    || (character == "-" && next == "-" && (index == 0 || characters[index - 1].isWhitespace))
                {
                    index += character == "#" ? 1 : 2
                    comment += String(characters[index...])
                    break
                }
                index += 1
            }
            let text = comment.trimmingCharacters(in: CharacterSet(charactersIn: " *\t"))
            if !text.isEmpty { comments.append(text) }
        }
        return comments.joined(separator: " ")
    }
    static func plain(_ answer: String) -> String {
        let pieces = AnswerBlock.parse(answer).map { block -> String in
            if block.isCode {
                let comments = codeComments(block.text)
                return comments.isEmpty ? "Code example is shown on screen." : "Code comments: " + comments
            }
            if let table = MarkdownAnswerTable.parse(block.text) {
                return table.rows.map { row in
                    zip(table.headers, row).map { "\($0): \($1)." }.joined(separator: " ")
                }.joined(separator: "\n")
            }
            return block.text
        }
        let joined = pieces.joined(separator: "\n").replacingOccurrences(
            of: #"(?m)^\s*(?:[-*]|\d+\.)\s+"#, with: "", options: .regularExpression)
        let markdown =
            (try? AttributedString(
                markdown: joined, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
        let plain = markdown.map { String($0.characters) } ?? joined
        return String(natural(plain).trimmingCharacters(in: .whitespacesAndNewlines).prefix(12000))
    }
    static func natural(_ text: String) -> String {
        var result = text.replacingOccurrences(
            of:
                #"(?im)^\s*(?:#{1,6}\s*)?(?:SAY THIS|SUMMARY|SHORT ANSWER|ANSWER|DETAILS?|APPROACH)(?:[ \t]*:[ \t]*|[ \t]*$)"#,
            with: "", options: .regularExpression)
        result = result.replacingOccurrences(
            of: #"(?im)^\s*(?:#{1,6}\s*)?EXAMPLE\s*:\s*"#,
            with: "For example, ", options: .regularExpression)
        result = result.replacingOccurrences(
            of: #"(?im)^\s*(?:#{1,6}\s*)?ANALOGY\s*:\s*"#,
            with: "Think of it this way. ", options: .regularExpression)
        for acronym in [
            "API", "AWS", "JVM", "JDK", "IDE", "JDBC", "HTTP", "HTTPS", "CPU", "URL", "DTO",
        ] {
            result = result.replacingOccurrences(
                of: "\\b" + acronym + "\\b", with: acronym.map(String.init).joined(separator: " "),
                options: .regularExpression)
        }
        return result
    }
    // Paragraph-sized utterances preserve intonation within a sentence and add a small breathing pause.
    static func paragraphs(_ text: String, limit: Int = 1800) -> [String] {
        var result: [String] = []
        for line in text.components(separatedBy: .newlines) {
            var remaining = line.trimmingCharacters(in: .whitespacesAndNewlines)
            while !remaining.isEmpty {
                let prefix = String(remaining.prefix(limit))
                let split =
                    remaining.count > limit ? (prefix.lastIndex(of: " ") ?? prefix.endIndex) : prefix.endIndex
                let piece = String(prefix[..<split])
                result.append(piece)
                remaining = String(remaining.dropFirst(piece.count)).trimmingCharacters(
                    in: .whitespacesAndNewlines)
            }
        }
        return result
    }
}

@MainActor
protocol AnswerSpeechEngine: AnyObject {
    func speak(_ text: String, voiceID: String, rate: Float, finished: @escaping () -> Void)
    func stop()
}

@MainActor
final class NativeAnswerSpeechEngine: AnswerSpeechEngine {
    var notice: ((String) -> Void)?
    private let synth = AVSpeechSynthesizer()
    private let playback: any SpeechPCMPlayback
    private var completion: (() -> Void)?
    private var run = UUID()
    private var paragraphs: [String] = []
    private var voiceID = ""
    private var rate: Float = 0.48
    private var lastFormat: AVAudioFormat?
    init(playback: (any SpeechPCMPlayback)? = nil) { self.playback = playback ?? NativeSpeechPCMPlayback() }
    func speak(_ text: String, voiceID: String, rate: Float, finished: @escaping () -> Void) {
        stop()
        paragraphs = AnswerSpeechText.paragraphs(text)
        self.voiceID = voiceID
        self.rate = rate
        completion = finished
        writeNext(token: run)
    }
    private func writeNext(token: UUID) {
        guard token == run else { return }
        guard !paragraphs.isEmpty else {
            playback.finish { [weak self] in
                guard let self, self.run == token else { return }
                let finished = self.completion
                self.completion = nil
                finished?()
            }
            return
        }
        let request = AVSpeechUtterance(string: paragraphs.removeFirst())
        request.voice = AVSpeechSynthesisVoice(identifier: voiceID)
        request.rate = rate
        synth.write(request) { [weak self] buffer in
            guard let source = buffer as? AVAudioPCMBuffer else { return }
            let ended = source.frameLength == 0
            // The synthesizer may reuse callback buffers. Own a copy before hopping to the UI actor.
            let copy = ended ? nil : NativeSpeechPCMPlayback.copy(source)
            Task { @MainActor in
                guard let self, self.run == token else { return }
                do {
                    if ended {
                        if !self.paragraphs.isEmpty, let format = self.lastFormat,
                            let pause = AVAudioPCMBuffer(
                                pcmFormat: format, frameCapacity: AVAudioFrameCount(format.sampleRate * 0.18))
                        {
                            pause.frameLength = pause.frameCapacity
                            for channel in UnsafeMutableAudioBufferListPointer(pause.mutableAudioBufferList) {
                                if let pointer = channel.mData {
                                    memset(pointer, 0, Int(channel.mDataByteSize))
                                }
                            }
                            try self.playback.appendNative(pause)
                        }
                        self.writeNext(token: token)
                    } else if let copy {
                        self.lastFormat = copy.format
                        try self.playback.appendNative(copy)
                    } else {
                        throw MeetingError.message("Cannot prepare the Mac voice audio.")
                    }
                } catch {
                    self.notice?(
                        (error as? MeetingError)?.localizedDescription ?? "Mac voice playback failed.")
                    let finished = self.completion
                    self.stop()
                    finished?()
                }
            }
        }
    }
    func stop() {
        run = UUID()
        completion = nil
        paragraphs = []
        lastFormat = nil
        synth.stopSpeaking(at: .immediate)
        playback.stop()
    }
}

@MainActor
final class AnswerSpeechController: ObservableObject {
    @Published private(set) var outputName: String
    @Published private(set) var speaking = false
    @Published private(set) var status = ""
    @Published private(set) var issue = false
    @Published private(set) var enabled: Bool
    @Published var pace: Double {
        didSet { defaults.set(SpeechPace.normalized(pace), forKey: "audioPace") }
    }
    @Published var provider: SpeechProvider {
        didSet {
            defaults.set(provider.rawValue, forKey: "speechProvider")
            applyPace()
        }
    }
    @Published var apiMode: APIVoiceMode {
        didSet {
            defaults.set(apiMode.rawValue, forKey: "apiVoiceMode")
            applyPace()
        }
    }
    @Published var macVoiceID: String {
        didSet {
            defaults.set(macVoiceID, forKey: "macVoiceID")
            applyPace()
        }
    }
    @Published var apiVoice: String {
        didSet {
            defaults.set(apiVoice, forKey: "apiVoice")
            applyPace()
        }
    }
    var availableVoices: [SpeechVoice] {
        voices().filter { $0.language == "en-US" && $0.female }.sorted { $0.label < $1.label }
    }
    func preview() {
        read(
            "SUMMARY: A transaction keeps related database changes together.\nEXAMPLE: If an API transfers money, both account updates succeed together, or both are rolled back."
        )
    }
    private let defaults: UserDefaults
    private let engine: any AnswerSpeechEngine
    private let output: () -> AudioOutput
    private let voices: () -> [SpeechVoice]
    private let monitor: AudioOutputMonitor?
    private var run = UUID()
    private var playingOutput: AudioOutput?
    private var latest: (id: UUID, answer: String)?
    private var playedID: UUID?
    private var spokenAnswer: String?
    init(
        engine: (any AnswerSpeechEngine)? = nil,
        output: @escaping () -> AudioOutput = AudioOutput.preferredHeadphones,
        voices: @escaping () -> [SpeechVoice] = SpeechVoice.installed,
        monitor: AudioOutputMonitor? = AudioOutputMonitor(), defaults: UserDefaults = .standard,
        key: @escaping () async throws -> String? = { try await Keychain.readAsync() }
    ) {
        self.engine = engine ?? SelectableAnswerSpeechEngine(key: key)
        outputName = output().name
        self.output = output
        self.voices = voices
        self.monitor = monitor
        self.defaults = defaults
        provider = SpeechProvider(rawValue: defaults.string(forKey: "speechProvider") ?? "") ?? .mac
        apiMode = APIVoiceMode(rawValue: defaults.string(forKey: "apiVoiceMode") ?? "") ?? .realtime
        macVoiceID = defaults.string(forKey: "macVoiceID") ?? ""
        apiVoice =
            APISpeechRequest.voices.contains(defaults.string(forKey: "apiVoice") ?? "")
            ? defaults.string(forKey: "apiVoice")! : "marin"
        enabled = defaults.bool(forKey: "automaticAnswerAudio")
        pace = SpeechPace.normalized(defaults.object(forKey: "audioPace") as? Double ?? 1)
        if let selected = self.engine as? SelectableAnswerSpeechEngine {
            selected.notice = { [weak self] message in
                self?.status = message
                self?.issue = true
            }
        }
        watchOutput()
        if enabled {
            status =
                output().headphoneLike
                ? "Audio on · Headphones connected · " + output().name
                : "Audio on · waiting for an answer and headphones"
        }
    }
    func setEnabled(_ value: Bool) {
        enabled = value
        defaults.set(value, forKey: "automaticAnswerAudio")
        if value {
            watchOutput()
            status =
                output().headphoneLike
                ? "Audio on · Headphones connected · " + output().name
                : "Audio on · waiting for an answer and headphones"
            speakLatestIfReady()
        } else {
            stop()
        }
    }
    func offer(_ answer: String, id: UUID) {
        guard enabled else { return }
        latest = (id, answer)
        speakLatestIfReady()
    }
    private func speakLatestIfReady() {
        guard enabled, let latest, latest.id != playedID else { return }
        read(latest.answer)
        if speaking { playedID = latest.id }
    }
    func read(_ answer: String) {
        halt()
        let text = AnswerSpeechText.plain(answer)
        guard !text.isEmpty else {
            fail("No answer to read yet.")
            return
        }
        let route = output()
        watchOutput()
        guard route.headphoneLike else {
            fail("Audio on · waiting for headphones. Current: \(route.name).")
            return
        }
        let voice = SpeechVoice.preferred(voices(), selected: macVoiceID)
        guard provider == .api || voice != nil else {
            fail("Install a female English (United States) voice in Mac Read & Speak settings.")
            return
        }
        if let selected = engine as? SelectableAnswerSpeechEngine { selected.fallbackVoiceID = voice?.id }
        spokenAnswer = answer
        playingOutput = route
        speaking = true
        issue = false
        status =
            "\(provider == .mac ? voice!.label : "API · " + apiVoice + " · AI-generated") · \(route.name)"
        let token = run
        watchOutput()
        engine.speak(
            text,
            voiceID: provider == .mac ? voice!.id : (apiMode == .realtime ? "realtime:" : "api:") + apiVoice,
            rate: SpeechPace.rate(pace)
        ) { [weak self] in
            guard let self, self.run == token else { return }
            self.speaking = false
            self.playingOutput = nil
            self.spokenAnswer = nil
            self.watchOutput()
            if !self.issue {
                self.status = self.enabled ? "Audio on · waiting for next answer" : "Read-aloud finished"
            }
        }
    }
    func applyPace() {
        // A speed change restarts the current explanation once, when slider dragging ends.
        if speaking, let answer = spokenAnswer { read(answer) }
    }
    func outputChanged() {
        let current = output()
        let changed = outputName != current.name
        outputName = current.name
        if !speaking, changed {
            status =
                current.headphoneLike
                ? (enabled ? "Audio on · " : "") + "Headphones connected · " + current.name
                : (enabled
                    ? "Audio on · waiting for headphones. Current: " + current.name
                    : "No headphones connected.")
            issue = false
        }
        if speaking, let previous = playingOutput, current != previous {
            halt()
            playedID = nil
            fail("Audio output changed. Playback stopped; waiting for headphones.")
        }
        watchOutput()
        if enabled { speakLatestIfReady() }
    }
    func stop() {
        latest = nil
        playedID = nil
        halt()
        watchOutput()
    }
    private func halt() {
        run = UUID()
        engine.stop()
        monitor?.stop()
        speaking = false
        playingOutput = nil
        spokenAnswer = nil
        status = ""
        issue = false
    }
    private func watchOutput() {
        monitor?.start(device: output().id) { [weak self] in Task { @MainActor in self?.outputChanged() } }
    }
    private func fail(_ message: String) {
        status = message
        issue = true
    }
}
