import AppKit
import Combine
import XCTest

@testable import MeetingAssist

final class CaptureProtectionTests: XCTestCase {
    @MainActor
    func testCaptureDeadlineAndLateCallbackAreSafe() async {
        let pending = CaptureWaiter<Int>()
        do {
            let _: Int = try await withCheckedThrowingContinuation { pending.begin($0, seconds: 0) }
            XCTFail("A stalled capture must time out")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("did not respond"))
        }
        pending.finish(.success(1))
        pending.finish(.failure(CancellationError()))
    }
    @MainActor
    func testCaptureCompletionAndCancellationOnlyResumeOnce() async throws {
        let pending = CaptureWaiter<Int>()
        let value: Int = try await withCheckedThrowingContinuation {
            pending.begin($0)
            pending.finish(.success(7))
            pending.finish(.success(8))
        }
        XCTAssertEqual(value, 7)
        let cancelled = CaptureWaiter<Int>()
        do {
            let _: Int = try await withCheckedThrowingContinuation {
                cancelled.begin($0)
                cancelled.finish(.failure(CancellationError()))
            }
            XCTFail("Cancellation must end the capture")
        } catch { XCTAssertTrue(error is CancellationError) }
        cancelled.finish(.success(9))
    }
    func testSuccessfulControlsRequiredBeforeReportingHidden() {
        XCTAssertEqual(
            CaptureProtectionResult.evaluate(baseline: true, protected: false, control: true), .hidden)
        XCTAssertEqual(
            CaptureProtectionResult.evaluate(baseline: true, protected: true, control: true), .visible)
        for (baseline, control) in [(false, true), (true, false), (false, false)] {
            for protected in [true, false] {
                if case .inconclusive = CaptureProtectionResult.evaluate(
                    baseline: baseline, protected: protected, control: control)
                {
                } else {
                    XCTFail("Missing controls must never imply privacy")
                }
            }
        }
    }
    func testStatusNeverPromisesUniversalInvisibility() {
        XCTAssertTrue(CaptureProtectionResult.notTested.message.contains("not tested"))
        XCTAssertTrue(CaptureProtectionResult.hidden.message.contains("Confirm with a meeting viewer"))
        XCTAssertTrue(CaptureProtectionResult.visible.message.contains("not confirmed"))
        XCTAssertTrue(
            CaptureProtectionResult.inconclusive("Permission denied").message.contains("Permission denied"))
    }
    @MainActor
    func testWindowAttachmentReattachmentAndActivationRequestExclusion() {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let view = ProtectionView()
        window.contentView = view
        XCTAssertEqual(window.sharingType, .none)
        view.enabled = false
        view.protectWindow()
        XCTAssertEqual(window.sharingType, .readOnly)
        view.enabled = true
        view.protectWindow()
        XCTAssertEqual(window.sharingType, .none)
        window.sharingType = .readOnly
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: window)
        XCTAssertEqual(window.sharingType, .none)
        window.contentView = nil
        window.sharingType = .readOnly
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: window)
        XCTAssertEqual(window.sharingType, .readOnly)
        window.contentView = view
        XCTAssertEqual(window.sharingType, .none)
        let workspace = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false)
        workspace.isReleasedWhenClosed = false
        defer { workspace.close() }
        XCTAssertEqual(workspace.sharingType, .readOnly, "Unattached workspace must remain shareable")
    }
    @MainActor
    func testFailureRecoveryAndDuplicateClick() async {
        var calls = 0
        let controller = CaptureProtectionController {
            calls += 1
            if calls == 1 { throw CaptureProtectionProbe.ProbeError.permission }
            return .visible
        }
        let first = expectation(description: "Permission failure reported")
        let observer = controller.$testing.dropFirst().sink { if !$0 { first.fulfill() } }
        controller.test()
        controller.test()
        await fulfillment(of: [first], timeout: 2)
        observer.cancel()
        XCTAssertEqual(calls, 1)
        if case .inconclusive(let reason) = controller.result {
            XCTAssertTrue(reason.contains("Screen Recording"))
        } else {
            XCTFail("Permission error must be shown")
        }
        let second = expectation(description: "Retry completed")
        let retryObserver = controller.$testing.dropFirst().sink { if !$0 { second.fulfill() } }
        controller.test()
        await fulfillment(of: [second], timeout: 2)
        retryObserver.cancel()
        XCTAssertEqual(controller.result, .visible)
        XCTAssertFalse(controller.testing)
    }
    @MainActor
    func testStopDiscardsCancelledResult() async {
        var continuation: CheckedContinuation<CaptureProtectionResult, Never>?
        let started = expectation(description: "Probe started")
        let controller = CaptureProtectionController {
            await withCheckedContinuation {
                continuation = $0
                started.fulfill()
            }
        }
        controller.test()
        await fulfillment(of: [started], timeout: 2)
        controller.stop()
        continuation?.resume(returning: .hidden)
        let drained = expectation(description: "Cancelled task drained")
        Task { @MainActor in drained.fulfill() }
        await fulfillment(of: [drained], timeout: 2)
        XCTAssertEqual(controller.result, .notTested)
        XCTAssertFalse(controller.testing)
    }
}
