import Foundation
import LocalAuthentication
import Security
import XCTest

@testable import MeetingAssist

final class LiveSpeechTests: XCTestCase {
    func testOptInRealAPIStreamWithoutAudioCaptureOrPlayback() async throws {
        guard ProcessInfo.processInfo.environment["MEETLY_LIVE_SPEECH_CHECK"] == "1" else {
            throw XCTSkip(
                "Set MEETLY_LIVE_SPEECH_CHECK=1 for a small paid voice request; no recording or playback.")
        }
        let context = LAContext()
        context.interactionNotAllowed = true
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.akshay.meetingassist", kSecAttrAccount as String: "openai",
            kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseAuthenticationContext as String: context,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
            let data = item as? Data, let key = String(data: data, encoding: .utf8), !key.isEmpty
        else { throw XCTSkip("Saved key unavailable without a security prompt.") }
        let request = try APISpeechRequest.make(
            text:
                "A transaction keeps database changes together. Both updates succeed, or both are rolled back.",
            voice: "marin", pace: 1, key: key, realtime: true)
        let timing = SpeechStreamTiming()
        try await APISpeechStream().stream(request) { data in await timing.add(data) }
        let result = await timing.result()
        XCTAssertGreaterThan(result.bytes, 4800)
        XCTAssertTrue(result.bytes.isMultiple(of: 2))
        XCTAssertGreaterThan(result.chunks, 1)
        print(
            "Speech API verified: first PCM \(result.first) seconds, total \(result.elapsed) seconds, \(result.bytes) bytes; no audio playback."
        )
    }
}
private actor SpeechStreamTiming {
    let start = Date()
    var first = 0.0
    var bytes = 0
    var chunks = 0
    func add(_ data: Data) {
        if chunks == 0 { first = Date().timeIntervalSince(start) }
        bytes += data.count
        chunks += 1
    }
    func result() -> (first: Double, elapsed: Double, bytes: Int, chunks: Int) {
        (first, Date().timeIntervalSince(start), bytes, chunks)
    }
}
