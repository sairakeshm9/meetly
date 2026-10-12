import SwiftUI

struct AppearanceButton: View {
    @ObservedObject var model: MeetingModel
    @State private var open = false
    var body: some View {
        Button {
            open.toggle()
        } label: {
            Image(systemName: "circle.lefthalf.filled").frame(width: 28, height: 24)
        }
        .accessibilityLabel("Window transparency")
        .help("Fade the window background independently of answer text")
        .popover(isPresented: $open) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Window transparency · \(Int(model.windowTransparency))%").font(.headline)
                Slider(
                    value: Binding(get: { model.windowTransparency }, set: model.setWindowTransparency),
                    in: WindowTransparency.range, step: 5
                ).accessibilityLabel("Window transparency level")
                Text(
                    "100% removes background fills. Text remains visible until Text transparency reaches 100%. Controls remain usable."
                )
                .font(.caption).foregroundStyle(.secondary)
                Button("Show solid window") {
                    model.setWindowTransparency(0)
                    open = false
                }
                Divider()
                TextTransparencyControls(model: model)
            }.padding(18).frame(width: 340)
                .background(CaptureProtectedWindow(enabled: model.captureExclusion))
        }
    }
}

struct TextTransparencyControls: View {
    @ObservedObject var model: MeetingModel
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Text transparency · \(Int(model.textTransparency))%").font(.headline)
            Slider(
                value: Binding(get: { model.textTransparency }, set: model.setTextTransparency),
                in: WindowTransparency.range, step: 5
            ).accessibilityLabel("Text transparency level")
            Text(
                "Fades answer prose, code and conversation text independently of the background. Buttons remain usable."
            )
            .font(.caption).foregroundStyle(.secondary)
            Button("Show solid text") { model.setTextTransparency(0) }
        }
    }
}
