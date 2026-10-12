import AppKit
import MeetingCore
import SwiftUI
import UniformTypeIdentifiers

struct PreparationView: View {
    @ObservedObject var model: MeetingModel
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 14) {
                Image(nsImage: AppIcon.applicationImage)
                    .resizable().scaledToFit().frame(width: 64, height: 64)
                    .accessibilityLabel("Meetly app picture")
                VStack(alignment: .leading, spacing: 4) {
                    Text("Meetly").font(.headline).foregroundStyle(.secondary)
                    Text("Prepare for your meeting.").font(.system(size: 28, design: .serif))
                }
            }
            Text("Would you like to upload your resume for this meeting?").font(.system(size: 16))
            Text(
                "PDF or TXT. Resume text is analyzed with OpenAI after common contacts are removed locally. Context stays in memory unless you explicitly save an encrypted profile. You can load and review it here each launch."
            )
            .font(.system(size: 12)).foregroundStyle(.secondary)
            HStack {
                Button("Upload & analyze resume") { chooseResume() }
                    .disabled(model.resumeLoading || model.listening || model.connecting)
                if model.resumeLoading {
                    ProgressView().controlSize(.small)
                    Text("Analyzing projects and skills…").font(.system(size: 12))
                }
                Spacer()
                if !model.hasKey {
                    Button("Open Settings") { model.sheet = .settings }
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                AnswerTemplatePicker(model: model)
                Text(model.answerTemplate.description).font(.caption).foregroundStyle(.secondary)
                if model.answerTemplate == .custom { CustomTemplateEditor(model: model) }
                Text("Answers explain technical terms in plain language, as if speaking to someone.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let error = model.resumeError { Text(error).font(.system(size: 12)).foregroundStyle(.orange) }
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if let profile = model.resumeProfile {
                        Text(model.resumeName).font(.system(size: 14, weight: .semibold))
                        Text(profile.skills.joined(separator: " · ")).font(.system(size: 12)).foregroundStyle(
                            .secondary)
                        if !profile.projects.isEmpty {
                            Picker("Current project", selection: $model.currentProject) {
                                Text("Use all projects").tag("")
                                ForEach(Array(profile.projects.enumerated()), id: \.offset) { _, project in
                                    Text(project.name).tag(project.name)
                                }
                            }.disabled(model.listening || model.connecting)
                            ForEach(Array(profile.projects.enumerated()), id: \.offset) { _, project in
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(project.name).font(.system(size: 13, weight: .semibold))
                                    Text(project.summary).font(.system(size: 12)).foregroundStyle(.secondary)
                                }.frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                        Text(
                            profile.incidents.isEmpty
                                ? "No specific incidents were documented in the resume. Add real details below; other scenarios will be labeled hypothetical."
                                : "\(profile.incidents.count) documented incident(s) found. Review them before using this profile."
                        )
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                        ForEach(Array(profile.incidents.enumerated()), id: \.offset) { _, incident in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(incident.project + ": " + incident.issue).font(.system(size: 12))
                                Text("Resume: " + incident.evidence).font(.system(size: 11)).foregroundStyle(
                                    .secondary)
                            }
                        }
                    }
                    Divider()
                    Text("Real project incidents (optional)").font(.system(size: 14, weight: .semibold))
                    Text(
                        "Add current or previous project details: symptom, root cause or bottleneck, your fix, and the outcome. Omit client secrets. The assistant uses these facts for your experience answers."
                    )
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                    TextEditor(text: $model.projectNotes).font(.system(size: 12)).frame(height: 140)
                        .border(Color.primary.opacity(0.15)).disabled(model.listening || model.connecting)
                    Text(
                        "Missing details produce a labeled hypothetical scenario, with diagnosis, fix and validation steps—not an invented personal claim."
                    )
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    Divider()
                    IncidentLibraryTools(model: model)
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                Button("Skip for now") { model.finishPreparation() }.keyboardShortcut(.escape, modifiers: [])
                Spacer()
                Button("Ready to answer") { model.finishPreparation() }.disabled(model.resumeLoading)
            }
        }.padding(28).frame(width: 680, height: 650).background(
            CaptureProtectedWindow(enabled: model.captureExclusion))
    }
    private func chooseResume() {
        let panel = NSOpenPanel()
        panel.title = "Choose your resume"
        panel.allowedContentTypes = [.pdf, .plainText]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in model.prepareResume(url) }
        }
    }
}

struct WorkspaceTools: View {
    @ObservedObject var controller: WorkspaceController
    @ObservedObject var protection: CaptureProtectionController
    @Binding var captureExclusion: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("SCREEN SHARING").font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(.secondary).tracking(1)
            Text("Capture protection").font(.system(size: 13, weight: .semibold))
            Toggle("Request capture exclusion", isOn: $captureExclusion).toggleStyle(.checkbox)
                .font(.system(size: 11))
            Text(
                captureExclusion
                    ? protection.result.message : "Exclusion off. This window can appear in captures."
            ).font(.system(size: 11))
                .foregroundStyle(protection.result == .visible ? Color.red : Color.secondary)
            Button(protection.testing ? "Testing capture…" : "Test capture protection") {
                protection.test()
            }.disabled(protection.testing)
            if protection.testing { Button("Cancel test") { protection.stop() } }
            Text(
                "For Zoom, try Settings → Share Screen → Advanced → Advanced capture with window filtering. Verify with a viewer before relying on it. Other capture methods may show this window."
            ).font(.system(size: 11)).foregroundStyle(.secondary)
            Divider()
            Text("Optional sharing window").font(.system(size: 13, weight: .semibold))
            Text(
                "Open the workspace below, then share only the ‘Meeting Workspace’ window in your meeting app. It shows the main display with Meetly excluded. Keep this assistant visible on your own screen."
            )
            .font(.system(size: 11)).foregroundStyle(.secondary)
            Button(
                controller.starting
                    ? "Preparing workspace…"
                    : controller.active ? "Show sharing window" : "Open sharing window"
            ) {
                controller.open()
            }.disabled(controller.starting)
            if controller.active {
                Text(
                    "Workspace ready. Select it in the meeting app’s window-sharing picker. Keep it open and unminimized."
                )
                .font(.system(size: 11)).foregroundStyle(.secondary)
                Button("Close sharing window") { controller.stop() }
            }
            if let error = controller.error { Text(error).font(.system(size: 11)).foregroundStyle(.orange) }
            Text(
                "Sharing your entire screen can still show the assistant. Transparency does not hide it from viewers."
            )
            .font(.system(size: 11)).foregroundStyle(.secondary)
        }.fixedSize(horizontal: false, vertical: true)
    }
}
