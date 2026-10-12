import AppKit
import XCTest

@testable import MeetingAssist

final class AppPresenceTests: XCTestCase {
    @MainActor
    func testInstalledAgentPresence() throws {
        guard ProcessInfo.processInfo.environment["MEETING_ASSIST_PRESENCE_APP_CHECK"] == "1" else {
            throw XCTSkip("Opt-in installed-app process metadata check")
        }
        let target = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Applications/Meetly.app")
        let running = try XCTUnwrap(
            NSRunningApplication.runningApplications(withBundleIdentifier: "com.akshay.meetingassist")
                .first(where: { $0.bundleURL?.standardizedFileURL == target.standardizedFileURL }))
        XCTAssertEqual(running.activationPolicy, .accessory)
        XCTAssertFalse(running.isTerminated)
        let bundle = try XCTUnwrap(Bundle(url: target))
        XCTAssertEqual(bundle.object(forInfoDictionaryKey: "LSUIElement") as? Bool, true)
    }
    func testAccessoryPresenceDoesNotTerminateWhenWindowCloses() {
        XCTAssertEqual(AssistantPresence.activationPolicy, .accessory)
        XCTAssertFalse(AssistantPresence.terminateAfterLastWindowClosed)
        XCTAssertEqual(AssistantPresence.windowID, "assistant")
    }
    @MainActor
    func testReopeningWindowPreservesSessionAndDoesNotRepeatStartupPrompt() {
        let model = MeetingModel()
        model.presentPreparationAtLaunch()
        XCTAssertEqual(model.sheet, .preparation)
        model.finishPreparation()
        model.preview()
        let questionID = model.cards.last?.id
        model.projectNotes = "User supplied test incident"
        model.presentPreparationAtLaunch()
        XCTAssertNil(model.sheet)
        XCTAssertEqual(model.cards.last?.id, questionID)
        XCTAssertEqual(model.projectNotes, "User supplied test incident")
        XCTAssertTrue(model.captureExclusion)
    }
}
