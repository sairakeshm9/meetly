import AppKit
import CoreImage
import MeetingCore
import ScreenCaptureKit
import SwiftUI

protocol WorkspaceCapturing: AnyObject {
    func start(onFrame: @escaping (CGImage) -> Void, onFailure: @escaping (String) -> Void) async throws
    func stop() async
}

private final class WorkspaceFrameOutput: NSObject, SCStreamOutput {
    private let context = CIContext(options: [.cacheIntermediates: false])
    private let onFrame: (CGImage) -> Void
    init(onFrame: @escaping (CGImage) -> Void) { self.onFrame = onFrame }
    func stream(_ stream: SCStream, didOutputSampleBuffer buffer: CMSampleBuffer, of type: SCStreamOutputType)
    {
        guard type == .screen, CMSampleBufferIsValid(buffer),
            let attachments = CMSampleBufferGetSampleAttachmentsArray(buffer, createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]],
            let status = attachments.first?[.status] as? Int, status == SCFrameStatus.complete.rawValue,
            let pixelBuffer = CMSampleBufferGetImageBuffer(buffer)
        else { return }
        let image = CIImage(cvPixelBuffer: pixelBuffer)
        if let frame = context.createCGImage(image, from: image.extent) { onFrame(frame) }
    }
}

final class WorkspaceScreenCapture: NSObject, WorkspaceCapturing, SCStreamDelegate {
    private let framesPerSecond: Int
    private let maxDimension: Int
    init(framesPerSecond: Int = 15, maxDimension: Int = 1600) {
        self.framesPerSecond = framesPerSecond
        self.maxDimension = maxDimension
        super.init()
    }
    private var stream: SCStream?
    private var output: WorkspaceFrameOutput?
    private var failure: ((String) -> Void)?
    private let queue = DispatchQueue(label: "com.akshay.meetingassist.workspace")
    static func configuration(width: Int, height: Int, framesPerSecond: Int = 15, maxDimension: Int = 1600)
        -> SCStreamConfiguration
    {
        let config = SCStreamConfiguration()
        let scale = min(1, Double(maxDimension) / Double(max(1, max(width, height))))
        config.width = max(1, Int(Double(width) * scale))
        config.height = max(1, Int(Double(height) * scale))
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(max(1, framesPerSecond)))
        config.queueDepth = 3
        config.capturesAudio = false
        config.showsCursor = true
        return config
    }
    func start(onFrame: @escaping (CGImage) -> Void, onFailure: @escaping (String) -> Void) async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard
            let display = content.displays.first(where: { $0.displayID == CGMainDisplayID() })
                ?? content.displays.first,
            let ownApp = content.applications.first(where: {
                $0.processID == ProcessInfo.processInfo.processIdentifier
            })
        else {
            throw MeetingError.message(
                "Cannot identify this app for exclusion. The sharing window has not started.")
        }
        // The meeting app shares this filtered workspace window, rather than the full display.
        // Excluding our whole process removes the assistant, resume/settings sheets and this mirror.
        let filter = SCContentFilter(display: display, excludingApplications: [ownApp], exceptingWindows: [])
        let capture = SCStream(
            filter: filter,
            configuration: Self.configuration(
                width: display.width, height: display.height, framesPerSecond: framesPerSecond,
                maxDimension: maxDimension),
            delegate: self)
        let frames = WorkspaceFrameOutput(onFrame: onFrame)
        try capture.addStreamOutput(frames, type: .screen, sampleHandlerQueue: queue)
        output = frames
        failure = onFailure
        stream = capture
        do { try await capture.startCapture() } catch {
            stream = nil
            output = nil
            failure = nil
            throw error
        }
    }
    func stop() async {
        let old = stream
        stream = nil
        if let old { try? await old.stopCapture() }
        output = nil
        failure = nil
    }
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        failure?("Workspace capture stopped. Close the sharing window and reopen it before sharing.")
    }
}

@MainActor
final class WorkspaceController: NSObject, ObservableObject, NSWindowDelegate {
    @Published private(set) var active = false
    @Published private(set) var starting = false
    @Published private(set) var image: NSImage?
    @Published private(set) var error: String?
    private let captureFactory: () -> any WorkspaceCapturing
    private let windowFactory: @MainActor () -> NSWindow?
    private var capture: (any WorkspaceCapturing)?
    private var window: NSWindow?
    private var task: Task<Void, Never>?
    private var generation = UUID()
    init(
        captureFactory: @escaping () -> any WorkspaceCapturing = { WorkspaceScreenCapture() },
        windowFactory: @escaping @MainActor () -> NSWindow? = {
            NSWindow(
                contentRect: NSRect(x: 100, y: 100, width: 960, height: 600),
                styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false
            )
        }
    ) {
        self.captureFactory = captureFactory
        self.windowFactory = windowFactory
        super.init()
    }
    func open() {
        if active || starting {
            window?.makeKeyAndOrderFront(nil)
            return
        }
        stop()
        error = nil
        starting = true
        let run = UUID()
        generation = run
        let source = captureFactory()
        capture = source
        let shareWindow = windowFactory()
        shareWindow?.title = "Meeting Workspace"
        shareWindow?.isReleasedWhenClosed = false
        shareWindow?.delegate = self
        shareWindow?.contentView = NSHostingView(rootView: WorkspaceView(controller: self))
        shareWindow?.makeKeyAndOrderFront(nil)
        window = shareWindow
        task = Task { [weak self] in
            guard let self else { return }
            do {
                try await source.start { [weak self] frame in
                    Task { @MainActor in
                        guard let self, self.generation == run else { return }
                        self.image = NSImage(cgImage: frame, size: .zero)
                    }
                } onFailure: { [weak self] message in
                    Task { @MainActor in
                        guard let self, self.generation == run else { return }
                        self.fail(message)
                    }
                }
                guard generation == run, !Task.isCancelled else {
                    await source.stop()
                    return
                }
                active = true
                starting = false
                task = nil
            } catch {
                guard generation == run else { return }
                fail("Cannot prepare the sharing window. Check Mac recording permission and reopen it.")
            }
        }
    }
    private func fail(_ message: String) {
        generation = UUID()
        task?.cancel()
        task = nil
        let old = capture
        capture = nil
        Task { await old?.stop() }
        active = false
        starting = false
        image = nil
        error = message
    }
    func stop() {
        generation = UUID()
        task?.cancel()
        task = nil
        let old = capture
        capture = nil
        Task { await old?.stop() }
        active = false
        starting = false
        image = nil
        window?.delegate = nil
        window?.contentView = nil
        window?.close()
        window = nil
    }
    func windowWillClose(_ notification: Notification) { stop() }
}

private struct WorkspaceView: View {
    @ObservedObject var controller: WorkspaceController
    var body: some View {
        ZStack {
            Color.black
            if let image = controller.image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
            } else {
                Text(controller.error ?? "Preparing desktop…").foregroundStyle(.white).padding(30)
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
