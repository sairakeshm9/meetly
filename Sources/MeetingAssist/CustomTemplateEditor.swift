import MeetingCore
import SwiftUI

struct CustomTemplateEditor: View {
    @ObservedObject var model: MeetingModel
    @State private var draft = ""
    @State private var name = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField("Template name", text: $name).textFieldStyle(.roundedBorder)
                .accessibilityLabel("Custom answer template name")
            Text("Describe your answer format").font(.caption.bold())
            TextEditor(text: $draft).font(.system(size: 12)).frame(height: 72)
                .padding(5).background(Color.primary.opacity(0.05))
                .accessibilityLabel("Custom answer template description")
            HStack {
                Button("Save template") {
                    model.saveCustomAnswerTemplate(draft, name: name)
                    loadSelection()
                }.disabled(AnswerTemplate.normalizedCustom(draft).isEmpty)
                Text(
                    model.selectedSavedTemplateID != nil
                        && AnswerTemplate.normalizedCustom(draft) == model.customAnswerTemplate
                        && name.trimmingCharacters(in: .whitespacesAndNewlines)
                            == model.savedAnswerTemplates.first(where: {
                                $0.id == model.selectedSavedTemplateID
                            })?.name
                        ? "Saved · applies to new answers" : "Up to 2,000 characters · save to apply"
                )
                .font(.caption).foregroundStyle(.secondary)
            }
        }.onAppear { loadSelection() }
            .onChange(of: model.templateSelection) { _, _ in loadSelection() }
    }
    private func loadSelection() {
        let saved = model.savedAnswerTemplates.first { $0.id == model.selectedSavedTemplateID }
        name = saved?.name ?? ""
        draft = saved?.instructions ?? ""
    }
}
