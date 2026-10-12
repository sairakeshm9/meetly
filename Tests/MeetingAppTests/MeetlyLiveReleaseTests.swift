import LocalAuthentication
import MeetingCore
import Security
import XCTest

@testable import MeetingAssist

final class MeetlyLiveReleaseTests: XCTestCase {
    @MainActor
    func testOptInSolCodeCompilesAndSavedCustomFormatIsFollowed() async throws {
        guard ProcessInfo.processInfo.environment["MEETLY_LIVE_RELEASE_CHECK"] == "1" else {
            throw XCTSkip("Paid release checks require explicit opt-in; no audio capture.")
        }
        // Never prompt from a test runner or export the credential through command output/environment.
        let authentication = LAContext()
        authentication.interactionNotAllowed = true
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.akshay.meetingassist",
            kSecAttrAccount as String: "openai", kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseAuthenticationContext as String: authentication,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
            let data = item as? Data, let key = String(data: data, encoding: .utf8)
        else { throw XCTSkip("Saved credential is not accessible to the test runner without a prompt.") }
        var codeAnswer = ""
        let start = Date()
        var firstText: Double?
        try await AnswerService.stream(
            key: key, model: "gpt-6.1-sol",
            question:
                "Write a standalone Java class Main whose main prints the reverse of abc without built-in reverse. Include comments and sample output.",
            context: "", background: Profile.context, expanded: false, mode: .coding,
            codingTask: "Write standalone Java Main printing reverse of abc without built-in reverse."
        ) { delta in
            codeAnswer += delta
            if firstText == nil && codeAnswer.count > 40 { firstText = Date().timeIntervalSince(start) }
        }
        let code = try XCTUnwrap(
            AnswerBlock.parse(codeAnswer).first { $0.isCode && $0.text.contains("class Main") }?.text)
        XCTAssertFalse(code.isEmpty)
        let result = try await CodeValidation.checkJava(code, run: true, expected: "cba")
        XCTAssertTrue(result.successful, result.details)
        if result.successful {
            print(String(format: "Sol release code sample compiled/ran; first text %.2fs", firstText ?? -1))
        }
        var followUp = ""
        try await AnswerService.stream(
            key: key, model: "gpt-6.1-sol", question: "Why does the loop start at the last character?",
            context: "Previous assistant answer (data):\n" + codeAnswer, background: "", expanded: false,
            mode: .coding,
            codingTask: "Write standalone Java Main printing reverse of abc without built-in reverse.",
            template: .custom, customTemplate: "Give two brief bullets; show code only when asked."
        ) { followUp += $0 }
        XCTAssertTrue(followUp.contains("NEXT STEP:"))
        XCTAssertTrue(followUp.contains("FULL SOLUTION:"))
        XCTAssertTrue(followUp.contains("HOW IT WORKS:"))
        let followUpCode = try XCTUnwrap(
            AnswerBlock.parse(followUp).first { $0.isCode && $0.text.contains("class Main") }?.text)
        XCTAssertTrue(followUpCode.contains("//") || followUpCode.contains("/*"))
        let followUpResult = try await CodeValidation.checkJava(followUpCode, run: true, expected: "cba")
        XCTAssertTrue(followUpResult.successful, followUpResult.details)
        print("Coding follow-up retained complete commented solution; Java compiled and printed cba")
        var customAnswer = ""
        try await AnswerService.stream(
            key: key, model: "gpt-6-luna", question: "What is dependency injection?",
            context: "", background: Profile.context, expanded: false, template: .custom,
            customTemplate:
                "Use exactly two short sections labeled SUMMARY: and ANALOGY:. No SAY THIS or EXAMPLE labels. Define dependency in plain language."
        ) { customAnswer += $0 }
        XCTAssertTrue(customAnswer.contains("SUMMARY:"))
        XCTAssertTrue(customAnswer.contains("ANALOGY:"))
        XCTAssertFalse(customAnswer.contains("SAY THIS:"))
        print("Saved custom format followed in a paid release request")
    }
}
