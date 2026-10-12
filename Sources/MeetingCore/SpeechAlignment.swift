import Foundation
import NaturalLanguage

public struct SpeechPassage: Equatable, Sendable, Identifiable {
    public enum Kind: Sendable { case prose, code, table }
    public let id: Int
    public let text: String
    public let kind: Kind
    public let blockIndex: Int
    public let plainRange: NSRange
    public let terms: Set<String>
    public let negative: Bool
    public var trackable: Bool { terms.count >= 2 }
}

/// Pre-index an answer once; matching uses only local words, concepts and nearby position.
public struct SpeechDocument: Sendable {
    public let passages: [SpeechPassage]
    public let blocks: [AnswerBlock]
    private let index: [String: Set<Int>]
    public init(_ answer: String) {
        blocks = AnswerBlock.parse(answer)
        var rows: [(String, SpeechPassage.Kind, Int, NSRange)] = []
        for (blockIndex, block) in blocks.enumerated() {
            if Task.isCancelled { break }
            let plain = block.isCode ? block.text : SpeechWords.plain(block.text)
            if block.isCode || MarkdownAnswerTable.parse(block.text) != nil {
                rows.append(
                    (
                        plain, block.isCode ? .code : .table, blockIndex,
                        NSRange(location: 0, length: plain.utf16.count)
                    ))
            } else {
                var lineStart = 0
                for line in plain.components(separatedBy: "\n") {
                    if Task.isCancelled { break }
                    let tokenizer = NLTokenizer(unit: .sentence)
                    tokenizer.string = line
                    tokenizer.enumerateTokens(in: line.startIndex..<line.endIndex) { range, _ in
                        var location = NSRange(range, in: line)
                        location.location += lineStart
                        rows.append((String(line[range]), .prose, blockIndex, location))
                        return true
                    }
                    lineStart += line.utf16.count + 1
                }
            }
        }
        passages = rows.enumerated().map { id, row in
            SpeechPassage(
                id: id, text: row.0, kind: row.1, blockIndex: row.2, plainRange: row.3,
                terms: SpeechWords.terms(row.0), negative: SpeechWords.negative(row.0))
        }
        var lookup: [String: Set<Int>] = [:]
        for passage in passages where passage.trackable {
            for term in passage.terms { lookup[term, default: []].insert(passage.id) }
        }
        index = lookup
    }
    public func match(_ spoken: String, current: Int?) -> Int? {
        let latest = SpeechWords.latestPhrase(String(spoken.suffix(800)))
        let recent = Array(SpeechWords.contentWords(latest).suffix(18))
        let words = Set(recent)
        guard words.count >= 2 else { return nil }
        let negative = SpeechWords.negative(latest)
        let candidates = words.reduce(into: Set<Int>()) { $0.formUnion(index[$1] ?? []) }
        var scores: [(Int, Double)] = []
        for id in candidates {
            let passage = passages[id]
            let overlap = words.intersection(passage.terms)
            guard overlap.count >= 2 else { continue }
            // A negation must not silently mark a contradictory answer as covered.
            guard negative == passage.negative || passage.kind != .prose else { continue }
            func weight(_ term: String) -> Double {
                let recency =
                    0.25 + 0.75 * Double((recent.lastIndex(of: term) ?? 0) + 1) / Double(recent.count)
                return (1 + log(Double(passages.count + 1) / Double((index[term]?.count ?? 0) + 1))) * recency
            }
            let coverage = overlap.reduce(0) { $0 + weight($1) } / words.reduce(0) { $0 + weight($1) }
            let passageCoverage = Double(overlap.count) / Double(passage.terms.count)
            let score = coverage * 0.8 + min(1, passageCoverage) * 0.2
            guard score >= 0.48 else { continue }
            let proximity = current.map { abs(id - $0) <= 1 ? 0.06 : 0 } ?? 0
            scores.append((id, score + proximity))
        }
        scores.sort { $0.1 == $1.1 ? $0.0 < $1.0 : $0.1 > $1.1 }
        guard let best = scores.first else { return nil }
        if scores.count > 1, best.1 - scores[1].1 < 0.05 { return nil }
        return best.0
    }
}

public struct SpeechProgress: Equatable, Sendable {
    public var current: Int?
    public var covered: Set<Int> = []
    public var uncertain = false
    public var manualPause = false
    public init() {}
    public mutating func receive(_ text: String, final: Bool, document: SpeechDocument) {
        guard let match = document.match(text, current: current) else {
            uncertain = true
            return
        }
        current = match
        uncertain = false
        if final { covered.insert(match) }
    }
}

private enum SpeechWords {
    static let ignored: Set<String> = [
        "a", "an", "the", "and", "or", "to", "of", "in", "on", "for", "with", "it", "this", "that", "is",
        "are", "be", "can", "will", "would", "should", "we", "you", "i", "my", "our", "your", "so", "then",
        "just", "like", "say", "example", "detail", "does", "do", "using", "use", "because", "not", "no",
        "without", "avoid", "never", "don't", "doesn't",
    ]
    static let aliases: [String: String] = [
        "dependencies": "dependency", "dependency": "dependency", "injecting": "injection",
        "inject": "injection", "injected": "injection", "passing": "injection",
        "testing": "test", "tests": "test", "testable": "test", "testability": "test", "mocking": "mock",
        "mocks": "mock",
        "duplicate": "duplicate", "duplicates": "duplicate", "duplicated": "duplicate",
        "idempotent": "duplicate", "idempotency": "duplicate",
        "locking": "lock", "locks": "lock", "concurrency": "concurrent", "simultaneous": "concurrent",
        "simultaneously": "concurrent",
        "database": "database", "db": "database", "transactions": "transaction", "atomic": "transaction",
        "atomicity": "transaction",
        "slower": "slow", "latency": "delay", "delayed": "delay", "delays": "delay", "retries": "retry",
        "retrying": "retry",
        "errors": "error", "failure": "error", "failed": "error", "failures": "error", "messages": "message",
        "events": "event",
    ]
    static func plain(_ text: String) -> String {
        (try? AttributedString(
            markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))).map {
                String($0.characters)
            } ?? text
    }
    static func words(_ text: String) -> [String] {
        let plain = plain(text)
        let tokenizer = NLTokenizer(unit: .word)
        let source = plain.lowercased().replacingOccurrences(of: "’", with: "'")
        tokenizer.string = source
        var words: [String] = []
        tokenizer.enumerateTokens(in: source.startIndex..<source.endIndex) { range, _ in
            words.append(String(source[range]))
            return true
        }
        return words
    }
    static func latestPhrase(_ text: String) -> String {
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = text
        var latest = text
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            latest = String(text[range])
            return true
        }
        return latest
    }
    static func contentWords(_ text: String) -> [String] {
        words(text).filter { $0.count > 2 && !ignored.contains($0) }.map {
            aliases[$0] ?? ($0.hasSuffix("s") && $0.count > 4 ? String($0.dropLast()) : $0)
        }
    }
    static func terms(_ text: String) -> Set<String> { Set(contentWords(text)) }
    static func negative(_ text: String) -> Bool {
        !Set(words(text)).isDisjoint(with: [
            "not", "no", "without", "avoid", "never", "don't", "doesn't", "cannot", "can't", "shouldn't",
        ])
    }
}
