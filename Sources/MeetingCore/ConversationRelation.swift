import Foundation
import NaturalLanguage

/// Broad local routing signals; the stronger model resolves the actual relationship from bounded context.
public enum ConversationRelation {
    private static let ignored: Set<String> = [
        "what", "how", "why", "which", "when", "where", "who", "is", "are", "be", "do", "does",
        "can", "could", "would", "should", "will", "have", "use", "using", "used", "work", "works",
        "explain", "tell", "give", "example", "please", "question", "answer", "code", "write", "make",
        "a", "an", "the", "and", "or", "in", "on", "for", "of", "to", "with", "without", "from",
        "by", "about", "you", "your", "we", "our", "i", "my", "me", "more", "one", "also", "way",
    ]
    private static let families: [Set<String>] = [
        [
            "concurrency", "concurrent", "race", "locking", "lock", "optimistic", "pessimistic", "version",
            "isolation", "transaction", "atomic", "atomicity", "deadlock", "thread", "synchronization",
            "serializable", "phantom",
        ],
        [
            "injection", "dependency", "dependencies", "constructor", "ioc", "bean", "mock", "mocking",
            "testability", "testing", "test", "unit", "stub", "fake", "unittest", "junit",
        ],
        [
            "sql", "database", "query", "queries", "index", "indexing", "join", "table", "rows", "schema",
            "postgresql", "mysql", "execution", "scan",
        ],
        [
            "kafka", "consumer", "producer", "partition", "offset", "broker", "message", "messaging",
            "acknowledgement", "idempotency", "idempotent", "deduplication",
        ],
        [
            "http", "rest", "endpoint", "controller", "restcontroller", "getmapping", "postmapping",
            "requestmapping", "url", "routing", "request", "response", "json", "web",
        ],
        [
            "microservice", "microservices", "distributed", "service", "communication", "network",
            "resilience", "retry", "timeout", "deployment", "capability",
        ],
        ["docker", "container", "kubernetes", "pod", "orchestration", "image", "helm", "cluster"],
        [
            "alert", "monitoring", "observability", "cloudwatch", "splunk", "logs", "log", "ingestion",
            "latency", "incident", "oncall", "runbook", "escalation",
        ],
        [
            "array", "list", "hashmap", "hashset", "collection", "map", "lookup", "complexity", "algorithm",
            "sorting", "search", "recursion",
        ],
    ]
    private static func terms(_ text: String) -> Set<String> {
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = text.lowercased()
        var result: Set<String> = []
        let source = text.lowercased()
        tokenizer.enumerateTokens(in: source.startIndex..<source.endIndex) { range, _ in
            let word = String(source[range]).trimmingCharacters(in: .punctuationCharacters)
            if word.count > 2, !ignored.contains(word), word.rangeOfCharacter(from: .letters) != nil {
                result.insert(word)
                if word.hasSuffix("s"), word.count > 4 { result.insert(String(word.dropLast())) }
            }
            return true
        }
        return result
    }
    public static func startsNewTopic(_ text: String) -> Bool {
        let normalized = QuestionDetector.normalized(text)
        return [
            "new topic", "different topic", "switching topics", "switch gears", "moving on",
            "let s talk about", "now let s discuss",
        ].contains(where: normalized.hasPrefix)
    }
    public static func match(_ question: String, questions: [String], answers: [String] = []) -> Int? {
        guard !questions.isEmpty, !startsNewTopic(question) else { return nil }
        let current = terms(question)
        let normalized = QuestionDetector.normalized(question)
        let references = ["this", "that", "it", "these", "those", "previous", "earlier", "above", "same"]
        let words = Set(normalized.split(separator: " ").map(String.init))
        let refersBack = references.contains(where: words.contains)
        var best: (index: Int, score: Int)?
        for index in questions.indices.suffix(3) {
            let topic = terms(questions[index])
            let answer = index < answers.count ? terms(String(answers[index].prefix(1800))) : []
            let overlap = current.intersection(topic).count
            let answerOverlap = current.intersection(answer).count
            let familyOverlap = families.filter {
                !$0.isDisjoint(with: current) && !$0.isDisjoint(with: topic)
            }.count
            let score = overlap * 4 + min(3, answerOverlap) * 3 + familyOverlap * 3
            if score >= 3, best == nil || score >= best!.score { best = (index, score) }
        }
        if let best { return best.index }
        if refersBack { return questions.indices.last }
        // Ambiguous how/which/conditional questions get the careful route; obvious unrelated definitions do not.
        if [
            "how ", "which ", "would ", "could ", "can ", "if ", "does ", "do ", "should ", "are ", "is ",
            "where ", "when ", "what happens", "what changes", "what risks", "what would",
        ].contains(where: normalized.hasPrefix) {
            return questions.indices.last
        }
        return nil
    }
}
