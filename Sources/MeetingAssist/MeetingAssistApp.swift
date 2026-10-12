import AppKit
import MeetingCore
import SwiftUI

@main
struct MeetingAssistApp: App {
    @StateObject private var model = MeetingModel()
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    var body: some Scene {
        Window("Meetly", id: AssistantPresence.windowID) {
            MainView(model: model)
                .background(CaptureProtectedWindow(enabled: model.captureExclusion))
                .background(TransparentAssistantWindow(transparency: model.windowTransparency, model: model))
                .frame(minWidth: 640, minHeight: 540)
                .preferredColorScheme(model.theme.scheme)
                .task {
                    model.applyTheme()
                    delegate.model = model
                    model.enableLocalSharingDetection()
                    if ProcessInfo.processInfo.arguments.contains("--demo") {
                        model.preview()
                    } else {
                        model.presentPreparationAtLaunch()
                    }
                }
        }
        .defaultSize(width: 1080, height: 800)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") { model.showSettings = true }.keyboardShortcut(",")
            }
            CommandMenu("Meeting") {
                Button("Prepare resume and projects…") { model.sheet = .preparation }
                    .disabled(model.listening || model.connecting)
                Button("Open sharing window") { model.workspace.open() }
                Button("Test capture protection") { model.captureProtection.test() }
                Button("Refresh displayed answer") { model.refreshSession() }.keyboardShortcut("r")
                Button("Reconnect audio and recover queue") { model.recoverSession() }
                Button("Show solid window") { model.setWindowTransparency(0) }.keyboardShortcut(
                    "0", modifiers: [.command, .shift])
                Button("Answer latest question") { model.answerLatest() }.keyboardShortcut(
                    .return, modifiers: [.command])
                Button("Stop listening") { model.stop() }.keyboardShortcut(".", modifiers: [.command])
            }
        }
        MenuBarExtra {
            AssistantMenu(model: model)
        } label: {
            Image(nsImage: AppIcon.menuBarImage())
                .accessibilityLabel("Meetly")
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var model: MeetingModel? {
        didSet { model?.globalShortcutAvailable = hotKey?.available ?? false }
    }
    private var hotKey: HotKey?
    private var lifecycleObservers: [NSObjectProtocol] = []
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.applicationIconImage = AppIcon.applicationImage
        NSApp.setActivationPolicy(AssistantPresence.activationPolicy)
        NSApp.activate(ignoringOtherApps: true)
        hotKey = HotKey()
        model?.globalShortcutAvailable = hotKey?.available ?? false
        hotKey?.action = { [weak self] in Task { @MainActor in self?.model?.answerLatest(useTyped: false) } }
        let center = NSWorkspace.shared.notificationCenter
        lifecycleObservers.append(
            center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) {
                [weak self] _ in Task { @MainActor in self?.model?.prepareForSleep() }
            })
        lifecycleObservers.append(
            center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) {
                [weak self] _ in Task { @MainActor in self?.model?.resumeAfterWake() }
            })
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        AssistantPresence.terminateAfterLastWindowClosed
    }
    func applicationWillTerminate(_ notification: Notification) {
        model?.stop()
        model?.finishPreparation()
        model?.workspace.stop()
        model?.screen.stop()
        model?.captureProtection.stop()
        model?.editor.stop()
        for observer in lifecycleObservers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
    }
}

private let canvas = MeetlyPalette.canvas
private let panel = MeetlyPalette.panel
private let accent = MeetlyPalette.accent

struct MainView: View {
    @ObservedObject var model: MeetingModel
    @State private var showControls = false
    @State private var answerBoxSize: CGSize?
    @State private var resizeStart: CGSize?
    private var surfaceOpacity: Double { WindowTransparency.backgroundOpacity(model.windowTransparency) }
    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                HStack {
                    Image(nsImage: AppIcon.applicationImage).resizable().frame(width: 26, height: 26)
                        .foregroundStyle(accent)
                    Text("MEETLY").font(.system(size: 12, weight: .bold, design: .monospaced))
                        .tracking(
                            2)
                    Spacer()
                    Picker("Mode", selection: $model.mode) {
                        ForEach([AssistantMode.questions, .coding], id: \.self) { mode in
                            Text(mode.rawValue).tag(mode)
                        }
                    }.frame(width: geometry.size.width < 900 ? 150 : 190)
                    Button {
                        model.refreshSession()
                    } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                    .labelStyle(.iconOnly)
                    .accessibilityLabel("Refresh")
                    .help("Clear the current explanation and re-answer the displayed question simply")
                    AppearanceButton(model: model)
                    ThemeButton(model: model)
                    if geometry.size.width >= 900 {
                        Button {
                            model.sidebarCollapsed.toggle()
                        } label: {
                            Image(systemName: "sidebar.left")
                        }.help(model.sidebarCollapsed ? "Show sidebar" : "Minimize sidebar")
                            .accessibilityLabel(model.sidebarCollapsed ? "Show sidebar" : "Minimize sidebar")
                    }
                    if geometry.size.width < 900 {
                        Button("Controls") { showControls.toggle() }
                            .popover(isPresented: $showControls) { sidebar.frame(width: 280, height: 480) }
                    }
                    Label(
                        model.demo
                            ? "DEMO"
                            : model.listening ? "LISTENING" : model.connecting ? "CONNECTING" : "READY",
                        systemImage: model.listening ? "record.circle" : "circle"
                    )
                    .font(.system(size: 11, weight: .semibold, design: .monospaced)).foregroundStyle(
                        model.listening ? accent : .secondary)
                    Button {
                        model.showSettings = true
                    } label: {
                        Image(systemName: "gearshape")
                    }
                    .buttonStyle(.plain).padding(.leading, 20).help("Settings")
                }.padding(20)
                Divider()
                HStack(spacing: 0) {
                    if geometry.size.width >= 900 && !model.sidebarCollapsed {
                        sidebar.frame(width: 260)
                        Divider()
                    }
                    VStack(alignment: .leading, spacing: 12) {
                        if !model.answerControlsCollapsed {
                            HStack(alignment: .firstTextBaseline) {
                                VStack(alignment: .leading, spacing: 5) {
                                    Text("Keep the thread.").font(
                                        .system(size: 22, weight: .regular, design: .serif))
                                    if geometry.size.width >= 900 {
                                        Text("Short answers. Concrete examples. Your technical context.")
                                            .font(.system(size: 12)).foregroundStyle(.secondary)
                                    }
                                }
                                Spacer()
                                Toggle("Pin window", isOn: $model.alwaysOnTop).toggleStyle(.checkbox).font(
                                    .system(size: 11)
                                )
                                .help(
                                    "Keep Meetly above other windows. This does not hide it from screen sharing."
                                )
                                .onChange(of: model.alwaysOnTop) { model.setWindowLevel() }
                            }
                        }
                        if let error = model.error {
                            HStack(alignment: .top) {
                                Image(systemName: "exclamationmark.circle")
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(
                                        "ISSUE · "
                                            + String(
                                                error.components(separatedBy: "\n").first?.prefix(160)
                                                    ?? "Please retry.")
                                    )
                                    .font(.system(size: 12)).textSelection(.enabled).help(error)
                                    if let clarification = model.clarification {
                                        Text(clarification).font(.system(size: 12))
                                        HStack {
                                            Button("Y — Yes") { model.answerClarification(true) }
                                            Button("N — No") { model.answerClarification(false) }
                                        }.disabled(model.answering)
                                    }
                                }
                                Spacer()
                                Button {
                                    model.error = nil
                                } label: {
                                    Image(systemName: "xmark")
                                }.buttonStyle(.plain)
                            }.foregroundStyle(.red).padding(10).background(
                                Color.red.opacity(0.12), in: RoundedRectangle(cornerRadius: 9))
                        }
                        resizableAnswerPanel
                        HStack {
                            TextField(
                                "Type a question, or answer the latest one heard…", text: $model.question
                            )
                            .textFieldStyle(.plain).padding(14).background(
                                panel.opacity(surfaceOpacity), in: RoundedRectangle(cornerRadius: 10)
                            )
                            .onSubmit { model.answerLatest() }
                            Button("Answer") { model.answerLatest() }.buttonStyle(PrimaryButtonStyle())
                        }
                        transcriptPanel
                    }.padding(20)
                }
                Divider()
                HStack {
                    Text(model.status).lineLimit(1).help(model.status)
                    if model.waitingQuestionCount > 0 || model.queuePaused {
                        Text(
                            model.waitingQuestionCount == 0
                                ? "Answers paused"
                                : "\(model.waitingQuestionCount) waiting"
                                    + (model.queuePaused ? " · paused" : "")
                        ).foregroundStyle(model.queuePaused ? .orange : accent).fixedSize()
                        if model.waitingQuestionCount > 0 {
                            Button("Answer newest") { model.answerNewestWaiting() }
                                .controlSize(.mini).fixedSize()
                                .help("Skip waiting questions and answer the newest meeting question")
                        }
                    }
                    Spacer()
                    if geometry.size.width >= 900 || (model.waitingQuestionCount == 0 && !model.queuePaused) {
                        Text(
                            model.globalShortcutAvailable
                                ? "⌃⌥Space: answer latest · ⌘.: stop · ⌘Return: answer"
                                : "⌘Return: answer · ⌘.: stop · global shortcut unavailable"
                        ).lineLimit(1)
                    }
                }.font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary).padding(
                    .horizontal, 24
                ).padding(.vertical, 8)
            }
        }
        .background(canvas.opacity(surfaceOpacity))
        .environment(\.surfaceOpacity, surfaceOpacity)
        .sheet(item: $model.sheet) { sheet in
            switch sheet {
            case .settings: SettingsView(model: model)
            case .preparation: PreparationView(model: model).interactiveDismissDisabled(model.resumeLoading)
            }
        }
    }
    private var sidebar: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text("CONTROLS").font(.caption.bold())
                    Spacer()
                    Button {
                        model.sidebarCollapsed = true
                        showControls = false
                    } label: {
                        Image(systemName: "chevron.left")
                    }
                    .accessibilityLabel("Minimize sidebar")
                    .help("Hide these controls; show them again with the sidebar button or Controls")
                }
                Toggle("Auto mode while sharing", isOn: $model.autoSharingMode).font(.caption)
                Button(model.sharingActive ? "Sharing on · mark stopped" : "Sharing off · mark started") {
                    model.setSharingActive(!model.sharingActive)
                }.font(.caption)
                Text(model.sharingStatus).font(.caption).foregroundStyle(.secondary)
                Text(
                    "Detects visible sharing indicators locally while listening. Hidden toolbars can prevent detection; use the Sharing button. Sharing switches to Coding, which also answers normal questions."
                )
                .font(.caption).foregroundStyle(.secondary)
                Divider()
                Text("AUDIO SOURCE").font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.secondary).tracking(1)
                Text("All apps and browsers").font(.system(size: 14, weight: .semibold))
                Text("Automatically listens to sound playing on this Mac. No app selection needed.")
                    .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(
                        horizontal: false, vertical: true)
                Button {
                    model.checkAudioAccess()
                } label: {
                    Label(
                        model.refreshing ? "Checking access…" : "Check audio access",
                        systemImage: "checkmark.shield")
                }.disabled(model.refreshing || model.listening || model.connecting)
                HStack(spacing: 3) {
                    ForEach(0..<28, id: \.self) { i in
                        RoundedRectangle(cornerRadius: 2).fill(
                            Double(i) / 28 < model.level ? accent : Color.primary.opacity(0.07)
                        ).frame(width: 5, height: 20)
                    }
                }.accessibilityLabel("Meeting audio level").accessibilityValue(
                    "\(Int(model.level * 100)) percent")
                if model.listening || model.connecting {
                    Button(model.connecting ? "Cancel connection" : "Stop listening") { model.stop() }
                        .buttonStyle(.bordered).tint(.red).frame(maxWidth: .infinity)
                } else {
                    Button("Start listening") { model.start() }.buttonStyle(PrimaryButtonStyle())
                }
                Toggle("Answer automatically", isOn: $model.autoAnswer).toggleStyle(.switch)
                Toggle("Smart conversation", isOn: $model.smartConversation).toggleStyle(.checkbox)
                    .help("Join unfinished questions and prioritize corrections and urgent follow-ups")
                Toggle("Include my microphone", isOn: $model.microphone).toggleStyle(.checkbox).disabled(
                    model.listening || model.connecting)
                Text(
                    "Microphone adds your responses as context. Only meeting audio triggers automatic answers."
                )
                .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(
                    horizontal: false, vertical: true)
                Divider()
                if model.mode != .questions {
                    ScreenTools(model: model, screen: model.screen)
                    Divider()
                }
                Text("YOUR FOCUS").font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.secondary).tracking(1)
                Text(
                    model.resumeProfile.map { $0.skills.prefix(10).joined(separator: " · ") }
                        ?? "Java / Spring\nPython · Angular · React\nAWS · Kubernetes\nKafka · SQL · DevOps"
                )
                .font(.system(size: 13)).lineSpacing(7).fixedSize(horizontal: false, vertical: true)
                if !model.resumeName.isEmpty {
                    Text("Resume ready: " + model.resumeName).font(.system(size: 11)).foregroundStyle(
                        .secondary)
                }
                Button("Prepare resume & projects") { model.sheet = .preparation }
                    .disabled(model.listening || model.connecting)
                Divider()
                DisclosureGroup("Advanced tools") {
                    WorkspaceTools(
                        controller: model.workspace, protection: model.captureProtection,
                        captureExclusion: $model.captureExclusion)
                    Divider()
                    PerformanceTools(model: model)
                    Divider()
                    Button("Try demo") { model.preview() }.disabled(model.listening || model.connecting)
                        .help(
                            "Show a sample answer without recording audio or calling OpenAI. Demo clears the current conversation."
                        )
                    Button("Clear session") { model.clear() }.disabled(model.listening || model.connecting)
                }
                Text(
                    "Audio is sent to OpenAI while listening. No local recordings. Session text stays in memory. Use agreed meeting transcription."
                )
                .font(.system(size: 10)).foregroundStyle(.secondary).lineSpacing(3).fixedSize(
                    horizontal: false, vertical: true)
            }.padding(24)
        }.background(panel.opacity(0.45 * surfaceOpacity)).background(
            CaptureProtectedWindow(enabled: model.captureExclusion))
    }
    private var resizableAnswerPanel: some View {
        GeometryReader { geometry in
            let size = AnswerBoxLayout.size(answerBoxSize, within: geometry.size)
            answerPanel.frame(width: size.width, height: size.height)
                .overlay(alignment: .bottomTrailing) {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.system(size: 11)).foregroundStyle(accent)
                        .frame(width: 28, height: 28).contentShape(Rectangle())
                        .accessibilityLabel("Resize answer box")
                        .help("Drag to resize the answer box; double-click to reset")
                        .onTapGesture(count: 2) { answerBoxSize = nil }
                        .gesture(
                            DragGesture(minimumDistance: 1, coordinateSpace: .named("answer-area"))
                                .onChanged { value in
                                    if resizeStart == nil { resizeStart = size }
                                    answerBoxSize = AnswerBoxLayout.resized(
                                        from: resizeStart ?? size, translation: value.translation,
                                        within: geometry.size)
                                }
                                .onEnded { _ in resizeStart = nil }
                        )
                }
        }.coordinateSpace(name: "answer-area")
            .frame(minHeight: 140, maxHeight: .infinity)
    }
    private var answerPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Button {
                    model.answerControlsCollapsed.toggle()
                } label: {
                    Image(systemName: model.answerControlsCollapsed ? "chevron.right" : "chevron.down")
                }
                .accessibilityLabel(
                    model.answerControlsCollapsed ? "Show answer controls" : "Minimize answer controls"
                )
                .help("Collapse the heading and answer toolbars while keeping the answer visible")
                .controlSize(.mini)
                Text(model.demo ? "SAMPLE ANSWER" : "YOUR ANSWER").tracking(1)
                ReadAloudButton(speech: model.speech, card: model.activeCard)
                SpeechFollowingHeader(controller: model.speechFollowing)
                Spacer()
                if model.answering {
                    ProgressView().controlSize(.small)
                    Text("Writing…")
                }
                if let timing = model.activeCard?.timing, let seconds = timing.firstUsefulSeconds {
                    Text(
                        String(
                            format: timing.questionEndedAt == nil
                                ? "Answer text %.2fs" : "After speech %.2fs", seconds))
                }
            }.font(.system(size: 10, weight: .medium, design: .monospaced)).foregroundStyle(accent)
            if !model.answerControlsCollapsed {
                HStack(spacing: 8) {
                    Button("A−") { model.adjustTextSize(-1) }.help("Smaller text")
                    Button("A+") { model.adjustTextSize(1) }.help("Larger text")
                    Text("\(Int(model.textSize)) pt").font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                    Toggle("Fit text", isOn: $model.autoFit).toggleStyle(.checkbox)
                    Toggle("Auto-scroll", isOn: $model.autoScroll).toggleStyle(.checkbox)
                    Spacer(minLength: 0)
                    Button("Reset answer box") { answerBoxSize = nil }
                        .help("Restore the answer box to its automatic size")
                        .fixedSize()
                }.font(.system(size: 11)).controlSize(.small)
                HStack(spacing: 8) {
                    Button {
                        model.browseAnswer(1)
                    } label: {
                        Image(systemName: "chevron.left")
                    }.help("Previous answer")
                        .disabled(model.cards.count < 2)
                    Button {
                        model.browseAnswer(-1)
                    } label: {
                        Image(systemName: "chevron.right")
                    }.help("Newer answer")
                        .disabled(model.newAnswersCount == 0)
                    Toggle("Pin answer", isOn: $model.readingPinned).toggleStyle(.checkbox)
                    Toggle("Brief cue", isOn: $model.cueOnly).toggleStyle(.checkbox)
                    Spacer()
                    if model.newAnswersCount > 0 {
                        Button("\(model.newAnswersCount) new · Show latest") { model.followNewestAnswer() }
                    }
                    Menu("History") {
                        ForEach(model.cards) { card in
                            Button(String(card.question.prefix(70))) { model.selectAnswer(card.id) }
                        }
                    }.disabled(model.cards.isEmpty)
                }.font(.system(size: 11)).controlSize(.small)
            }
            if let card = model.activeCard {
                Text(card.question).font(.system(size: 15, weight: .semibold)).lineLimit(2)
                    .opacity(WindowTransparency.backgroundOpacity(model.textTransparency)).textSelection(
                        .enabled)
                HStack {
                    Text(card.intent == .newQuestion ? card.route : card.intent.label + " · " + card.route)
                    if let parent = card.parentID, let target = model.cards.first(where: { $0.id == parent })
                    {
                        Button("Related answer") { model.selectAnswer(target.id) }
                    }
                    Menu(
                        card.evidence.isEmpty
                            ? "General explanation · no personal evidence"
                            : "Provided context · \(card.evidence.count) sources"
                    ) {
                        ForEach(card.evidence) { source in Text(source.label + "\n" + source.text) }
                        Text(
                            "Context provided to the model; verify its use in the answer. Hypothetical examples must be labeled."
                        )
                    }
                }.font(.system(size: 10)).foregroundStyle(.secondary).controlSize(.mini)
                if model.readingPinned, model.newAnswersCount > 0, let latest = model.cards.first {
                    Text(
                        "New \(latest.intent.label.lowercased()): "
                            + String(AnswerLayers.cue(latest.answer).prefix(180))
                    )
                    .font(.system(size: 11)).foregroundStyle(accent).lineLimit(2)
                }
                Divider()
                FollowingAnswerContent(model: model, card: card)
                    .id(card.id).frame(minHeight: 40, maxHeight: .infinity)
                if card.interrupted {
                    Text(
                        card.superseded
                            ? "Superseded by a correction" : "Partial answer · retry before relying on it"
                    ).font(.system(size: 11))
                        .foregroundStyle(.orange)
                }
                HStack {
                    Button("Copy answer") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(card.answer, forType: .string)
                    }.disabled(card.answer.isEmpty)
                    Button("Better answer") { model.explainMore() }.disabled(
                        model.answering || model.demo)
                    if model.answering {
                        Button("Cancel answer") { model.cancelAnswer(pauseQueue: true) }
                    }
                    Spacer()
                }.controlSize(.small)
                SpeechStatus(speech: model.speech)
            } else {
                Spacer()
                Image(systemName: "text.bubble").font(.system(size: 32)).foregroundStyle(
                    accent.opacity(0.65))
                Text("A little space to think.").font(.system(size: 23, design: .serif))
                Text(
                    "Start listening, type a question, or try the demo.\nEach answer includes a short explanation and one example."
                )
                .font(.system(size: 13)).foregroundStyle(.secondary).lineSpacing(5)
                Spacer()
            }
        }.padding(16).frame(
            maxWidth: .infinity, minHeight: 140, maxHeight: .infinity, alignment: .leading
        )
        .background(panel.opacity(surfaceOpacity), in: RoundedRectangle(cornerRadius: 14))
    }
    private var transcriptPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Button {
                    model.conversationCollapsed.toggle()
                } label: {
                    Image(systemName: model.conversationCollapsed ? "chevron.right" : "chevron.down")
                }.accessibilityLabel(
                    model.conversationCollapsed ? "Show recent conversation" : "Minimize recent conversation")
                Text("RECENT CONVERSATION").font(.system(size: 10, weight: .medium, design: .monospaced))
                    .tracking(1)
                Spacer()
                if let inputStatus = model.audioInputStatus {
                    Text(inputStatus).font(.system(size: 10)).foregroundStyle(accent)
                }
            }.foregroundStyle(.secondary)
            if !model.conversationCollapsed {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 10) {
                            if model.turns.isEmpty {
                                Text("Live transcript will appear here.").foregroundStyle(.tertiary).padding(
                                    .vertical, 12)
                            }
                            ForEach(model.turns.suffix(8)) { turn in
                                HStack(alignment: .top, spacing: 10) {
                                    Text(turn.speaker.uppercased()).font(
                                        .system(size: 9, weight: .semibold, design: .monospaced)
                                    ).foregroundStyle(accent).frame(width: 58, alignment: .leading)
                                    Text(turn.text.isEmpty ? "Transcribing…" : turn.text).foregroundStyle(
                                        turn.final ? .primary : .secondary
                                    ).textSelection(.enabled)
                                }.id(turn.id)
                            }
                        }.font(.system(size: 12)).frame(maxWidth: .infinity, alignment: .leading)
                    }.opacity(WindowTransparency.backgroundOpacity(model.textTransparency)).frame(height: 64)
                        .onChange(of: model.turns) {
                            if model.autoScroll, let id = model.turns.last?.id {
                                proxy.scrollTo(id, anchor: .bottom)
                            }
                        }
                }
            }
        }
    }
}

struct SettingsView: View {
    @ObservedObject var model: MeetingModel
    @State private var key = ""
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    Text("Make it yours.").font(.system(size: 28, design: .serif))
                    Spacer()
                    Button("Done") { dismiss() }.keyboardShortcut(.escape, modifiers: [])
                }
                Picker("Theme", selection: $model.theme) {
                    ForEach(AppTheme.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }.pickerStyle(.segmented)
                Text("API ACCESS").font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.secondary)
                Text(
                    model.hasKey
                        ? "An API key is saved in this Mac's Keychain."
                        : "Enter an OpenAI API key. API usage is billed to your API account."
                )
                .font(.system(size: 12))
                SecureField("New or replacement API key", text: $key).textFieldStyle(.roundedBorder)
                HStack {
                    Button("Save to Keychain") {
                        model.saveKey(key)
                        if model.hasKey && model.error == nil { key = "" }
                    }.disabled(key.isEmpty || model.listening || model.connecting)
                    Button("Remove saved key") { model.removeKey() }.disabled(!model.hasKey)
                    Button("Test connection") {
                        dismiss()
                        model.testConnection()
                    }.disabled(!model.hasKey || model.listening || model.connecting || model.answering)
                }
                if let error = model.error { Text(error).font(.system(size: 12)).foregroundStyle(.orange) }
                Divider()
                Toggle("Adaptive answer depth", isOn: $model.adaptiveAnswers)
                Text(
                    "Simple questions stay fast. Complex design/debugging requests use deeper processing and can take longer."
                ).font(.caption).foregroundStyle(.secondary)
                Toggle("Semantic pauses (compatible models only)", isOn: $model.semanticEndpointing).disabled(
                    model.listening || model.connecting)
                Text(
                    "Optional: choose gpt-4o-mini-transcribe first. The default gpt-live-transcribe uses local pause detection. Semantic detection can wait longer for an unfinished sentence."
                ).font(.caption).foregroundStyle(.secondary)
                Toggle("Fast live answers", isOn: $model.fastAnswers).disabled(
                    model.listening || model.connecting)
                Text(
                    "Prepares answers while the completed speech is transcribed, then displays confirmed questions only. This can use extra API tokens for discarded speech turns. Ordinary typed questions use the answer model below; follow-ups and Better answer use the stronger model. Changes apply next time you start listening."
                )
                .font(.system(size: 11)).foregroundStyle(.secondary)
                TextField("Fast live model", text: $model.realtimeAnswerModel).textFieldStyle(.roundedBorder)
                    .disabled(model.listening || model.connecting)
                TextField("Ordinary question model", text: $model.answerModel).textFieldStyle(.roundedBorder)
                TextField("Coding model", text: $model.codingAnswerModel).textFieldStyle(.roundedBorder)
                TextField("Follow-up / Better answer model", text: $model.followupAnswerModel).textFieldStyle(
                    .roundedBorder)
                Text(
                    "Follow-ups, interruptions, corrections, Refresh and Better answer use this model with a concise accuracy-focused format. It may take longer than ordinary answers."
                ).font(.caption).foregroundStyle(.secondary)
                AnswerTemplatePicker(model: model)
                if model.answerTemplate == .custom { CustomTemplateEditor(model: model) }
                Text(
                    "Coding mode handles ordinary questions too. Code requests use the coding model; ordinary questions keep the fast path. GPT-6.1 Sol uses low reasoning and may take longer."
                ).font(.caption).foregroundStyle(.secondary)
                TextField("Transcription model", text: $model.transcriptionModel).textFieldStyle(
                    .roundedBorder
                ).disabled(model.listening || model.connecting)
                Text(
                    "Defaults: gpt-realtime-2.1-mini for fast live answers, gpt-6-luna for typed answers, gpt-live-transcribe for transcripts. Fast mode uses minimal reasoning and has separate audio/token charges. Model availability depends on your API project."
                )
                .font(.system(size: 11)).foregroundStyle(.secondary)
                Text("TECHNICAL BACKGROUND").font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.secondary)
                TextEditor(text: $model.background).font(.system(size: 12)).frame(height: 160).border(
                    Color.primary.opacity(0.1))
                HStack {
                    Button("Recording permissions") {
                        NSWorkspace.shared.open(
                            URL(
                                string:
                                    "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
                            )!)
                    }
                    Spacer()
                    Text("Close the app or clear the session to discard meeting text.").font(
                        .system(size: 10)
                    )
                    .foregroundStyle(.secondary)
                }
            }.padding(28)
        }.frame(width: 650, height: 680).background(canvas).background(
            CaptureProtectedWindow(enabled: model.captureExclusion))
    }
}

private struct PrimaryButtonStyle: ButtonStyle {
    @Environment(\.surfaceOpacity) private var surfaceOpacity
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 13, weight: .medium))
            .foregroundStyle(surfaceOpacity < 0.5 ? Color.primary : canvas)
            .padding(.horizontal, 15).padding(.vertical, 10)
            .background(
                accent.opacity((enabled ? (configuration.isPressed ? 0.8 : 1) : 0.4) * surfaceOpacity),
                in: RoundedRectangle(cornerRadius: 8))
    }
}
