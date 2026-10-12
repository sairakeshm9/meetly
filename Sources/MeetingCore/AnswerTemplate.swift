import Foundation

public struct SavedAnswerTemplate: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public var name: String
    public var instructions: String
    public init(id: String = UUID().uuidString, name: String, instructions: String) {
        self.id = id
        self.name = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80))
        self.instructions = AnswerTemplate.normalizedCustom(instructions)
    }
}

public enum AnswerTemplate: String, CaseIterable, Codable, Sendable {
    case brief = "Brief bullets & comparisons"
    case layered = "Bullets, example & detail"
    case custom = "Custom template"

    public var description: String {
        switch self {
        case .brief: return "2–3 short bullets. Comparisons use a compact table; an example only when useful."
        case .custom: return "Describe your preferred answer format below, then save it."
        case .layered: return "2–3 short bullets first, then an example, then a more detailed explanation."
        }
    }
    public var guidance: String {
        switch self {
        case .brief:
            return """
                Answer template: start SAY THIS: with 2–3 short bullet points. For comparisons or
                different types, use a compact Markdown table with clear column headings and short
                cells, plus a brief takeaway bullet. Add EXAMPLE: only when useful or solving a coding
                task. Keep prose around 40–70 words. Omit DETAIL: unless explicitly asked to explain more.
                """
        case .custom:
            return "Use the saved custom answer format. Keep explanations clear and grounded."
        case .layered:
            return """
                Answer template: three sections in order. SAY THIS: contains 2–3 short bullet points.
                EXAMPLE: contains one concrete example. DETAIL: contains a short, more detailed
                explanation of why/how it works. For comparisons use a compact Markdown table in
                SAY THIS, with a brief takeaway bullet. Keep the initial bullets concise; aim for
                100–160 words of prose total, excluding code. Clearly separate the sections.
                """
        }
    }
    public static func normalizedCustom(_ text: String) -> String {
        String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(2000))
    }
    public func guidance(for question: String, customInstructions: String = "") -> String {
        if self == .custom {
            return
                "Custom answer format overrides default section labels, bullet counts, tables and example layout. Preserve clarity, grounding, actual coding solutions and Y/N clarifications. Follow this saved format:\n"
                + Self.normalizedCustom(customInstructions)
        }
        let q = QuestionDetector.normalized(question)
        let comparison = [
            "compare", "comparison", "difference between", "differences between", "versus", " vs ",
            "different types", "types of",
        ].contains(where: q.contains)
        guard comparison else { return guidance }
        return guidance
            + "\nThis is a comparison/types question: SAY THIS must contain a Markdown table with a header and --- separator row, followed by 2 short takeaway bullets. Do not substitute only prose bullets for the table."
    }
    public static let simpleRefresh = """
        Refresh override: explain the latest question again in simpler terms. Give 2–3 short bullets
        in SAY THIS: and one tiny EXAMPLE: only if helpful. No DETAIL section. Define each essential
        technical term in everyday language. Do not repeat the previous wording or stale answers.
        Keep prose under 70 words; still provide actual code if the question asks for a coding solution.
        """
}

public enum SharingSignal: Equatable, Sendable {
    case started, stopped, unknown
    public static func fromVisibleText(_ text: String) -> Self {
        let s = QuestionDetector.normalized(text)
        if [
            "screen sharing ended", "screen sharing stopped", "you stopped sharing",
            "you are no longer presenting",
        ].contains(where: s.contains) {
            return .stopped
        }
        if [
            "you are screen sharing", "you are sharing your screen", "you re sharing your screen",
            "you re presenting", "stop sharing", "stop presenting",
        ].contains(where: s.contains) {
            return .started
        }
        // Absence can mean the toolbar is hidden. Only recognize explicit idle meeting controls.
        if s.contains("share screen"), s.contains("participants"), s.contains("mute") {
            return .stopped
        }
        return .unknown
    }
}

public struct MarkdownAnswerTable: Equatable, Sendable {
    public let headers: [String]
    public let rows: [[String]]
    public static func parse(_ text: String) -> Self? {
        let lines = text.components(separatedBy: "\n").filter {
            !$0.trimmingCharacters(in: .whitespaces).isEmpty
        }
        guard lines.count >= 2 else { return nil }
        func cells(_ line: String) -> [String] {
            let value = line.trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "|"))
            return value.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
        }
        let headers = cells(lines[0])
        let separator = cells(lines[1])
        guard headers.count >= 2, headers.count <= 6, separator.count == headers.count,
            separator.allSatisfy({ $0.range(of: #"^:?-{3,}:?$"#, options: .regularExpression) != nil })
        else { return nil }
        let rows = lines.dropFirst(2).prefix(20).map(cells).filter { $0.count == headers.count }
        return .init(headers: headers, rows: rows)
    }
}
