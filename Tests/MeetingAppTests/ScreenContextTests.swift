import AppKit
import Combine
import XCTest

@testable import MeetingAssist

final class FeatureScreenCapture: WorkspaceCapturing {
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

@MainActor
final class ScreenContextTests: XCTestCase {
    static func image() throws -> CGImage {
        let context = try XCTUnwrap(
            CGContext(
                data: nil, width: 2, height: 2, bitsPerComponent: 8, bytesPerRow: 8,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        )
        return try XCTUnwrap(context.makeImage())
    }
    private func start(_ controller: ScreenContextController) async {
        let ready = expectation(description: "screen enabled")
        let observer = controller.$enabled.dropFirst().sink { if $0 { ready.fulfill() } }
        controller.start()
        await fulfillment(of: [ready], timeout: 2)
        observer.cancel()
    }
    func testSnapshotWaitsForFrameAndStopDiscardsIt() async throws {
        let capture = FeatureScreenCapture()
        let screen = ScreenContextController(
            captureFactory: { capture },
            analyzer: { _ in
                ScreenSnapshot(
                    jpeg: Data([1, 2]), text: "public class Main {}",
                    capturedAt: Date().addingTimeInterval(-20))
            })
        await start(screen)
        let waiting = Task { try await screen.snapshotForAnswer() }
        capture.frame?(try Self.image())
        let result = try await waiting.value
        XCTAssertTrue(result.hasCode)
        XCTAssertEqual(result.jpeg, Data([1, 2]))
        XCTAssertNotNil(screen.snapshot)
        let cached = try await screen.snapshotForAnswer()
        XCTAssertEqual(cached.jpeg, result.jpeg, "A healthy static screen keeps its current complete frame")
        screen.stop()
        XCTAssertNil(screen.snapshot)
        XCTAssertFalse(screen.enabled)
        do {
            _ = try await screen.snapshotForAnswer()
            XCTFail("Off capture must fail")
        } catch { XCTAssertTrue(error.localizedDescription.contains("off")) }
    }
    func testCancellationAndStopReleasePendingSnapshotRequests() async throws {
        let screen = ScreenContextController(captureFactory: { FeatureScreenCapture() })
        await start(screen)
        let waiting = Task { try await screen.snapshotForAnswer() }
        await Task.yield()
        waiting.cancel()
        do {
            _ = try await waiting.value
            XCTFail("Cancelled snapshot must fail")
        } catch { XCTAssertTrue(error is CancellationError) }
        let second = Task { try await screen.snapshotForAnswer() }
        await Task.yield()
        screen.stop()
        do {
            _ = try await second.value
            XCTFail("Stopped snapshot must fail")
        } catch { XCTAssertTrue(error is CancellationError) }
    }
    func testStaleCallbacksCannotReplaceNewScreenAndCaptureFailureClearsImage() async throws {
        let first = FeatureScreenCapture()
        let second = FeatureScreenCapture()
        var sources = [first, second]
        let screen = ScreenContextController(
            captureFactory: { sources.removeFirst() },
            analyzer: { _ in
                ScreenSnapshot(jpeg: Data([1]), text: "class Main {}", capturedAt: Date())
            })
        await start(screen)
        screen.stop()
        await start(screen)
        first.frame?(try Self.image())
        first.failure?("old failure")
        let frame = expectation(description: "new frame")
        let observer = screen.$snapshot.dropFirst().sink { if $0 != nil { frame.fulfill() } }
        second.frame?(try Self.image())
        await fulfillment(of: [frame], timeout: 2)
        observer.cancel()
        XCTAssertNil(screen.error)
        let failed = expectation(description: "current failure")
        let errorObserver = screen.$error.dropFirst().sink { if $0 != nil { failed.fulfill() } }
        second.failure?("capture stopped")
        await fulfillment(of: [failed], timeout: 2)
        errorObserver.cancel()
        XCTAssertNil(screen.snapshot)
        XCTAssertFalse(screen.enabled)
    }
    func testDeniedPermissionShowsShortReasonAndNeverEnablesCapture() async {
        let capture = FeatureScreenCapture()
        capture.startError = NSError(domain: "test", code: -3801)
        let screen = ScreenContextController(captureFactory: { capture })
        let failed = expectation(description: "permission failure")
        let observer = screen.$error.dropFirst().sink { if $0 != nil { failed.fulfill() } }
        screen.start()
        await fulfillment(of: [failed], timeout: 2)
        observer.cancel()
        XCTAssertTrue(screen.error?.contains("permission") == true)
        XCTAssertFalse(screen.enabled)
        XCTAssertNil(screen.snapshot)
    }
    func testSnapshotFingerprintIgnoresWhitespaceButTracksCodeChanges() {
        let first = ScreenSnapshot(jpeg: Data(), text: "class Main { return value; }", capturedAt: Date())
        let same = ScreenSnapshot(jpeg: Data([1]), text: "class Main {\n return value; }", capturedAt: Date())
        let changed = ScreenSnapshot(jpeg: Data(), text: "class Main { return result; }", capturedAt: Date())
        XCTAssertEqual(first.fingerprint, same.fingerprint)
        XCTAssertNotEqual(first.fingerprint, changed.fingerprint)
        let caseChanged = ScreenSnapshot(
            jpeg: Data(), text: "class main { return value; }", capturedAt: Date())
        XCTAssertNotEqual(first.fingerprint, caseChanged.fingerprint)
    }
    static func editorImage() throws -> CGImage {
        let bitmap = try XCTUnwrap(
            NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: 1400,
                pixelsHigh: 800, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        NSColor.white.setFill()
        NSRect(x: 0, y: 0, width: 1400, height: 800).fill()
        let code = """
            Main.java — Java editor
            Task: reverse a string without built-ins
            public class Main {
                public static String reverse(String input) {
                    // TODO: implement reversal
                    return input;
                }
            }
            """
        (code as NSString).draw(
            in: NSRect(x: 40, y: 90, width: 1300, height: 670),
            withAttributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 30, weight: .regular),
                .foregroundColor: NSColor.black,
            ])
        NSGraphicsContext.restoreGraphicsState()
        return try XCTUnwrap(bitmap.cgImage)
    }
    func testActualScreenshotEncodingAndOCRRecognizeVisibleCode() throws {
        let snapshot = try ScreenSnapshot.read(Self.editorImage())
        XCTAssertTrue(snapshot.hasCode)
        XCTAssertTrue(snapshot.text.split(whereSeparator: \.isWhitespace).joined().contains("Main.java"))
        XCTAssertTrue(snapshot.text.contains("return input"))
        XCTAssertNotNil(NSBitmapImageRep(data: snapshot.jpeg))
        XCTAssertLessThan(snapshot.jpeg.count, 1_000_000)
    }
    func testAlreadyCancelledSnapshotRequestFailsImmediately() async {
        let screen = ScreenContextController(captureFactory: { FeatureScreenCapture() })
        await start(screen)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await screen.snapshotForAnswer()
        }
        do {
            _ = try await task.value
            XCTFail("Pre-cancelled request must fail")
        } catch { XCTAssertTrue(error is CancellationError) }
        screen.stop()
    }
}
