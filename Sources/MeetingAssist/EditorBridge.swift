import Foundation
import MeetingCore

/// A private local file handoff, read only while the user enables editor context.
@MainActor
final class EditorBridge: ObservableObject {
    nonisolated static let directory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
        "Library/Application Support/Meeting Assist/editor-bridge")
    @Published private(set) var enabled = false
    @Published private(set) var snapshot: EditorSnapshot?
    @Published private(set) var status = "Editor connection off"
    var onChange: ((EditorSnapshot) -> Void)?
    private var task: Task<Void, Never>?
    let directory: URL
    init(directory: URL = EditorBridge.directory) { self.directory = directory }
    func start() {
        stop()
        enabled = true
        status = "Waiting for editor · run Connect Meetly in the editor"
        task = Task { [weak self] in
            while !Task.isCancelled {
                self?.poll()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }
    func poll(now: Date = Date()) {
        guard enabled else { return }
        do {
            let paths = ["vscode.json", "intellij.json"].map { directory.appendingPathComponent($0) }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let candidates = paths.compactMap { url -> EditorSnapshot? in
                guard let size = try? url.resourceValues(forKeys: [.fileSizeKey, .isSymbolicLinkKey]),
                    size.isSymbolicLink != true,
                    (size.fileSize ?? Int.max) <= 200000, let data = try? Data(contentsOf: url),
                    let frame = try? decoder.decode(EditorSnapshot.self, from: data),
                    let valid = try? frame.validated(now: now)
                else { return nil }
                return valid
            }
            guard let current = candidates.max(by: { $0.capturedAt < $1.capturedAt }) else {
                snapshot = nil
                status = "Editor not connected or snapshot expired"
                return
            }
            let changed = current.fingerprint != snapshot?.fingerprint
            snapshot = current
            status = "\(current.editor) · \(current.file) · line \(current.cursorLine)"
            if changed { onChange?(current) }
        }
    }
    func stop() {
        task?.cancel()
        task = nil
        enabled = false
        snapshot = nil
        status = "Editor connection off"
    }
    func current(now: Date = Date()) -> EditorSnapshot? {
        guard enabled else { return nil }
        poll(now: now)
        return snapshot
    }
}
