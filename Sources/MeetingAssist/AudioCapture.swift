import AVFoundation
import MeetingCore
import ScreenCaptureKit

struct AudioFrame: Sendable {
    let pcm: Data
    let rms: Double
    let seconds: Double
    let microphone: Bool
    var capturedAt = Date()
}

/// Group PCM into 40 ms packets without dropping samples or mixing audio sources.
struct PCMFrameBatcher {
    private var pending = Data()
    private let packetBytes = 1920
    mutating func append(_ frame: AudioFrame) -> [AudioFrame] {
        guard !frame.pcm.isEmpty, frame.pcm.count.isMultiple(of: 2) else { return [] }
        pending.append(frame.pcm)
        var output: [AudioFrame] = []
        while pending.count >= packetBytes {
            let data = Data(pending.prefix(packetBytes))
            pending.removeFirst(packetBytes)
            var sum = 0.0
            data.withUnsafeBytes { bytes in
                for offset in stride(from: 0, to: data.count, by: 2) {
                    let value = Double(bytes.loadUnaligned(fromByteOffset: offset, as: Int16.self)) / 32768
                    sum += value * value
                }
            }
            // Backdate complete packets when a callback contains more than one packet.
            let trailingSeconds = Double(pending.count) / 48000
            output.append(
                AudioFrame(
                    pcm: data, rms: sqrt(sum / 960), seconds: 0.04,
                    microphone: frame.microphone,
                    capturedAt: frame.capturedAt.addingTimeInterval(-trailingSeconds)))
        }
        return output
    }
}

/// Preserve resampling state between callbacks; disable initial priming loss for live chunks.
final class PCMConverter {
    private var format: AVAudioFormat?
    private var converter: AVAudioConverter?
    func get(from source: AVAudioFormat, to target: AVAudioFormat) -> AVAudioConverter? {
        if format != source {
            format = source
            converter = AVAudioConverter(from: source, to: target)
            converter?.primeMethod = .none
        }
        return converter
    }
}

protocol MeetingAudioCapturing: AnyObject {
    var onFailure: ((String) -> Void)? { get set }
    func start(microphone: Bool) async throws -> AsyncStream<AudioFrame>
    func stop() async
}

final class AudioCapture: NSObject, MeetingAudioCapturing, SCStreamOutput, SCStreamDelegate {
    private let meetingConverter = PCMConverter()
    private let micConverter = PCMConverter()
    private var meetingBatcher = PCMFrameBatcher()
    private var micBatcher = PCMFrameBatcher()
    private var stream: SCStream?
    private var frames: AsyncStream<AudioFrame>.Continuation?
    private let queue = DispatchQueue(label: "com.akshay.meetingassist.audio")
    var onFailure: ((String) -> Void)?
    static func checkAccess() async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(
            false, onScreenWindowsOnly: false)
        guard !content.displays.isEmpty else {
            throw MeetingError.message("No display available for system audio capture.")
        }
    }
    func start(microphone: Bool) async throws -> AsyncStream<AudioFrame> {
        if microphone {
            guard await AVCaptureDevice.requestAccess(for: .audio) else {
                throw MeetingError.message(
                    "Microphone permission denied. Allow it in System Settings or turn microphone context off."
                )
            }
        }
        let content = try await SCShareableContent.excludingDesktopWindows(
            false, onScreenWindowsOnly: false)
        guard let display = content.displays.first else {
            throw MeetingError.message("No display available for system audio capture.")
        }
        // Exclude only this app: new meeting apps and browser helpers are included automatically.
        let filter = SCContentFilter(
            display: display,
            excludingApplications: content.applications.filter {
                $0.processID == ProcessInfo.processInfo.processIdentifier
            }, exceptingWindows: [])
        let config = SCStreamConfiguration()
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        config.capturesAudio = true
        config.sampleRate = 24000
        config.channelCount = 1
        config.excludesCurrentProcessAudio = true
        config.captureMicrophone = microphone
        let pair = AsyncStream<AudioFrame>.makeStream(bufferingPolicy: .bufferingOldest(150))
        frames = pair.continuation
        let capture = SCStream(filter: filter, configuration: config, delegate: self)
        try capture.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
        if microphone {
            try capture.addStreamOutput(self, type: .microphone, sampleHandlerQueue: queue)
        }
        stream = capture
        do { try await capture.startCapture() } catch {
            stream = nil
            frames?.finish()
            frames = nil
            throw error
        }
        return pair.stream
    }
    func stop() async {
        let old = stream
        stream = nil
        if let old { try? await old.stopCapture() }
        queue.sync {
            frames?.finish()
            frames = nil
        }
    }
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        onFailure?("Audio capture stopped. Check recording permission and restart listening.")
    }
    func stream(
        _ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of type: SCStreamOutputType
    ) {
        guard type == .audio || type == .microphone, sampleBuffer.isValid,
            CMSampleBufferGetNumSamples(sampleBuffer) > 0
        else { return }
        do {
            let frame = try Self.convert(
                sampleBuffer, microphone: type == .microphone,
                converterStore: type == .microphone ? micConverter : meetingConverter)
            let batches: [AudioFrame]
            if frame.microphone {
                batches = micBatcher.append(frame)
            } else {
                batches = meetingBatcher.append(frame)
            }
            for batch in batches {
                if let frames, case .dropped = frames.yield(batch) {
                    onFailure?("Audio processing is overloaded. Stop and restart listening.")
                    break
                }
            }
        } catch {
            onFailure?("Unsupported audio format. Restart listening and check the Mac audio output.")
        }
    }
    static func convert(
        _ sample: CMSampleBuffer, microphone: Bool,
        converterStore: PCMConverter? = nil
    ) throws -> AudioFrame {
        guard let description = sample.formatDescription,
            let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(description),
            let format = AVAudioFormat(streamDescription: asbd)
        else {
            throw MeetingError.message("Missing audio format.")
        }
        var required = 0
        var block: CMBlockBuffer?
        CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sample, bufferListSizeNeededOut: &required,
            bufferListOut: nil, bufferListSize: 0, blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil,
            flags: UInt32(kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment),
            blockBufferOut: &block)
        guard required > 0 else { throw MeetingError.message("Empty audio buffer.") }
        let memory = UnsafeMutableRawPointer.allocate(byteCount: required, alignment: 16)
        defer { memory.deallocate() }
        let list = memory.bindMemory(to: AudioBufferList.self, capacity: 1)
        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sample, bufferListSizeNeededOut: nil,
            bufferListOut: list, bufferListSize: required, blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil,
            flags: UInt32(kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment),
            blockBufferOut: &block)
        guard status == noErr,
            let input = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: list, deallocator: nil),
            let target = AVAudioFormat(
                commonFormat: .pcmFormatInt16, sampleRate: 24000, channels: 1, interleaved: true),
            let converter = (converterStore ?? PCMConverter()).get(from: format, to: target)
        else {
            throw MeetingError.message("Cannot convert audio.")
        }
        input.frameLength = AVAudioFrameCount(CMSampleBufferGetNumSamples(sample))
        let capacity =
            AVAudioFrameCount(ceil(Double(input.frameLength) * 24000 / format.sampleRate)) + 64
        guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else {
            throw MeetingError.message("Cannot allocate audio.")
        }
        var used = false
        var conversionError: NSError?
        let conversionStatus = converter.convert(to: output, error: &conversionError) { _, status in
            if used {
                status.pointee = converterStore == nil ? .endOfStream : .noDataNow
                return nil
            }
            used = true
            status.pointee = .haveData
            return input
        }
        guard conversionStatus != .error, conversionError == nil,
            let values = output.int16ChannelData?[0]
        else {
            throw MeetingError.message("Audio conversion failed.")
        }
        if converterStore == nil {
            // A finite clip can include a resampling filter tail; preserve the source duration.
            output.frameLength = min(
                output.frameLength,
                AVAudioFrameCount(ceil(Double(input.frameLength) * 24000 / format.sampleRate)))
        }
        let count = Int(output.frameLength)
        guard count > 0 else { return .init(pcm: Data(), rms: 0, seconds: 0, microphone: microphone) }
        var sum = 0.0
        for i in 0..<count {
            let v = Double(values[i]) / 32768
            sum += v * v
        }
        let data = Data(bytes: values, count: count * 2)
        return .init(
            pcm: data, rms: sqrt(sum / Double(count)), seconds: Double(count) / 24000,
            microphone: microphone)
    }
}
