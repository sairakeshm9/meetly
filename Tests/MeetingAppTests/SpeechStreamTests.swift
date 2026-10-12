import Foundation
import XCTest

@testable import MeetingAssist

final class SpeechStreamTests: XCTestCase {
    private func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [SpeechFixtureProtocol.self]
        return URLSession(configuration: config)
    }
    func testPCMIsDeliveredIncrementallyWithAlignedFinalBlock() async throws {
        let client = session()
        defer { client.invalidateAndCancel() }
        let recorder = PCMRecorder()
        try await APISpeechStream(session: client).stream(
            URLRequest(url: URL(string: "https://speech.test/ok")!)
        ) { await recorder.append($0) }
        let sizes = await recorder.sizes
        XCTAssertEqual(sizes, [4800, 4800, 2])
    }
    func testRejectedEmptyWrongFormatAndTruncatedResponsesFail() async {
        for path in ["denied", "empty", "json", "odd"] {
            let client = session()
            defer { client.invalidateAndCancel() }
            do {
                try await APISpeechStream(session: client).stream(
                    URLRequest(url: URL(string: "https://speech.test/" + path)!)
                ) { _ in }
                XCTFail("Invalid response accepted: \(path)")
            } catch { XCTAssertFalse(error.localizedDescription.isEmpty) }
        }
    }
}
private actor PCMRecorder {
    var sizes: [Int] = []
    func append(_ data: Data) { sizes.append(data.count) }
}
private final class SpeechFixtureProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "speech.test" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let path = request.url!.lastPathComponent
        let response = HTTPURLResponse(
            url: request.url!, statusCode: path == "denied" ? 403 : 200, httpVersion: nil,
            headerFields: ["Content-Type": path == "json" ? "application/json" : "audio/pcm"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        let count = path == "empty" ? 0 : path == "odd" ? 3 : 9602
        client?.urlProtocol(self, didLoad: Data(repeating: 0, count: count))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
