import Foundation
import NaturalLanguage

/// A local fallback for unformatted prose. Model-selected emphasis remains the primary signal.
public enum ExplanationEmphasis {
    public static let guidance = """
        Answer emphasis requirement (also applies to custom templates and long answers):
        Choose short **explanation cues**, not just language/product names. In every substantive
        bullet or paragraph, emphasize the definition, mechanism, action, consequence or contrast
        that helps the user explain it aloud. Usually select 2–3 phrases of 2–5 words. For example:
        Java is a **programming language**; Spring Boot **provides sensible defaults** and
        **reduces setup work**; @GetMapping **handles HTTP GET requests**; microservices are
        **independently deployable services** organized around a **business capability**.
        Apply this throughout the answer, including later sections, examples and comparison cells.
        Keep most words plain. Do not bold whole sentences, repeated product names, punctuation,
        or code inside fenced blocks. Use Markdown **phrase** directly; no separate keyword list.
        """
    private static let predicates = try! NSRegularExpression(
        pattern:
            #"\b(is|are|means|refers to|provides?|reduces?|prevents?|avoids?|handles?|maps?|starts?|enables?|marks?|injects?|contains?|supports?|ensures?|guarantees?|improves?|separates?|groups?|stores?|checks?|retries|retry|deploy|deployed|deploys|scale|scales|isolates?|protects?|returns?|creates?|exposes?|removes?|follows?|confirms?|assess|assesses|notifies|notify|escalates?|verifies|verify|documents?|investigates?|validates?|coordinates?|monitors?|detects?|resolves?)\s+([^\n.!?;:]+)"#,
        options: .caseInsensitive)
    private static let separator = try! NSRegularExpression(
        pattern:
            #"\s+(?:and|or|but|so|because|which|that|where|while|with|for|using|used to|such as|rather than)\b|,"#,
        options: .caseInsensitive)
    private static let identifiers = try! NSRegularExpression(
        pattern: #"(?<![\p{L}\p{N}])@[A-Za-z][A-Za-z0-9_]*"#)

    public static func ranges(in text: String, preferred: [Range<String.Index>] = []) -> [Range<String.Index>]
    {
        guard !text.isEmpty else { return [] }
        var output: [Range<String.Index>] = []
        // Each line and sentence has its own budget, so later bullets retain emphasis too.
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = text
        text.enumerateSubstrings(in: text.startIndex..., options: [.byLines, .substringNotRequired]) {
            _, line, _, _ in
            tokenizer.enumerateTokens(in: line) { sentence, _ in
                let explicit = preferred.filter { $0.overlaps(sentence) }
                var selected = explicit
                let whole = NSRange(sentence, in: text)
                var cues: [Range<String.Index>] = []
                // Advance from each verb rather than the matched tail, so multiple clauses contribute.
                var cursor = sentence.lowerBound
                while cursor < sentence.upperBound,
                    let match = predicates.firstMatch(
                        in: text, range: NSRange(cursor..<sentence.upperBound, in: text)),
                    let verb = Range(match.range(at: 1), in: text)
                {
                    cursor = verb.upperBound
                    guard let tail = Range(match.range(at: 2), in: text) else { continue }
                    var end = tail.upperBound
                    if let stop = separator.firstMatch(in: text, range: match.range(at: 2)),
                        let boundary = Range(stop.range, in: text)
                    {
                        end = boundary.lowerBound
                    }
                    var start = verb.lowerBound
                    if ["is", "are", "means", "refers to"].contains(text[verb].lowercased()) {
                        start = tail.lowerBound
                        for article in ["a ", "an ", "the "]
                        where text[start..<end].lowercased().hasPrefix(article) {
                            start = text.index(start, offsetBy: article.count)
                            break
                        }
                    }
                    // Keep negation with the action so emphasis never implies its opposite.
                    let prefix = text[sentence.lowerBound..<start]
                    if let negative = prefix.range(
                        of: #"(?:not|never|cannot|can't|doesn't|don't)\s+$"#,
                        options: [.regularExpression, .caseInsensitive])
                    {
                        start = negative.lowerBound
                    }
                    var words = Array(text[start..<end].split(whereSeparator: { $0.isWhitespace }).prefix(4))
                    let dangling: Set<String> = [
                        "a", "an", "the", "to", "for", "with", "and", "of", "in", "on", "by", "as", "after",
                        "during", "through", "into", "at", "from",
                    ]
                    while let last = words.last, dangling.contains(last.lowercased()) { words.removeLast() }
                    if words.count >= 2, let last = words.last {
                        cues.append(start..<last.endIndex)
                    }
                }
                let annotations = identifiers.matches(in: text, range: whole).compactMap {
                    Range($0.range, in: text)
                }
                let fragment = String(text[sentence])
                let technical = KeywordEmphasis.ranges(in: fragment).map {
                    local -> Range<String.Index> in
                    let start = text.index(
                        sentence.lowerBound,
                        offsetBy: fragment.distance(from: fragment.startIndex, to: local.lowerBound))
                    let end = text.index(start, offsetBy: fragment[local].count)
                    return start..<end
                }
                let wordCount = text[sentence].split(whereSeparator: { $0.isWhitespace }).count
                let budget = max(6, Int(ceil(Double(wordCount) * 0.5)))
                var used = explicit.reduce(0) {
                    $0 + text[$1].split(whereSeparator: { $0.isWhitespace }).count
                }
                for cue in cues + annotations + technical {
                    guard selected.count < 3, !selected.contains(where: { $0.overlaps(cue) }) else {
                        continue
                    }
                    let words = text[cue].split(whereSeparator: { $0.isWhitespace }).count
                    guard used + words <= budget else { continue }
                    selected.append(cue)
                    output.append(cue)
                    used += words
                }
                return true
            }
        }
        return output.sorted { $0.lowerBound < $1.lowerBound }
    }
}
