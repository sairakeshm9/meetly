import Foundation

public enum TurnIntent: String, Sendable {
    case newQuestion, followUp, correction, incomplete, acknowledgement
    public var label: String {
        switch self {
        case .newQuestion: return "Question"
        case .followUp: return "Follow-up"
        case .correction: return "Correction"
        case .incomplete: return "Incomplete question"
        case .acknowledgement: return "Acknowledgement"
        }
    }
}

/// Fast, deterministic routing; semantic audio endpointing is a separate opt-in transport feature.
public enum ConversationRouter {
    public static func intent(_ text: String, hasContext: Bool) -> TurnIntent {
        let s = QuestionDetector.normalized(text)
        if s.isEmpty
            || [
                "thanks", "thank you", "okay", "ok", "yes", "no", "right", "got it", "that helps",
                "thanks that helps",
            ].contains(s)
        {
            return .acknowledgement
        }
        if ConversationRelation.startsNewTopic(text) { return .newQuestion }
        if hasContext
            && [
                "actually ", "no i mean ", "sorry i meant ", "instead ", "correction ", "i meant ",
                "that is wrong", "that s wrong", "not correct", "incorrect", "not satisfied",
                "i m not satisfied", "that does not answer", "that doesn t answer", "not what i asked",
                "give a better answer", "try again", "can you give a better answer",
                "please give a better answer", "that answer is wrong", "that answer is incorrect",
                "that is not correct", "that s not correct", "not good enough", "i am not satisfied",
                "i don t understand", "that doesn t make sense",
            ].contains(
                where: s.hasPrefix)
        {
            return .correction
        }
        if QuestionClarity.issue(text, hasContext: hasContext) != nil
            || [" and", " or", " because", " such as", " for example", " with", " using", " versus"].contains(
                where: s.hasSuffix)
        {
            return .incomplete
        }
        if hasContext
            && [
                "why", "how so", "why not", "what if", "and in", "but why", "an example", "another example",
                "without ", "with multiple", "what about", "time complexity", "space complexity", "is that",
                "does that", "can it", "could it", "and what", "and how", "explain that", "can you clarify",
                "clarify", "can you explain why", "more precisely", "wait ", "hold on", "but ",
            ].contains(where: s.hasPrefix)
        {
            return .followUp
        }
        return QuestionDetector.isCandidate(text, hasRecentQuestion: hasContext)
            ? .newQuestion : .acknowledgement
    }
    public static func isUrgent(_ text: String, intent: TurnIntent) -> Bool {
        intent == .correction
            || (intent == .followUp
                && ["why", "but why", "why not", "how so", "wait", "hold on"].contains(
                    where: QuestionDetector.normalized(text).hasPrefix))
    }
    public static func correcting(_ correction: String, previous: String) -> String {
        "Original request: \(previous.prefix(1800))\nCorrection: \(correction.prefix(1800))\nAnswer the corrected request. Discard incompatible assumptions in the original."
    }
}

public enum AnswerLayers {
    public static func cue(_ answer: String) -> String {
        let start = answer.range(of: "SAY THIS:")?.upperBound ?? answer.startIndex
        let end =
            ["EXAMPLE:", "DETAIL:"].compactMap {
                answer.range(of: $0, range: start..<answer.endIndex)?.lowerBound
            }.min() ?? answer.endIndex
        return String(answer[start..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    public static func example(_ answer: String) -> String {
        guard let start = answer.range(of: "EXAMPLE:")?.upperBound else { return "" }
        return String(answer[start...]).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

public struct PerformanceLedger: Sendable {
    public struct Sample: Sendable {
        public let route: String
        public let firstUseful: Double?
        public let total: Double
        public let failed: Bool
    }
    public private(set) var samples: [Sample] = []
    public private(set) var events: [String: Int] = [:]
    public init() {}
    public mutating func event(_ name: String) { events[name, default: 0] += 1 }
    public mutating func record(route: String, firstUseful: Double?, total: Double, failed: Bool) {
        samples.append(.init(route: route, firstUseful: firstUseful, total: max(0, total), failed: failed))
        if samples.count > 200 { samples.removeFirst(samples.count - 200) }
    }
    public func percentile(_ p: Double, route: String? = nil) -> Double? {
        let values = samples.filter { !$0.failed && (route == nil || $0.route == route) }
            .compactMap(\.firstUseful).filter { $0.isFinite && $0 >= 0 }.sorted()
        guard !values.isEmpty else { return nil }
        return values[max(0, Int(ceil(min(1, max(0, p)) * Double(values.count))) - 1)]
    }
}

public enum AudioHealth {
    public static func issue(now: Date, lastFrame: Date, startedAt: Date) -> String? {
        guard now.timeIntervalSince(startedAt) > 12, now.timeIntervalSince(lastFrame) > 12 else { return nil }
        return "Audio frames stopped. Refresh to reconnect."
    }
}

public enum AnswerQuality {
    public static func requiresStrongerModel(intent: TurnIntent, interrupted: Bool, requested: Bool) -> Bool {
        requested || interrupted || intent == .followUp || intent == .correction
    }
    public static let guidance = """
        Precision follow-up: answer the latest concern directly using the linked question and answer.
        Determine which of the last three questions/answers the latest question builds on, even if
        differently worded. Do not force an unrelated new topic into the linked answer.
        Re-check assumptions and technical accuracy before replying. Correct an earlier mistake
        explicitly when present; do not defend or repeat an incorrect claim. Distinguish verified facts,
        assumptions and tradeoffs. If essential context is missing, ask one Y/N clarification.
        Keep the spoken explanation around 70–120 words: 2–3 focused bullets and at most one tiny
        example if useful. No long DETAIL section, repeated versions or broad recap. This concise
        layout overrides a template requesting more detail. Preserve explanation-cue highlighting.
        Coding requests still require the complete relevant commented solution and next step;
        keep accompanying prose brief. Output one final answer with each section only once.
        """
}
