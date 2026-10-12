import Foundation
import MeetingCore

struct CodeCheckResult: Equatable, Sendable {
    let label: String
    let details: String
    let successful: Bool
}

enum CodeValidation {
    static func checkJava(_ source: String, run: Bool = false, expected: String = "") async throws
        -> CodeCheckResult
    {
        let check = Task.detached { () throws -> CodeCheckResult in
            try Task.checkCancellation()
            let match = source.range(
                of: #"\b(?:public\s+)?class\s+[A-Za-z_$][\w$]*"#, options: .regularExpression)
            guard let match, source.utf8.count <= 64000, !source.contains("package ") else {
                throw MeetingError.message(
                    "Use a standalone Java class without a package; project builds stay in your IDE.")
            }
            let name = source[match].split(whereSeparator: \.isWhitespace).last.map(String.init)!
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(
                "meeting-check-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            try Data(source.utf8).write(to: root.appendingPathComponent(name + ".java"))
            let jdk = try execute("/usr/libexec/java_home", [], root: root, sandbox: false).details
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard jdk.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: jdk + "/bin/javac") else {
                throw MeetingError.message("Java compiler missing. Install a JDK to validate Java.")
            }
            let compiled = try execute(
                jdk + "/bin/javac",
                [
                    "-J-Xmx128m", "-proc:none", "-d", root.path,
                    root.appendingPathComponent(name + ".java").path,
                ], root: root, jdk: jdk)
            guard compiled.successful else {
                return .init(label: "Compile failed", details: compiled.details, successful: false)
            }
            guard run else {
                return .init(
                    label: "Compiled · tests not run",
                    details: "Standalone Java compilation passed. This does not prove correctness.",
                    successful: true)
            }
            let output = try execute(
                jdk + "/bin/java", ["-Xmx128m", "-cp", root.path, name], root: root, jdk: jdk)
            guard output.successful else {
                return .init(label: "Sample failed", details: output.details, successful: false)
            }
            guard !expected.isEmpty else {
                return .init(label: "Sample ran · no assertion", details: output.details, successful: true)
            }
            let passed =
                output.details.trimmingCharacters(in: .whitespacesAndNewlines)
                == expected.trimmingCharacters(in: .whitespacesAndNewlines)
            return .init(
                label: passed ? "Sample assertion passed" : "Sample assertion failed",
                details: output.details, successful: passed)
        }
        return try await withTaskCancellationHandler {
            try await check.value
        } onCancel: {
            check.cancel()
        }
    }
    private static func execute(
        _ executable: String, _ arguments: [String], root: URL, jdk: String = "", sandbox: Bool = true
    ) throws -> CodeCheckResult {
        let process = Process()
        let outputURL = root.appendingPathComponent(UUID().uuidString + ".txt")
        FileManager.default.createFile(atPath: outputURL.path, contents: nil)
        let handle = try FileHandle(forWritingTo: outputURL)
        defer { try? handle.close() }
        process.currentDirectoryURL = root
        process.standardOutput = handle
        process.standardError = handle
        process.environment = [
            "PATH": "/usr/bin:/bin", "HOME": root.path, "TMPDIR": root.path, "LANG": "en_US.UTF-8",
        ]
        if sandbox {
            guard FileManager.default.isExecutableFile(atPath: "/usr/bin/sandbox-exec") else {
                throw MeetingError.message("Isolated code runner unavailable on this Mac.")
            }
            func quote(_ path: String) -> String {
                "\""
                    + path.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(
                        of: "\"", with: "\\\"") + "\""
            }
            // Foundation can preserve /var aliases here; the sandbox matches the actual /private/var path.
            guard let resolved = realpath(root.path, nil) else {
                throw MeetingError.message("Temporary code folder unavailable.")
            }
            let sandboxRoot = String(cString: resolved)
            free(resolved)
            let profile =
                "(version 1)(deny default)(allow process-exec)(allow process-fork)(allow sysctl-read)(allow mach-lookup)(allow file-read-metadata)(allow file-read* (literal \"/\") (subpath \(quote(jdk))) (subpath \"/System\") (subpath \"/usr\") (subpath \"/private/var/db\") (subpath \"/dev\") (subpath \(quote(sandboxRoot))))(allow file-write* (subpath \(quote(sandboxRoot))) (literal \"/dev/null\"))"
            process.executableURL = URL(fileURLWithPath: "/usr/bin/sandbox-exec")
            process.arguments = ["-p", profile, executable] + arguments
        } else {
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
        }
        try process.run()
        let deadline = Date().addingTimeInterval(10)
        while process.isRunning {
            if Date() >= deadline || Task.isCancelled
                || ((try? outputURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) > 64000
            {
                process.terminate()
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                process.waitUntilExit()
                throw MeetingError.message("Code check stopped: time or output limit reached.")
            }
            Thread.sleep(forTimeInterval: 0.02)
        }
        process.waitUntilExit()
        let output = SecretRedactor.clean(
            (try? String(contentsOf: outputURL, encoding: .utf8)) ?? "", maxLength: 6000)
        return .init(label: "Process completed", details: output, successful: process.terminationStatus == 0)
    }
}
