import MeetingCore
import SwiftUI

struct AnswerTemplatePicker: View {
    @ObservedObject var model: MeetingModel
    var body: some View {
        Picker(
            "Answer template",
            selection: Binding(
                get: { model.templateSelection }, set: { model.templateSelection = $0 })
        ) {
            ForEach(AnswerTemplate.allCases.filter { $0 != .custom }, id: \.self) {
                Text($0.rawValue).tag($0.rawValue)
            }
            ForEach(model.savedAnswerTemplates) { saved in
                Text(saved.name).tag(saved.id)
            }
            Text("New custom template…").tag(AnswerTemplate.custom.rawValue)
        }.pickerStyle(.menu)
    }
}
