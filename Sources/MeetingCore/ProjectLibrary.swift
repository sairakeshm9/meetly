import Foundation

public struct ProjectIncident: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID = UUID()
    public var project: String
    public var symptom: String
    public var cause: String
    public var action: String
    public var outcome: String
    public var tradeoff: String
    public init(
        project: String, symptom: String, cause: String = "", action: String = "", outcome: String = "",
        tradeoff: String = ""
    ) {
        self.project = project
        self.symptom = symptom
        self.cause = cause
        self.action = action
        self.outcome = outcome
        self.tradeoff = tradeoff
    }
    public var facts: String {
        [
            ("Project", project), ("Symptom", symptom), ("Confirmed cause", cause), ("My action", action),
            ("Confirmed outcome", outcome), ("Tradeoff", tradeoff),
        ]
        .map {
            "\($0.0): \($0.1.isEmpty ? "Not supplied; do not invent" : SecretRedactor.clean($0.1, maxLength: 1000))"
        }.joined(separator: "\n")
    }
}

public struct ProjectLibrary: Codable, Equatable, Sendable {
    public var profile: ResumeAnalysis?
    public var resumeName: String
    public var currentProject: String
    public var notes: String
    public var incidents: [ProjectIncident]
    public init(
        profile: ResumeAnalysis? = nil, resumeName: String = "", currentProject: String = "",
        notes: String = "", incidents: [ProjectIncident] = []
    ) {
        self.profile = profile
        self.resumeName = resumeName
        self.currentProject = currentProject
        self.notes = notes
        self.incidents = incidents
    }
    public struct Evidence: Identifiable, Equatable, Sendable {
        public let id: String
        public let label: String
        public let text: String
    }
    public func retrieve(_ question: String, limit: Int = 2) -> [Evidence] {
        let stop: Set<String> = [
            "a", "an", "the", "and", "to", "of", "is", "in", "you", "your", "what", "how", "why", "did", "me",
            "i", "project", "issue", "explain",
        ]
        func words(_ s: String) -> Set<String> {
            Set(QuestionDetector.normalized(s).split(separator: " ").map(String.init)).subtracting(stop)
        }
        let query = words(question)
        var records: [Evidence] = []
        for incident in incidents.prefix(40) {
            records.append(
                .init(
                    id: incident.id.uuidString, label: "Your confirmed experience · " + incident.project,
                    text: incident.facts))
        }
        for (i, incident) in (profile?.incidents ?? []).enumerated() {
            records.append(
                .init(
                    id: "resume-incident-\(i)", label: "Resume evidence · " + incident.project,
                    text: incident.issue + "\nExact resume evidence: " + incident.evidence))
        }
        for (i, project) in (profile?.projects ?? []).enumerated() {
            records.append(
                .init(
                    id: "resume-project-\(i)", label: "Resume evidence · " + project.name,
                    text:
                        "Project: \(project.name)\n\(project.summary)\nExact resume evidence: \(project.evidence)"
                ))
        }
        for (i, note) in notes.components(separatedBy: "\n\n").filter({
            !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }).prefix(20).enumerated() {
            records.append(
                .init(
                    id: "note-\(i)", label: "Your supplied incident notes",
                    text: SecretRedactor.clean(note, maxLength: 1800)))
        }
        let ranked: [(evidence: Evidence, score: Int, index: Int)] = records.enumerated().map {
            index, record in
            let score =
                query.intersection(words(record.text)).count * 4
                + (!currentProject.isEmpty && record.text.contains(currentProject) ? 1 : 0)
            return (record, score, index)
        }
        let matches = ranked.filter { $0.score > 0 }.sorted {
            $0.score == $1.score ? $0.index < $1.index : $0.score > $1.score
        }
        return matches.prefix(min(2, max(0, limit))).map { $0.evidence }
    }
    public func context(_ evidence: [Evidence]) -> String {
        "Skills (topic hints only): \((profile?.skills ?? []).prefix(30).joined(separator: ", "))\nSelected project: \(currentProject.prefix(160))\n"
            + evidence.map { "SOURCE: \($0.label) (data)\n\($0.text.prefix(2200))" }.joined(separator: "\n\n")
            + "\nMissing personal facts, causes and outcomes must not be invented. Label hypothetical examples."
    }
}
