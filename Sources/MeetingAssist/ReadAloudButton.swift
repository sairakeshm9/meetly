import AppKit
import SwiftUI

struct ReadAloudButton: View {
    @ObservedObject var speech: AnswerSpeechController
    let card: AnswerCard?
    @State private var showPace = false
    var body: some View {
        HStack(spacing: 4) {
            Button {
                speech.setEnabled(!speech.enabled)
                if speech.enabled, let card, card.finished, !card.interrupted {
                    speech.offer(card.answer, id: card.id)
                }
            } label: {
                Label(
                    speech.enabled ? "Audio on" : "Audio off",
                    systemImage: speech.enabled ? "speaker.wave.2.fill" : "speaker.slash")
            }.help("Automatically read completed answers through connected headphones until turned off")
            Button {
                showPace.toggle()
            } label: {
                Image(systemName: "slider.horizontal.3")
            }
            .accessibilityLabel("Voice & audio")
            .help("Choose voice and adjust read-aloud speed")
            .popover(isPresented: $showPace) {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Voice & audio").font(.headline)
                    Text("Meetly output · " + speech.outputName).font(.caption).foregroundStyle(.secondary)
                    Picker("Voice source", selection: $speech.provider) {
                        ForEach(SpeechProvider.allCases) { Text($0.label).tag($0) }
                    }
                    if speech.provider == .mac {
                        Picker("Mac voice", selection: $speech.macVoiceID) {
                            Text("Best available · American female").tag("")
                            ForEach(speech.availableVoices, id: \.id) { Text($0.label).tag($0.id) }
                        }
                        Text("No speech API charge. Best quality uses an Enhanced or Premium Mac voice.")
                            .font(.caption).foregroundStyle(.secondary)
                        Button("Download Mac voices…") {
                            NSWorkspace.shared.open(
                                URL(
                                    string:
                                        "x-apple.systempreferences:com.apple.Accessibility-Settings.extension?SpokenContent"
                                )!)
                        }
                    } else {
                        Picker("API option", selection: $speech.apiMode) {
                            ForEach(APIVoiceMode.allCases) { Text($0.label).tag($0) }
                        }
                        Text(
                            speech.apiMode == .realtime
                                ? "Realtime Mini: $20 / million audio output tokens, plus text usage."
                                : "Budget TTS: $12 / million audio output tokens, plus text usage. Available until January 6, 2027."
                        )
                        .font(.caption).foregroundStyle(.secondary)
                        Picker("API voice", selection: $speech.apiVoice) {
                            ForEach(APISpeechRequest.voices, id: \.self) { Text($0.capitalized).tag($0) }
                        }
                        Text(
                            "AI-generated voice · streams online using your saved OpenAI key. Spoken answer text is sent to OpenAI. Additional usage charges and network delay apply. Mac voice is the fallback if audio has not started."
                        ).font(.caption).foregroundStyle(.secondary)
                        Link(
                            "API voice pricing",
                            destination: URL(
                                string: speech.apiMode == .realtime
                                    ? "https://developers.openai.com/api/docs/models/gpt-realtime-2.1-mini"
                                    : "https://developers.openai.com/api/docs/models/gpt-4o-mini-tts")!)
                    }
                    HStack {
                        Button("Preview voice") { speech.preview() }
                        Button("Stop audio") { speech.stop() }.disabled(!speech.speaking)
                    }
                    SpeechStatus(speech: speech)
                    Divider()
                    Text("Audio pace · \(speech.pace, specifier: "%.2f")×").font(.headline)
                    Slider(
                        value: $speech.pace, in: 0.65...1.5, step: 0.05,
                        onEditingChanged: { editing in
                            if !editing { speech.applyPace() }
                        }
                    ).accessibilityLabel("Audio pace level")
                    HStack {
                        Text("Slow")
                        Spacer()
                        Text("Fast")
                    }.font(.caption)
                    Button("Normal speed") {
                        speech.pace = 1
                        speech.applyPace()
                    }
                    Text(
                        "Changing speed restarts the current explanation. Code lines stay silent; explanatory comments are read."
                    )
                    .font(.caption).foregroundStyle(.secondary)
                }.padding().frame(width: 360)
            }
        }.controlSize(.small)
    }
}

struct SpeechStatus: View {
    @ObservedObject var speech: AnswerSpeechController
    var body: some View {
        if !speech.status.isEmpty {
            Text(speech.status).font(.caption).foregroundStyle(speech.issue ? Color.red : Color.secondary)
                .textSelection(.enabled)
        }
    }
}
