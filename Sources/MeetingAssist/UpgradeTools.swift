import AppKit
import MeetingCore
import SwiftUI

struct PerformanceTools: View {
    @ObservedObject var model: MeetingModel
    var body: some View {
        DisclosureGroup("Session health & speed") {
            VStack(alignment: .leading, spacing: 7) {
                ForEach(
                    ["Audio", "Typed", "Coding", "Refresh", "Deep", "Screenshot", "Editor", "Fallback"],
                    id: \.self
                ) { route in
                    if let p50 = model.performance.percentile(0.5, route: route),
                        let p95 = model.performance.percentile(0.95, route: route)
                    {
                        Text(String(format: "%@ · typical %.2fs · p95 %.2fs", route, p50, p95))
                    }
                }
                Text(
                    "\(model.performance.samples.count) completed attempts · \(model.performance.samples.filter(\.failed).count) failed"
                )
                Text(
                    "Timing measures first useful words. Small samples are indicative; no fixed latency guarantee."
                )
                ForEach(model.performance.events.keys.sorted(), id: \.self) { event in
                    Text("\(event): \(model.performance.events[event] ?? 0)")
                }
                Button("Reset measurements") { model.performance = PerformanceLedger() }
                HStack {
                    Button("Missed question") { model.performance.event("Reported missed question") }
                    Button("Wrong link") { model.performance.event("Reported wrong follow-up link") }
                }
            }.font(.system(size: 10)).foregroundStyle(.secondary)
        }.font(.system(size: 11))
    }
}

struct EditorTools: View {
    @ObservedObject var model: MeetingModel
    @ObservedObject var editor: EditorBridge
    @State private var expected = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(
                "Use connected editor",
                isOn: Binding(get: { editor.enabled }, set: { model.setEditorEnabled($0) })
            ).toggleStyle(.switch)
            Text(editor.status).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(3)
            DisclosureGroup("Editor setup & Java checks") {
                VStack(alignment: .leading, spacing: 8) {
                    Text(
                        "Install the companion extension, then run Connect Meetly in VS Code or IntelliJ. Only the active code file is shared while connected. Code and diagnostics can be sent to OpenAI for coding answers."
                    )
                    Button("Open companion extensions") {
                        let app = Bundle.main.bundleURL.appendingPathComponent(
                            "Contents/Resources/Editor Companions")
                        NSWorkspace.shared.open(app)
                    }
                    TextField("Expected sample output (optional)", text: $expected).textFieldStyle(
                        .roundedBorder)
                    HStack {
                        Button("Compile Java") { model.validateEditorCode(run: false, expected: "") }
                        Button("Run sample") { model.validateEditorCode(run: true, expected: expected) }
                    }.disabled(model.checkingCode || editor.snapshot?.language.lowercased() != "java")
                    Text(
                        "Checks use an isolated temporary folder without network or access to your personal files. Standalone Java classes only; Run sample executes main. An output match checks one sample, not all correctness."
                    )
                    if model.checkingCode { ProgressView("Checking…").controlSize(.mini) }
                    if let result = model.codeCheck {
                        Text(result.label).foregroundStyle(result.successful ? .green : .orange)
                        Text(result.details).textSelection(.enabled)
                    } else {
                        Text("Suggested · code has not been checked")
                    }
                }.font(.system(size: 10)).foregroundStyle(.secondary)
            }.font(.system(size: 11))
        }
    }
}

struct IncidentLibraryTools: View {
    @ObservedObject var model: MeetingModel
    @State private var project = ""
    @State private var symptom = ""
    @State private var cause = ""
    @State private var action = ""
    @State private var outcome = ""
    @State private var tradeoff = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Verified project library").font(.headline)
            Text("Add only facts you actually experienced. Leave unknown fields blank; they stay unknown.")
                .font(.caption).foregroundStyle(.secondary)
            ForEach(model.incidents) { incident in
                HStack(alignment: .top) {
                    VStack(alignment: .leading) {
                        Text(incident.project + " · " + incident.symptom).bold()
                        Text(incident.facts).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Remove") { model.incidents.removeAll { $0.id == incident.id } }
                }
            }
            DisclosureGroup("Add an incident") {
                VStack(spacing: 8) {
                    TextField("Project", text: $project)
                    TextField("Symptom / bottleneck", text: $symptom)
                    TextField("Confirmed root cause (optional)", text: $cause)
                    TextField("What I changed (optional)", text: $action)
                    TextField("Confirmed outcome (optional)", text: $outcome)
                    TextField("Tradeoff / lesson (optional)", text: $tradeoff)
                    HStack {
                        Text("Are these your real, confirmed facts?")
                        Button("Y — Add") {
                            model.incidents.append(
                                .init(
                                    project: String(project.prefix(160)),
                                    symptom: String(symptom.prefix(1000)), cause: String(cause.prefix(1000)),
                                    action: String(action.prefix(1000)),
                                    outcome: String(outcome.prefix(1000)),
                                    tradeoff: String(tradeoff.prefix(1000))))
                            project = ""
                            symptom = ""
                            cause = ""
                            action = ""
                            outcome = ""
                            tradeoff = ""
                        }.disabled(
                            project.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                || symptom.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                || model.incidents.count >= 40)
                        Button("N — Clear") {
                            project = ""
                            symptom = ""
                            cause = ""
                            action = ""
                            outcome = ""
                            tradeoff = ""
                        }
                    }
                }.textFieldStyle(.roundedBorder).font(.system(size: 12))
            }
            HStack {
                Button("Save encrypted profile") { model.saveProjectLibrary() }
                Button("Load saved profile") { model.loadProjectLibrary() }.disabled(!model.hasSavedLibrary)
                Button("Delete saved profile") { model.deleteProjectLibrary() }.disabled(
                    !model.hasSavedLibrary)
            }.controlSize(.small)
            Text(model.libraryStatus).font(.caption).foregroundStyle(.secondary)
        }.disabled(model.listening || model.connecting)
    }
}
