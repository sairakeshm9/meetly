import AppKit
import MeetingCore
import Vision

struct ScreenSnapshot: Sendable {
    let jpeg: Data
    let text: String
    let capturedAt: Date
    var hasCode: Bool {
        text.range(
            of:
                #"\b(?:class|interface|public|private|return|import|package|def|function|const|select|void)\b"#,
            options: [.regularExpression, .caseInsensitive]) != nil
    }
    var fingerprint: UInt64 {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ").utf8.reduce(
            14_695_981_039_346_656_037
        ) { ($0 ^ UInt64($1)) &* 1_099_511_628_211 }
    }
    static func read(_ image: CGImage) throws -> Self {
        let bitmap = NSBitmapImageRep(cgImage: image)
        guard let jpeg = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.72]) else {
            throw MeetingError.message("Screenshot could not be prepared.")
        }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .fast
        request.usesLanguageCorrection = false
        try VNImageRequestHandler(cgImage: image).perform([request])
        let text =
            request.results?.compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n") ?? ""
        return Self(jpeg: jpeg, text: String(text.prefix(16000)), capturedAt: Date())
    }
}

/// Screen frames stay local until an answer request explicitly consumes the current snapshot.
@MainActor
final class ScreenContextController: ObservableObject {
    @Published private(set) var enabled = false
    @Published private(set) var starting = false
    @Published private(set) var snapshot: ScreenSnapshot?
    @Published private(set) var error: String?
    var onSnapshot: ((ScreenSnapshot) -> Void)?
    var onFailure: ((String) -> Void)?
    private let captureFactory: () -> any WorkspaceCapturing
    private let analyzer: (CGImage) async throws -> ScreenSnapshot
    private var capture: (any WorkspaceCapturing)?
    private var startTask: Task<Void, Never>?
    private var frameTask: Task<Void, Never>?
    private var generation = UUID()
    private var waiters: [UUID: (CheckedContinuation<ScreenSnapshot, Error>, Task<Void, Never>)] = [:]
    init(
        captureFactory: @escaping () -> any WorkspaceCapturing = {
            WorkspaceScreenCapture(framesPerSecond: 1, maxDimension: 2000)
        },
        analyzer: @escaping (CGImage) async throws -> ScreenSnapshot = { image in
            try await Task.detached { try ScreenSnapshot.read(image) }.value
        }
    ) {
        self.captureFactory = captureFactory
        self.analyzer = analyzer
    }
    func start() {
        guard !enabled && !starting else { return }
        stop()
        error = nil
        starting = true
        let run = UUID()
        generation = run
        let source = captureFactory()
        capture = source
        startTask = Task {
            do {
                try await source.start { [weak self] image in
                    Task { @MainActor in
                        guard let self, self.generation == run, self.frameTask == nil else { return }
                        self.frameTask = Task {
                            do {
                                let frame = try await self.analyzer(image)
                                guard self.generation == run, !Task.isCancelled else { return }
                                self.snapshot = frame
                                self.resolveWaiters(.success(frame))
                                self.onSnapshot?(frame)
                            } catch {
                                guard self.generation == run else { return }
                                self.fail("Screenshot unreadable. Reopen Watch screen.")
                            }
                            if self.generation == run { self.frameTask = nil }
                        }
                    }
                } onFailure: { [weak self] _ in
                    Task { @MainActor in
                        guard let self, self.generation == run else { return }
                        self.fail("Screen capture stopped. Refresh or reopen Watch screen.")
                    }
                }
                guard generation == run, !Task.isCancelled else {
                    await source.stop()
                    return
                }
                enabled = true
                starting = false
                startTask = nil
            } catch {
                guard generation == run else { return }
                fail("Screen access unavailable. Allow Mac recording permission.")
            }
        }
    }
    private func fail(_ message: String) {
        resolveWaiters(.failure(MeetingError.message(message)))
        stop()
        error = message
        onFailure?(message)
    }
    func stop() {
        resolveWaiters(.failure(CancellationError()))
        generation = UUID()
        startTask?.cancel()
        startTask = nil
        frameTask?.cancel()
        frameTask = nil
        let old = capture
        capture = nil
        Task { await old?.stop() }
        enabled = false
        starting = false
        snapshot = nil
    }
    func snapshotForAnswer() async throws -> ScreenSnapshot {
        try Task.checkCancellation()
        // A healthy static screen may emit no new complete frame; its last frame is still current.
        if enabled, let snapshot { return snapshot }
        guard enabled || starting else {
            throw MeetingError.message(error ?? "Screen capture is off. Enable Watch screen first.")
        }
        let id = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                let timeout = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(5))
                    guard !Task.isCancelled, let waiter = self?.waiters.removeValue(forKey: id) else {
                        return
                    }
                    waiter.0.resume(
                        throwing: MeetingError.message("Screenshot unavailable. Refresh Watch screen."))
                }
                waiters[id] = (continuation, timeout)
            }
        } onCancel: {
            Task { @MainActor in
                guard let waiter = self.waiters.removeValue(forKey: id) else { return }
                waiter.1.cancel()
                waiter.0.resume(throwing: CancellationError())
            }
        }
    }
    private func resolveWaiters(_ result: Result<ScreenSnapshot, Error>) {
        let pending = waiters.values
        waiters.removeAll()
        for (continuation, task) in pending {
            task.cancel()
            continuation.resume(with: result)
        }
    }
}
