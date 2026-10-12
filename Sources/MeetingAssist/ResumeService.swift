import Foundation
import MeetingCore
import PDFKit

enum ResumeFile {
    static func read(_ url: URL) async throws -> String {
        try await Task.detached(priority: .userInitiated) {
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size > 0, size <= 10 * 1024 * 1024 else {
                throw MeetingError.message("Choose a non-empty resume under 10 MB.")
            }
            let source: String
            switch url.pathExtension.lowercased() {
            case "pdf":
                guard let document = PDFDocument(url: url), !document.isLocked, document.pageCount <= 50
                else {
                    throw MeetingError.message(
                        "Cannot read this PDF. Unlock it or use a resume under 50 pages.")
                }
                source = document.string ?? ""
            case "txt": source = try String(contentsOf: url, encoding: .utf8)
            default: throw MeetingError.message("Choose a PDF or UTF-8 TXT resume.")
            }
            return try ResumeText.prepare(source)
        }.value
    }
}

enum ResumeService {
    static func analyze(
        key: String, model: String, text: String, session: URLSession = .shared,
        endpoint: URL = URL(string: "https://api.openai.com/v1/responses")!
    ) async throws -> ResumeAnalysis {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.setValue("Bearer " + key, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try ResumeRequest.body(model: model, text: text)
        let (data, response) = try await session.data(for: request)
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse else {
            throw MeetingError.message("Invalid resume analysis response.")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw MeetingError.message(APIRequest.error(status: http.statusCode, key: key, body: Data()))
        }
        return try ResumeRequest.decode(data, source: text)
    }
}
