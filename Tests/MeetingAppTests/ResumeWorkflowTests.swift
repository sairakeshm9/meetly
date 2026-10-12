import Combine
import MeetingCore
import XCTest

@testable import MeetingAssist

final class ResumeWorkflowTests: XCTestCase {
    private let source =
        "Java engineer. Built a Spring Boot payments service. Investigated Kafka lag caused by a slow database query."
    private func file(_ content: String, extension suffix: String = "txt") throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(suffix)
        try Data(content.utf8).write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
    @MainActor
    func testStartupAsksOncePerLaunchAndProfileIsNotRestoredFromDefaults() {
        let model = MeetingModel()
        model.presentPreparationAtLaunch()
        XCTAssertEqual(model.sheet, .preparation)
        model.finishPreparation()
        model.presentPreparationAtLaunch()
        XCTAssertNil(model.sheet)
        let relaunched = MeetingModel()
        relaunched.presentPreparationAtLaunch()
        XCTAssertEqual(relaunched.sheet, .preparation)
        XCTAssertNil(relaunched.resumeProfile)
        XCTAssertTrue(relaunched.projectNotes.isEmpty)
    }
    func testTextResumeReadsAndUnreadableFilesFail() async throws {
        let text = try await ResumeFile.read(file(source))
        XCTAssertEqual(text, source)
        for url in [try file(""), try file("invalid", extension: "pdf"), try file(source, extension: "docx")]
        {
            do {
                _ = try await ResumeFile.read(url)
                XCTFail("Invalid file should fail")
            } catch { XCTAssertFalse(error.localizedDescription.isEmpty) }
        }
    }
    @MainActor
    func testUploadAnalysisPopulatesReadyContextWithoutPersistingResume() async throws {
        let expected = ResumeAnalysis(
            skills: ["Java"],
            projects: [
                .init(
                    name: "Payments", summary: "Spring Boot service",
                    evidence: "Built a Spring Boot payments service.")
            ], incidents: [])
        let model = MeetingModel(
            credentials: CredentialAccess { "test-only" },
            resumeAnalyzer: { key, _, text in
                XCTAssertEqual(key, "test-only")
                XCTAssertEqual(text, self.source)
                return expected
            })
        model.hasKey = true
        let ready = expectation(description: "resume ready")
        let observer = model.$resumeLoading.dropFirst().sink { if !$0 { ready.fulfill() } }
        let url = try file(source)
        model.prepareResume(url)
        await fulfillment(of: [ready], timeout: 2)
        XCTAssertEqual(model.resumeProfile, expected)
        XCTAssertEqual(model.resumeName, url.lastPathComponent)
        XCTAssertEqual(model.currentProject, "Payments")
        model.projectNotes = "Payment timeouts: added an index to the slow lookup."
        XCTAssertTrue(model.answerBackground.contains("Payment timeouts"))
        XCTAssertTrue(model.answerBackground.contains("Project: Payments"))
        XCTAssertLessThanOrEqual(model.answerBackground.count, 10000)
        withExtendedLifetime(observer) {}
    }
    @MainActor
    func testSkippingDuringAnalysisCannotApplyLateResult() async throws {
        var pending: CheckedContinuation<ResumeAnalysis, Error>?
        let started = expectation(description: "analysis started")
        let returned = expectation(description: "late analysis returned")
        let model = MeetingModel(
            credentials: CredentialAccess { "test-only" },
            resumeAnalyzer: { _, _, _ in
                defer { returned.fulfill() }
                return try await withCheckedThrowingContinuation { continuation in
                    pending = continuation
                    started.fulfill()
                }
            })
        model.hasKey = true
        model.prepareResume(try file(source))
        await fulfillment(of: [started], timeout: 2)
        model.finishPreparation()
        pending?.resume(returning: ResumeAnalysis(skills: ["Java"], projects: [], incidents: []))
        await fulfillment(of: [returned], timeout: 2)
        XCTAssertFalse(model.resumeLoading)
        XCTAssertNil(model.resumeProfile)
        XCTAssertNil(model.sheet)
    }
    @MainActor
    func testMissingKeyAndActiveMeetingBlockResumeChanges() throws {
        let model = MeetingModel()
        model.hasKey = false
        model.prepareResume(try file(source))
        XCTAssertTrue(model.resumeError?.contains("API key") ?? false)
        XCTAssertFalse(model.resumeLoading)
        model.hasKey = true
        model.listening = true
        model.prepareResume(try file(source))
        XCTAssertTrue(model.resumeError?.contains("Stop listening") ?? false)
        XCTAssertFalse(model.resumeLoading)
        model.listening = false
    }
    func testResumeServiceHonorsHTTPErrorAndCompletedJSONContract() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockHTTP.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let analysis = ResumeAnalysis(skills: ["Java"], projects: [], incidents: [])
        let json = String(decoding: try JSONEncoder().encode(analysis), as: UTF8.self)
        MockHTTP.status = 200
        MockHTTP.payload = String(
            decoding: try JSONSerialization.data(withJSONObject: [
                "status": "completed", "output": [["content": [["type": "output_text", "text": json]]]],
            ]), as: UTF8.self)
        let result = try await ResumeService.analyze(
            key: "test-only", model: "gpt-6-luna", text: source, session: session)
        XCTAssertEqual(result, analysis)
        MockHTTP.status = 401
        MockHTTP.payload = "private-provider-body"
        do {
            _ = try await ResumeService.analyze(
                key: "test-only", model: "gpt-6-luna", text: source, session: session)
            XCTFail("Auth failure must fail")
        } catch {
            XCTAssertFalse(error.localizedDescription.contains("private-provider-body"))
            XCTAssertTrue(error.localizedDescription.contains("key"))
        }
    }
}
