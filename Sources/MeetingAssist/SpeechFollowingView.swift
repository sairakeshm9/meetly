import AppKit
import MeetingCore
import SwiftUI

struct SpeechFollowingHeader: View {
    @ObservedObject var controller: SpeechFollowingController
    @State private var expanded = false
    var body: some View {
        Button {
            expanded.toggle()
        } label: {
            HStack(spacing: 4) {
                Image(systemName: expanded ? "chevron.down" : "chevron.right")
                Text("Follow my speech")
                if controller.enabled {
                    Image(systemName: "checkmark.circle.fill")
                } else if controller.issue {
                    Image(systemName: "exclamationmark.circle")
                }
            }.fixedSize(horizontal: true, vertical: false)
        }
        .font(.system(size: 10)).buttonStyle(.plain)
        .foregroundStyle(
            controller.issue ? Color.red : controller.enabled ? MeetlyPalette.accent : Color.secondary
        )
        .accessibilityLabel(expanded ? "Collapse speech controls" : "Expand speech controls")
        .accessibilityValue(controller.enabled ? "On" : controller.issue ? "Needs attention" : "Off")
        .help(controller.status.isEmpty ? "Show or hide Follow my speech options" : controller.status)
        .popover(isPresented: $expanded) {
            SpeechFollowingTools(controller: controller).padding(12).frame(width: 390, alignment: .leading)
        }
        .onChange(of: controller.issue) { if controller.issue { expanded = true } }
    }
}

struct SpeechFollowingTools: View {
    @ObservedObject var controller: SpeechFollowingController
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Toggle(
                    "Follow my speech", isOn: Binding(get: { controller.enabled }, set: controller.setEnabled)
                )
                .toggleStyle(.checkbox)
                .help(
                    "Use your microphone locally to highlight your speaking position. Off by default; does not start meeting capture."
                )
                if controller.starting { ProgressView().controlSize(.mini) }
                if controller.enabled {
                    Button(controller.progress.manualPause ? "Resume scroll" : "Hold scroll") {
                        if controller.progress.manualPause {
                            controller.resume()
                        } else {
                            controller.pauseScrolling()
                        }
                    }
                    Button("Restart position") { controller.resetProgress() }
                    SpeechInputIndicator(input: controller.inputStatus)
                } else if controller.issue {
                    Button("Retry following") { controller.setEnabled(true) }
                }
            }.font(.system(size: 11)).controlSize(.mini)
            if controller.issue {
                Text(controller.status).font(.system(size: 10)).lineLimit(1).help(controller.status)
                    .foregroundStyle(
                        controller.issue ? .red : .secondary)
            }
        }
    }
}

private struct SpeechInputIndicator: View {
    @ObservedObject var input: SpeechInputStatus
    @State private var showDetails = false
    var body: some View {
        Button {
            showDetails.toggle()
        } label: {
            Label("Mic", systemImage: input.active ? "waveform" : "mic")
        }.help("Microphone input and recognized words")
            .popover(isPresented: $showDetails) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(input.name).font(.caption.bold())
                    Text(input.active ? "Sound detected" : "Waiting for speech")
                    Text(input.heard.isEmpty ? "Heard: waiting…" : "Heard: \(input.heard)")
                }.font(.caption).padding(12).frame(width: 280, alignment: .leading)
            }
    }
}

enum SpeechScrollIntent {
    static func pauses(type: NSEvent.EventType, key: UInt16, inside: Bool, scrollbar: Bool, focused: Bool)
        -> Bool
    {
        switch type {
        case .scrollWheel: return inside
        case .leftMouseDown: return scrollbar
        case .keyDown: return focused && [116, 121, 125, 126].contains(key)
        default: return false
        }
    }
}

/// An observation-only view: it must never become a mouse or scroll event target.
struct ScrollIntentDetector: NSViewRepresentable {
    var action: () -> Void
    func makeNSView(context: Context) -> IntentView { IntentView(action: action) }
    func updateNSView(_ view: IntentView, context: Context) { view.action = action }
    final class IntentView: NSView {
        var action: () -> Void
        private var monitor: Any?
        init(action: @escaping () -> Void) {
            self.action = action
            super.init(frame: .zero)
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .leftMouseDown, .keyDown]) {
                [weak self] event in
                guard let self, let scroll = self.enclosingScrollView, event.window == self.window else {
                    return event
                }
                let inside = scroll.bounds.contains(scroll.convert(event.locationInWindow, from: nil))
                let scrollbar = [scroll.verticalScroller, scroll.horizontalScroller].compactMap { $0 }
                    .contains {
                        !$0.isHidden && $0.bounds.contains($0.convert(event.locationInWindow, from: nil))
                    }
                let focused = (self.window?.firstResponder as? NSView)?.isDescendant(of: scroll) == true
                if SpeechScrollIntent.pauses(
                    type: event.type, key: event.keyCode, inside: inside, scrollbar: scrollbar,
                    focused: focused)
                {
                    self.action()
                }
                return event
            }
        }
        deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
    }
}

struct FollowingAnswerContent: View {
    @ObservedObject var model: MeetingModel
    @ObservedObject var controller: SpeechFollowingController
    let card: AnswerCard
    init(model: MeetingModel, card: AnswerCard) {
        self.model = model
        self.controller = model.speechFollowing
        self.card = card
    }
    var body: some View {
        let answer = model.cueOnly ? AnswerLayers.cue(card.answer) : card.answer
        AnswerContentView(
            answer: answer, textSize: model.textSize, autoFit: model.autoFit,
            autoScroll: model.autoScroll,
            textOpacity: WindowTransparency.backgroundOpacity(model.textTransparency),
            speechDocument: controller.enabled ? controller.document : nil,
            speechProgress: controller.enabled ? controller.progress : nil,
            readAloud: controller.suspendedForReadAloud,
            onManualScroll: controller.enabled ? { controller.pauseScrolling() } : nil
        )
        .onAppear { if controller.enabled { controller.setAnswer(id: card.id, text: answer) } }
        .onChange(of: answer) { if controller.enabled { controller.setAnswer(id: card.id, text: answer) } }
        .onChange(of: controller.enabled) {
            if controller.enabled { controller.setAnswer(id: card.id, text: answer) }
        }
    }
}
