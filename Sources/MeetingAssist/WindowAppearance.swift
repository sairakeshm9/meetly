import AppKit
import SwiftUI

enum WindowTransparency {
    static let preferenceKey = "assistantWindowTransparency"
    static let defaultPercent = 20.0
    static let range = 0.0...100.0

    static func normalized(_ percent: Double) -> Double {
        guard percent.isFinite else { return defaultPercent }
        return min(range.upperBound, max(range.lowerBound, percent))
    }

    static func backgroundOpacity(_ percent: Double) -> Double {
        1 - normalized(percent) / 100
    }
}

// Keep the native window clear; SwiftUI fades surfaces independently of answer text.
struct TransparentAssistantWindow: NSViewRepresentable {
    var transparency: Double
    var model: MeetingModel? = nil
    func makeNSView(context: Context) -> AssistantAppearanceView {
        let view = AssistantAppearanceView()
        view.transparency = transparency
        view.model = model
        return view
    }
    func updateNSView(_ view: AssistantAppearanceView, context: Context) {
        view.transparency = transparency
        view.model = model
        view.configureWindow()
    }
}

final class AssistantAppearanceView: NSView {
    var transparency = WindowTransparency.defaultPercent
    weak var model: MeetingModel?
    private var observers: [NSObjectProtocol] = []
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers.removeAll()
        guard let window else { return }
        configureWindow()
        // AppKit can restore opacity after a sheet transition; reapply the saved appearance.
        for name in [
            NSWindow.didBecomeKeyNotification, NSWindow.didEndSheetNotification, NSWindow.didMoveNotification,
            NSWindow.didResizeNotification,
        ] {
            observers.append(
                NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) {
                    [weak self] _ in self?.configureWindow()
                })
        }
    }

    func configureWindow() {
        guard let window else { return }
        // Only SwiftUI surface fills fade. Native window alpha must never multiply text opacity.
        window.alphaValue = 1
        window.isOpaque = false
        window.backgroundColor = .clear
        window.titlebarAppearsTransparent = true
        window.ignoresMouseEvents = false
        window.hasShadow = WindowTransparency.normalized(transparency) < 100
    }

    deinit {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
    }
}

enum AnswerBoxLayout {
    static func size(_ preferred: CGSize?, within available: CGSize) -> CGSize {
        let width = max(0, available.width)
        let height = max(0, available.height)
        return CGSize(
            width: min(width, max(min(360, width), preferred?.width ?? width)),
            height: min(height, max(min(200, height), preferred?.height ?? height)))
    }

    static func resized(from start: CGSize, translation: CGSize, within available: CGSize) -> CGSize {
        size(
            CGSize(width: start.width + translation.width, height: start.height + translation.height),
            within: available)
    }
}
