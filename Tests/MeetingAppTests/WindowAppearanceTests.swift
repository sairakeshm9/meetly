import AppKit
import XCTest

@testable import MeetingAssist

final class WindowAppearanceTests: XCTestCase {
    func testTransparencyBoundsAndInvalidInput() {
        XCTAssertEqual(WindowTransparency.normalized(-5), 0)
        XCTAssertEqual(WindowTransparency.normalized(105), 100)
        XCTAssertEqual(WindowTransparency.normalized(.nan), 20)
        XCTAssertEqual(WindowTransparency.normalized(.infinity), 20)
        XCTAssertEqual(WindowTransparency.backgroundOpacity(0), 1)
        XCTAssertEqual(WindowTransparency.backgroundOpacity(40), 0.6, accuracy: 0.001)
        XCTAssertEqual(WindowTransparency.backgroundOpacity(80), 0.2, accuracy: 0.001)
        XCTAssertEqual(WindowTransparency.backgroundOpacity(100), 0)
    }

    @MainActor
    func testPreferenceSurvivesRestartAndSolidReset() {
        let name = "MeetingAssist.AppearanceTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let model = MeetingModel(appearanceDefaults: defaults)
        XCTAssertEqual(model.windowTransparency, 20)
        model.setWindowTransparency(45)
        XCTAssertEqual(MeetingModel(appearanceDefaults: defaults).windowTransparency, 45)
        model.setWindowTransparency(100)
        XCTAssertEqual(defaults.double(forKey: WindowTransparency.preferenceKey), 100)
        model.setWindowTransparency(0)
        XCTAssertEqual(MeetingModel(appearanceDefaults: defaults).windowTransparency, 0)
        defaults.set(-42, forKey: WindowTransparency.preferenceKey)
        XCTAssertEqual(MeetingModel(appearanceDefaults: defaults).windowTransparency, 0)
    }

    @MainActor
    func testSurfaceTransparencyKeepsTextCaptureProtectionAndWindowLevelUnchanged() {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.sharingType = .none
        window.level = .floating
        window.alphaValue = 0.4
        let appearance = AssistantAppearanceView()
        appearance.transparency = 60
        window.contentView = appearance
        XCTAssertEqual(window.alphaValue, 1, "Native opacity must not fade text")
        XCTAssertFalse(window.isOpaque)
        XCTAssertEqual(window.backgroundColor, .clear)
        XCTAssertEqual(window.sharingType, .none)
        XCTAssertEqual(window.level, .floating)
        window.alphaValue = 1
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: window)
        XCTAssertEqual(window.alphaValue, 1, accuracy: 0.001)
        window.alphaValue = 1
        NotificationCenter.default.post(name: NSWindow.didEndSheetNotification, object: window)
        XCTAssertEqual(window.alphaValue, 1, accuracy: 0.001)
        window.contentView = nil
        window.alphaValue = 1
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: window)
        XCTAssertEqual(window.alphaValue, 1, "A detached view must not change the old window")
        window.contentView = appearance
        XCTAssertEqual(window.alphaValue, 1, accuracy: 0.001)
        appearance.transparency = 0
        appearance.configureWindow()
        XCTAssertEqual(window.alphaValue, 1, "Solid reset restores fully visible text")
    }

    func testAnswerBoxDragBoundsAndWindowResize() {
        let available = CGSize(width: 700, height: 500)
        XCTAssertEqual(AnswerBoxLayout.size(nil, within: available), available)
        let resized = AnswerBoxLayout.resized(
            from: available, translation: CGSize(width: -150, height: -100), within: available)
        XCTAssertEqual(resized, CGSize(width: 550, height: 400))
        XCTAssertEqual(
            AnswerBoxLayout.size(CGSize(width: -50, height: -50), within: available),
            CGSize(width: 360, height: 200))
        XCTAssertEqual(AnswerBoxLayout.size(CGSize(width: 900, height: 900), within: available), available)
        let compact = CGSize(width: 280, height: 140)
        XCTAssertEqual(AnswerBoxLayout.size(resized, within: compact), compact)
        XCTAssertEqual(AnswerBoxLayout.size(resized, within: .zero), .zero)
    }
}
