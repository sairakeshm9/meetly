import AppKit
import Combine
import MeetingCore
import XCTest

@testable import MeetingAssist

private final class MockWorkspaceCapture: WorkspaceCapturing {
    var frame: ((CGImage) -> Void)?
    var failure: ((String) -> Void)?
    var startError: Error?
    func start(onFrame: @escaping (CGImage) -> Void, onFailure: @escaping (String) -> Void) async throws {
        frame = onFrame
        failure = onFailure
        if let startError { throw startError }
    }
    func stop() async {}
}

final class WorkspaceSharingTests: XCTestCase {
    func testVideoConfigurationIsBoundedAndDoesNotCaptureMeetingAudio() {
        let config = WorkspaceScreenCapture.configuration(width: 3840, height: 2160)
        XCTAssertEqual(config.width, 1600)
        XCTAssertEqual(config.height, 900)
        XCTAssertFalse(config.capturesAudio)
        XCTAssertEqual(config.minimumFrameInterval.seconds, 1.0 / 15, accuracy: 0.001)
        let portrait = WorkspaceScreenCapture.configuration(width: 1000, height: 3000)
        XCTAssertEqual(portrait.height, 1600)
        XCTAssertGreaterThan(portrait.width, 0)
    }
    private func image() throws -> CGImage {
        let context = try XCTUnwrap(
            CGContext(
                data: nil, width: 2, height: 2, bitsPerComponent: 8, bytesPerRow: 8,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        )
        return try XCTUnwrap(context.makeImage())
    }
    @MainActor
    func testWorkspaceStopAndRestartDiscardStaleFramesAndFailures() async throws {
        let first = MockWorkspaceCapture()
        let second = MockWorkspaceCapture()
        var captures = [first, second]
        let controller = WorkspaceController(
            captureFactory: { captures.removeFirst() }, windowFactory: { nil })
        for capture in [first, second] {
            let active = expectation(description: "workspace active")
            let observer = controller.$active.dropFirst().sink { if $0 { active.fulfill() } }
            controller.open()
            await fulfillment(of: [active], timeout: 2)
            observer.cancel()
            let rendered = expectation(description: "frame rendered")
            let frameObserver = controller.$image.dropFirst().sink { if $0 != nil { rendered.fulfill() } }
            capture.frame?(try image())
            await fulfillment(of: [rendered], timeout: 2)
            frameObserver.cancel()
            XCTAssertNotNil(controller.image)
            controller.stop()
            XCTAssertNil(controller.image)
            XCTAssertFalse(controller.active)
        }
        first.frame?(try image())
        first.failure?("old failure")
        let delivered = expectation(description: "queued callbacks drained")
        Task { @MainActor in delivered.fulfill() }
        await fulfillment(of: [delivered], timeout: 2)
        XCTAssertNil(controller.image)
        XCTAssertNil(controller.error)
    }
    @MainActor
    func testCaptureFailureClearsLastFrameAndProvidesRecovery() async throws {
        let capture = MockWorkspaceCapture()
        let controller = WorkspaceController(captureFactory: { capture }, windowFactory: { nil })
        let active = expectation(description: "workspace started")
        let observer = controller.$active.dropFirst().sink { if $0 { active.fulfill() } }
        controller.open()
        await fulfillment(of: [active], timeout: 2)
        observer.cancel()
        let failed = expectation(description: "capture failure reported")
        let errorObserver = controller.$error.dropFirst().sink { if $0 != nil { failed.fulfill() } }
        capture.failure?("Reopen workspace")
        await fulfillment(of: [failed], timeout: 2)
        XCTAssertNil(controller.image)
        XCTAssertFalse(controller.active)
        XCTAssertEqual(controller.error, "Reopen workspace")
        errorObserver.cancel()
        controller.stop()
    }
    @MainActor
    func testPermissionFailureDoesNotLeaveWorkspaceActive() async {
        let capture = MockWorkspaceCapture()
        capture.startError = MeetingError.message("Permission denied")
        let controller = WorkspaceController(captureFactory: { capture }, windowFactory: { nil })
        let failed = expectation(description: "permission error")
        let observer = controller.$error.dropFirst().sink { if $0 != nil { failed.fulfill() } }
        controller.open()
        await fulfillment(of: [failed], timeout: 2)
        XCTAssertFalse(controller.active)
        XCTAssertFalse(controller.starting)
        XCTAssertNil(controller.image)
        XCTAssertTrue(controller.error?.contains("permission") ?? false)
        withExtendedLifetime(observer) {}
        controller.stop()
    }
}
