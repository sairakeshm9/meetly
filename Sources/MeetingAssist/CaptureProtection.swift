import AppKit
import ScreenCaptureKit
import SwiftUI
import Vision

// This requests legacy exclusion; it is not a guarantee about another app's capture engine.
struct CaptureProtectedWindow: NSViewRepresentable {
    var enabled = true
    func makeNSView(context: Context) -> ProtectionView {
        let view = ProtectionView()
        view.enabled = enabled
        return view
    }
    func updateNSView(_ nsView: ProtectionView, context: Context) {
        nsView.enabled = enabled
        nsView.protectWindow()
    }
}

final class ProtectionView: NSView {
    var enabled = true
    private var observer: NSObjectProtocol?
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        guard let window else { return }
        protectWindow()
        observer = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main
        ) { [weak self] _ in self?.protectWindow() }
    }
    func protectWindow() { window?.sharingType = enabled ? .none : .readOnly }
    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }
}

enum CaptureProtectionResult: Equatable {
    case notTested, hidden, visible
    case inconclusive(String)
    var message: String {
        switch self {
        case .notTested: return "Capture exclusion requested. Compatibility not tested."
        case .hidden: return "Hidden in this local test. Confirm with a meeting viewer."
        case .visible: return "Visible in modern screen capture. Full-screen privacy is not confirmed."
        case .inconclusive(let reason): return "Test incomplete: " + reason
        }
    }
    static func evaluate(baseline: Bool, protected: Bool, control: Bool) -> Self {
        guard baseline, control else {
            return .inconclusive("Test window was obscured or capture did not update.")
        }
        return protected ? .visible : .hidden
    }
}

@MainActor
final class CaptureProtectionController: ObservableObject {
    @Published private(set) var testing = false
    @Published private(set) var result = CaptureProtectionResult.notTested
    private var task: Task<Void, Never>?
    private let probe: () async throws -> CaptureProtectionResult
    init(
        probe: @escaping () async throws -> CaptureProtectionResult = {
            try await CaptureProtectionProbe.run()
        }
    ) {
        self.probe = probe
    }
    func test() {
        guard !testing else { return }
        testing = true
        task = Task { [weak self, probe] in
            let result: CaptureProtectionResult
            do { result = try await probe() } catch { result = .inconclusive(error.localizedDescription) }
            guard !Task.isCancelled, let self else { return }
            self.result = result
            self.testing = false
            self.task = nil
        }
    }
    func stop() {
        task?.cancel()
        task = nil
        testing = false
        result = .notTested
    }
}

@MainActor
enum CaptureProtectionProbe {
    enum ProbeError: LocalizedError {
        case permission, display, obscured, crop, timeout
        var errorDescription: String? {
            switch self {
            case .permission: return "Allow Screen Recording for Meetly, then retry."
            case .display: return "No main display available."
            case .obscured: return "Keep the test window visible and retry."
            case .crop: return "Unable to locate the test panel in the capture."
            case .timeout: return "Screen capture did not respond. Retry after checking recording access."
            }
        }
    }
    static func run() async throws -> CaptureProtectionResult {
        guard CGPreflightScreenCaptureAccess() else { throw ProbeError.permission }
        let content: SCShareableContent = try await boundedCapture { completion in
            SCShareableContent.getExcludingDesktopWindows(
                false, onScreenWindowsOnly: false, completionHandler: completion)
        }
        guard let display = content.displays.first(where: { $0.displayID == CGMainDisplayID() }),
            let screen = NSScreen.screens.first(where: {
                ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
                    == display.displayID
            })
        else { throw ProbeError.display }
        let window = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 540, height: 130),
            styleMask: [.titled, .nonactivatingPanel], backing: .buffered, defer: false)
        window.title = "Local capture test"
        window.isReleasedWhenClosed = false
        window.hidesOnDeactivate = false
        window.level = .floating
        window.backgroundColor = .black
        window.setFrameOrigin(NSPoint(x: screen.visibleFrame.midX - 270, y: screen.visibleFrame.midY - 65))
        let label = NSTextField(labelWithString: "")
        label.frame = NSRect(x: 20, y: 35, width: 500, height: 60)
        label.font = .monospacedSystemFont(ofSize: 28, weight: .bold)
        label.textColor = .white
        label.alignment = .center
        window.contentView?.addSubview(label)
        defer { window.close() }
        // No exclusions: this must exercise the ordinary full-display capture path.
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let config = SCStreamConfiguration()
        config.width = display.width
        config.height = display.height
        config.showsCursor = false
        config.capturesAudio = false
        let nonce = String(Int.random(in: 10000...99999))
        func containsMarker(_ phase: String, protected: Bool) async throws -> Bool {
            try Task.checkCancellation()
            let marker = "MA \(phase) \(nonce)"
            label.stringValue = marker
            window.sharingType = protected ? .none : .readOnly
            window.orderFrontRegardless()
            window.sharingType = protected ? .none : .readOnly
            window.displayIfNeeded()
            let image = try await capture(filter: filter, configuration: config)
            guard window.isVisible else {
                throw ProbeError.obscured
            }
            // Crop to the test panel. Captured desktop pixels stay in memory and never go to an API.
            let frame = window.frame
            let rect = CGRect(
                x: (frame.minX - screen.frame.minX) / screen.frame.width * CGFloat(image.width),
                y: (screen.frame.maxY - frame.maxY) / screen.frame.height * CGFloat(image.height),
                width: frame.width / screen.frame.width * CGFloat(image.width),
                height: frame.height / screen.frame.height * CGFloat(image.height))
            guard let crop = image.cropping(to: rect) else { throw ProbeError.crop }
            return try await Task.detached {
                let request = VNRecognizeTextRequest()
                request.recognitionLevel = .accurate
                request.usesLanguageCorrection = false
                try VNImageRequestHandler(cgImage: crop).perform([request])
                return (request.results ?? []).contains {
                    guard let text = $0.topCandidates(1).first?.string else { return false }
                    return protected ? text.contains(nonce) && text.contains("MA") : text.contains(marker)
                }
            }.value
        }
        let baseline = try await containsMarker("BASELINE", protected: false)
        let protected = try await containsMarker("PROTECTED", protected: true)
        let control = try await containsMarker("CONTROL", protected: false)
        try Task.checkCancellation()
        return .evaluate(baseline: baseline, protected: protected, control: control)
    }
    private static func capture(filter: SCContentFilter, configuration: SCStreamConfiguration) async throws
        -> CGImage
    {
        try await boundedCapture { completion in
            SCScreenshotManager.captureImage(
                contentFilter: filter, configuration: configuration, completionHandler: completion)
        }
    }
    private static func boundedCapture<Value>(
        _ start: (@escaping @Sendable (Value?, Error?) -> Void) -> Void
    ) async throws -> Value {
        let pending = CaptureWaiter<Value>()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                pending.begin(continuation)
                start { value, error in
                    Task { @MainActor in
                        if let value {
                            pending.finish(.success(value))
                        } else {
                            pending.finish(.failure(error ?? ProbeError.crop))
                        }
                    }
                }
            }
        } onCancel: {
            Task { @MainActor in pending.finish(.failure(CancellationError())) }
        }
    }
}

@MainActor
final class CaptureWaiter<Value> {
    private var continuation: CheckedContinuation<Value, Error>?
    private var timeout: Task<Void, Never>?
    func begin(_ continuation: CheckedContinuation<Value, Error>, seconds: Double = 8) {
        self.continuation = continuation
        timeout = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(seconds)) } catch { return }
            self?.finish(.failure(CaptureProtectionProbe.ProbeError.timeout))
        }
    }
    func finish(_ result: Result<Value, Error>) {
        guard let continuation else { return }
        self.continuation = nil
        timeout?.cancel()
        timeout = nil
        continuation.resume(with: result)
    }
}
