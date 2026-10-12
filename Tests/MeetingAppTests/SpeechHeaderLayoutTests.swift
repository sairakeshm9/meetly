import AppKit
import Combine
import SwiftUI
import XCTest

@testable import MeetingAssist

@MainActor
private final class HeaderTestRecognizer: LocalSpeechRecognizing {
    var activity: (@MainActor (String, Bool) -> Void)?
    func start(
        receive: @escaping @MainActor (LocalSpeechEvent) -> Void,
        failure: @escaping @MainActor (String) -> Void
    ) async throws {}
    func stop() {}
}

@MainActor
final class SpeechHeaderLayoutTests: XCTestCase {
    func testCollapsedSpeechControlsFitOneRowWithoutStartingMicrophone() {
        let controller = SpeechFollowingController(recognizer: HeaderTestRecognizer())
        let host = NSHostingView(rootView: SpeechFollowingHeader(controller: controller))
        XCTAssertFalse(controller.enabled)
        XCTAssertGreaterThan(host.fittingSize.width, 60)
        XCTAssertLessThan(host.fittingSize.width, 180)
        XCTAssertLessThanOrEqual(host.fittingSize.height, 20)
    }
    func testEnabledSpeechHeaderDoesNotAddRowsOrExposeDiagnosticsInline() async {
        let controller = SpeechFollowingController(recognizer: HeaderTestRecognizer())
        let ready = expectation(description: "following ready without actual microphone")
        var fulfilled = false
        let observer = controller.$starting.sink {
            if !$0, controller.enabled, !fulfilled {
                fulfilled = true
                ready.fulfill()
            }
        }
        controller.setEnabled(true)
        await fulfillment(of: [ready], timeout: 2)
        observer.cancel()
        let host = NSHostingView(rootView: SpeechFollowingHeader(controller: controller))
        controller.inputStatus.heard = String(repeating: "recognized words ", count: 20)
        XCTAssertLessThan(host.fittingSize.width, 180)
        XCTAssertLessThanOrEqual(
            host.fittingSize.height, 20, "Long microphone diagnostics must not become extra answer rows")
        controller.stop()
    }
}
