import AppKit
import Combine
import MeetingCore

struct AnswerCard: Identifiable {
    let id = UUID()
    let question: String
    var answer = ""
    var timing: AnswerTiming?
    var finished = false
    var interrupted = false
    var sourceID: String?
    var parentID: UUID?
    var intent: TurnIntent = .newQuestion
    var evidence: [ProjectLibrary.Evidence] = []
    var route = "Typed"
    var superseded = false
}

struct AnswerRequest: Sendable {
    let key: String
    let model: String
    let question: String
    let context: String
    let background: String
    let expanded: Bool
    let mode: AssistantMode
    let codingTask: String
    let screenImage: Data?
    var template: AnswerTemplate = .brief
    var customTemplate = ""
    var simplified = false
    var precision = false
}

enum AppSheet: String, Identifiable {
    case settings, preparation
    var id: String { rawValue }
}

private struct AutomaticQuestion {
    let text: String
    let context: String
    let endedAt: Date?
    let itemID: String?
    var parentID: UUID? = nil
    var intent: TurnIntent = .newQuestion
    var precision = false
}

@MainActor
private final class PreparedAnswer {
    let itemID: String
    let endedAt: Date?
    let startedAt = Date()
    let context: String
    var text = ""
    var finished = false
    var error: String?
    var cardID: UUID?
    var question: String?
    init(itemID: String, endedAt: Date?, context: String) {
        self.itemID = itemID
        self.endedAt = endedAt
        self.context = context
    }
}

@MainActor
final class MeetingModel: ObservableObject {
    let speechFollowing = SpeechFollowingController()
    @Published var listening = false
    @Published var connecting = false
    @Published var refreshing = false
    @Published var autoAnswer = true {
        didSet {
            if !autoAnswer {
                pendingQuestions.removeAll()
                recoveryQuestions.removeAll()
                recoveryIncludesActive = false
                newestQuestion = nil
                if preparation != nil, preparation?.cardID == nil { cancelPreparation() }
            }
        }
    }
    @Published var microphone = false
    @Published var alwaysOnTop = false
    @Published var globalShortcutAvailable = false
    @Published var hasKey = false
    @Published var sheet: AppSheet?
    var showSettings: Bool {
        get { sheet == .settings }
        set { sheet = newValue ? .settings : nil }
    }
    @Published var resumeProfile: ResumeAnalysis?
    @Published var resumeName = ""
    @Published var resumeLoading = false
    @Published var resumeError: String?
    @Published var currentProject = ""
    @Published var projectNotes = ""
    @Published var incidents: [ProjectIncident] = []
    @Published var libraryStatus = "Not saved · memory only"
    private let libraryStore: ProjectLibraryStore
    @Published var selectedCardID: UUID?
    @Published var readingPinned = false
    @Published var cueOnly = false
    let speech: AnswerSpeechController
    @Published var theme: AppTheme {
        didSet {
            appearanceDefaults.set(theme.rawValue, forKey: "appTheme")
            applyTheme()
        }
    }
    func applyTheme() { NSApp?.appearance = theme.appearance }
    @Published var answerControlsCollapsed = false
    @Published var sidebarCollapsed = false
    @Published var conversationCollapsed = false
    @Published private(set) var customAnswerTemplate: String
    @Published private(set) var savedAnswerTemplates: [SavedAnswerTemplate]
    @Published private(set) var selectedSavedTemplateID: String?
    var templateSelection: String {
        get {
            answerTemplate == .custom
                ? selectedSavedTemplateID ?? AnswerTemplate.custom.rawValue : answerTemplate.rawValue
        }
        set {
            if let saved = savedAnswerTemplates.first(where: { $0.id == newValue }) {
                selectedSavedTemplateID = saved.id
                customAnswerTemplate = saved.instructions
                appearanceDefaults.set(saved.id, forKey: "selectedSavedTemplateID")
                appearanceDefaults.set(saved.instructions, forKey: "customAnswerTemplate")
                answerTemplate = .custom
            } else if let builtin = AnswerTemplate(rawValue: newValue) {
                selectedSavedTemplateID = nil
                appearanceDefaults.removeObject(forKey: "selectedSavedTemplateID")
                if builtin == .custom { customAnswerTemplate = "" }
                answerTemplate = builtin
            }
        }
    }
    @Published var answerTemplate: AnswerTemplate {
        didSet {
            appearanceDefaults.set(answerTemplate.rawValue, forKey: "answerTemplate")
            if preparation?.cardID == nil { cancelPreparation() }
        }
    }
    @Published var followupAnswerModel: String {
        didSet { appearanceDefaults.set(followupAnswerModel, forKey: "followupAnswerModel") }
    }
    @Published var codingAnswerModel: String {
        didSet { appearanceDefaults.set(codingAnswerModel, forKey: "codingAnswerModel") }
    }
    @Published var autoSharingMode = true {
        didSet {
            appearanceDefaults.set(autoSharingMode, forKey: "autoSharingMode")
            updateSharingDetection()
        }
    }
    @Published private(set) var sharingActive = false
    @Published private(set) var sharingStatus = "Sharing detection starts with listening"
    let sharingMonitor: ScreenContextController
    private var sharingDetectionAllowed = false
    @Published var smartConversation = true
    @Published var semanticEndpointing = false
    @Published var adaptiveAnswers = true
    @Published var performance = PerformanceLedger()
    let editor: EditorBridge
    @Published var codeCheck: CodeCheckResult?
    @Published var checkingCode = false
    private var previousEditor: EditorSnapshot?
    private var fragment: (text: String, at: Date)?
    private var codeCheckTask: Task<Void, Never>?
    private var lastAudioFrameAt = Date.distantPast
    private var audioStartedAt = Date.distantPast
    private var wasListeningBeforeSleep = false
    let workspace = WorkspaceController()
    let captureProtection = CaptureProtectionController()
    @Published var captureExclusion = true {
        didSet { captureProtection.stop() }
    }
    @Published var status = "Ready when you are"
    @Published var error: String?
    @Published var question = ""
    @Published var turns: [TranscriptTurn] = []
    @Published var cards: [AnswerCard] = []
    @Published var answering = false
    @Published var level = 0.0
    @Published var framesReceived = 0
    @Published var demo = false
    @Published var mode: AssistantMode = .questions {
        didSet {
            guard mode != oldValue else { return }
            if mode == .questions {
                setScreenWatching(false)
                setEditorEnabled(false)
            } else {
                autoGuide = true
                setScreenWatching(true)
            }
            if preparation != nil, preparation?.cardID == nil { cancelPreparation() }
        }
    }
    @Published var textSize = 15.0 {
        didSet { UserDefaults.standard.set(textSize, forKey: "answerTextSize") }
    }
    @Published var autoFit = true {
        didSet { UserDefaults.standard.set(autoFit, forKey: "answerAutoFit") }
    }
    @Published var autoScroll = true
    @Published private(set) var windowTransparency: Double
    @Published private(set) var textTransparency: Double
    private let appearanceDefaults: UserDefaults
    @Published var codingTask = ""
    @Published private(set) var watchScreen = false
    @Published var autoGuide = true
    @Published private(set) var guiding = false
    @Published var clarification: String?
    private var clarificationContext: String?
    @Published private(set) var queuePaused = false
    let screen: ScreenContextController
    @Published var fastAnswers: Bool {
        didSet { UserDefaults.standard.set(fastAnswers, forKey: "fastAnswers") }
    }
    @Published var realtimeAnswerModel: String {
        didSet { UserDefaults.standard.set(realtimeAnswerModel, forKey: "realtimeAnswerModel") }
    }
    @Published var answerModel: String {
        didSet { UserDefaults.standard.set(answerModel, forKey: "answerModel") }
    }
    @Published var transcriptionModel: String {
        didSet { UserDefaults.standard.set(transcriptionModel, forKey: "transcriptionModel") }
    }
    @Published var background: String {
        didSet { UserDefaults.standard.set(background, forKey: "background") }
    }
    private var transcript = TranscriptStore()
    private let credentials: CredentialAccess
    private let resumeAnalyzer: (String, String, String) async throws -> ResumeAnalysis
    private let now: () -> Date
    private let captureFactory: () -> any MeetingAudioCapturing
    private let answerStreamer: (AnswerRequest, @escaping @MainActor (String) -> Void) async throws -> Void
    private var resumeTask: Task<Void, Never>?
    private var resumeRun = UUID()
    private var presentedStartup = false
    private var capture: (any MeetingAudioCapturing)?
    private let meetingClient: LiveTranscriber
    private let micClient = LiveTranscriber()
    private var startTask: Task<Void, Never>?
    private var audioTask: Task<Void, Never>?
    private var answerTask: Task<Void, Never>?
    private var preparationTask: Task<Void, Never>?
    private var preparation: PreparedAnswer?
    private var watchdog: Task<Void, Never>?
    @Published private var pendingQuestions: [AutomaticQuestion] = []
    private var newestQuestion: AutomaticQuestion?
    private var answeredIDs = Set<String>()
    private var answeredOrder: [String] = []
    private var lastQuestionAt = Date.distantPast
    private var questionHistory = QuestionHistory()
    @Published private var recoveryQuestions: [AutomaticQuestion] = []
    private var reconnectNeeded = false
    private var recoveryIncludesActive = false
    private var lastScreenFingerprint: UInt64?
    private var lastScreenChange = Date.distantPast
    private var lastGuidedFingerprint: UInt64?
    private var lastGuidedAt = Date.distantPast
    private var screenGuideTask: Task<Void, Never>?
    private let screenPause: (Double) async throws -> Void
    private var session = UUID()
    private var answerRun = UUID()
    var activeCard: AnswerCard? { cards.first(where: { $0.id == selectedCardID }) ?? cards.first }
    var newAnswersCount: Int { cards.firstIndex(where: { $0.id == selectedCardID }) ?? 0 }
    var waitingQuestionCount: Int { pendingQuestions.count + recoveryQuestions.count }
    var audioInputStatus: String? {
        guard listening, framesReceived > 0 else { return nil }
        return level >= 0.096 ? "Sound detected" : "Waiting for speech"
    }

    init(
        credentials: CredentialAccess? = nil, meetingClient: LiveTranscriber? = nil,
        now: @escaping () -> Date = Date.init,
        screenPause: @escaping (Double) async throws -> Void = { try await Task.sleep(for: .seconds($0)) },
        captureFactory: @escaping () -> any MeetingAudioCapturing = { AudioCapture() },
        screen: ScreenContextController? = nil,
        answerStreamer:
            @escaping (AnswerRequest, @escaping @MainActor (String) -> Void) async throws -> Void = {
                request, delta in
                try await AnswerService.stream(
                    key: request.key, model: request.model, question: request.question,
                    context: request.context, background: request.background, expanded: request.expanded,
                    mode: request.mode, codingTask: request.codingTask, screenImage: request.screenImage,
                    template: request.template, customTemplate: request.customTemplate,
                    simplified: request.simplified, precision: request.precision,
                    onDelta: delta)
            },
        resumeAnalyzer: @escaping (String, String, String) async throws -> ResumeAnalysis = {
            try await ResumeService.analyze(key: $0, model: $1, text: $2)
        },
        appearanceDefaults: UserDefaults = .standard,
        libraryStore: ProjectLibraryStore = ProjectLibraryStore(),
        editor: EditorBridge? = nil,
        sharingMonitor: ScreenContextController? = nil,
        speech: AnswerSpeechController? = nil
    ) {
        let speechCredentials = credentials ?? CredentialAccess()
        self.libraryStore = libraryStore
        self.editor = editor ?? EditorBridge()
        self.appearanceDefaults = appearanceDefaults
        self.speech =
            speech
            ?? AnswerSpeechController(
                defaults: appearanceDefaults, key: { try await speechCredentials.load() })
        speechFollowing.observeReadAloud(self.speech)
        theme = AppTheme(rawValue: appearanceDefaults.string(forKey: "appTheme") ?? "") ?? .dark
        self.sharingMonitor = sharingMonitor ?? ScreenContextController()
        let initialTemplate =
            AnswerTemplate(rawValue: appearanceDefaults.string(forKey: "answerTemplate") ?? "") ?? .brief
        var initialCustom = AnswerTemplate.normalizedCustom(
            appearanceDefaults.string(forKey: "customAnswerTemplate") ?? "")
        var initialSaved =
            (appearanceDefaults.data(forKey: "savedAnswerTemplates")
            .flatMap { try? JSONDecoder().decode([SavedAnswerTemplate].self, from: $0) } ?? [])
            .filter { !$0.name.isEmpty && !AnswerTemplate.normalizedCustom($0.instructions).isEmpty }
        var initialID = appearanceDefaults.string(forKey: "selectedSavedTemplateID")
        // Migrate the previously saved single format without losing the user's description.
        if initialSaved.isEmpty, !initialCustom.isEmpty {
            let legacy = SavedAnswerTemplate(name: "My saved template", instructions: initialCustom)
            initialSaved = [legacy]
            if initialTemplate == .custom { initialID = legacy.id }
            appearanceDefaults.set(try? JSONEncoder().encode(initialSaved), forKey: "savedAnswerTemplates")
            appearanceDefaults.set(initialID, forKey: "selectedSavedTemplateID")
        }
        if let saved = initialSaved.first(where: { $0.id == initialID }) {
            initialCustom = saved.instructions
        } else {
            initialID = nil
            if initialTemplate == .custom, !initialSaved.isEmpty { initialCustom = "" }
        }
        answerTemplate = initialTemplate
        customAnswerTemplate = initialCustom
        savedAnswerTemplates = initialSaved
        selectedSavedTemplateID = initialID
        autoSharingMode = appearanceDefaults.object(forKey: "autoSharingMode") as? Bool ?? true
        codingAnswerModel = appearanceDefaults.string(forKey: "codingAnswerModel") ?? "gpt-6.1-sol"
        followupAnswerModel = appearanceDefaults.string(forKey: "followupAnswerModel") ?? "gpt-6.1-sol"
        textTransparency = WindowTransparency.normalized(
            appearanceDefaults.double(forKey: "assistantTextTransparency"))
        windowTransparency = WindowTransparency.normalized(
            appearanceDefaults.object(forKey: WindowTransparency.preferenceKey) as? Double
                ?? WindowTransparency.defaultPercent)
        self.credentials = speechCredentials
        self.resumeAnalyzer = resumeAnalyzer
        self.now = now
        self.screenPause = screenPause
        self.captureFactory = captureFactory
        self.screen = screen ?? ScreenContextController()
        self.answerStreamer = answerStreamer
        self.meetingClient = meetingClient ?? LiveTranscriber()
        fastAnswers = UserDefaults.standard.object(forKey: "fastAnswers") as? Bool ?? true
        realtimeAnswerModel =
            UserDefaults.standard.string(forKey: "realtimeAnswerModel") ?? "gpt-realtime-2.1-mini"
        answerModel = UserDefaults.standard.string(forKey: "answerModel") ?? "gpt-6-luna"
        transcriptionModel =
            UserDefaults.standard.string(forKey: "transcriptionModel") ?? "gpt-live-transcribe"
        background = UserDefaults.standard.string(forKey: "background") ?? Profile.context
        textSize = min(28, max(10, UserDefaults.standard.object(forKey: "answerTextSize") as? Double ?? 15))
        autoFit = UserDefaults.standard.object(forKey: "answerAutoFit") as? Bool ?? true
        hasKey = Keychain.contains()
        wire(self.meetingClient, speaker: "Meeting")
        wire(micClient, speaker: "You")
        self.screen.onSnapshot = { [weak self] frame in self?.screenUpdated(frame) }
        self.screen.onFailure = { [weak self] message in self?.error = message }
        self.editor.onChange = { [weak self] snapshot in self?.editorUpdated(snapshot) }
        self.sharingMonitor.onSnapshot = { [weak self] snapshot in self?.observeSharingText(snapshot.text) }
        self.sharingMonitor.onFailure = { [weak self] _ in
            self?.sharingStatus = "Sharing detection unavailable · use Sharing button"
        }
    }
    var projectLibrary: ProjectLibrary {
        ProjectLibrary(
            profile: resumeProfile, resumeName: resumeName, currentProject: currentProject,
            notes: projectNotes, incidents: incidents)
    }
    var hasSavedLibrary: Bool { libraryStore.exists }
    func saveProjectLibrary() {
        let library = projectLibrary
        let store = libraryStore
        Task {
            do {
                try await Task.detached { try store.save(library) }.value
                libraryStatus = "Saved encrypted on this Mac"
            } catch { libraryStatus = "Save failed · approve Keychain access and retry" }
        }
    }
    func loadProjectLibrary() {
        guard !listening && !connecting else { return }
        let store = libraryStore
        Task {
            do {
                let library = try await Task.detached { try store.load() }.value
                guard !self.listening && !self.connecting else { return }
                resumeProfile = library.profile
                resumeName = library.resumeName
                currentProject = library.currentProject
                projectNotes = library.notes
                incidents = library.incidents
                libraryStatus = "Loaded · review before Ready to answer"
            } catch { libraryStatus = "Load failed · approve Keychain access or delete saved profile" }
        }
    }
    func deleteProjectLibrary() {
        do {
            try libraryStore.delete()
            libraryStatus = "Saved profile deleted · current meeting context retained"
        } catch { libraryStatus = "Could not delete saved profile" }
    }
    func selectAnswer(_ id: UUID) {
        speech.stop()
        selectedCardID = id
        readingPinned = true
    }
    func browseAnswer(_ offset: Int) {
        guard !cards.isEmpty else { return }
        let index = cards.firstIndex(where: { $0.id == activeCard?.id }) ?? 0
        selectAnswer(cards[min(cards.count - 1, max(0, index + offset))].id)
    }
    func followNewestAnswer() {
        speech.stop()
        selectedCardID = cards.first?.id
        readingPinned = false
    }
    private func insertCard(_ card: AnswerCard) {
        cards.insert(card, at: 0)
        if !readingPinned { selectedCardID = card.id }
        if cards.count > 10 {
            let index = cards.lastIndex(where: { $0.id != selectedCardID }) ?? cards.count - 1
            cards.remove(at: index)
        }
    }
    func setEditorEnabled(_ enabled: Bool) {
        previousEditor = nil
        if enabled && mode != .questions { editor.start() } else { editor.stop() }
    }
    private func editorUpdated(_ snapshot: EditorSnapshot) {
        guard autoGuide, mode != .questions, !codingTask.isEmpty else { return }
        screenGuideTask?.cancel()
        let fingerprint = snapshot.fingerprint
        let pause = screenPause
        let delay = max(2, 8 - now().timeIntervalSince(lastGuidedAt))
        screenGuideTask = Task { [weak self] in
            do { try await pause(delay) } catch { return }
            guard let self, !Task.isCancelled, self.editor.current()?.fingerprint == fingerprint,
                !self.answering, self.pendingQuestions.isEmpty, !self.queuePaused, self.clarification == nil
            else { return }
            self.guideNextStep()
        }
    }
    func validateEditorCode(run: Bool, expected: String) {
        guard !checkingCode, let snapshot = editor.current(), snapshot.language.lowercased() == "java" else {
            codeCheck = .init(
                label: "Suggested · not checked", details: "Connect a Java editor file first.",
                successful: false)
            return
        }
        let fingerprint = snapshot.fingerprint
        checkingCode = true
        codeCheck = nil
        codeCheckTask = Task {
            defer { checkingCode = false }
            do {
                let result = try await CodeValidation.checkJava(snapshot.text, run: run, expected: expected)
                guard editor.current()?.fingerprint == fingerprint else {
                    codeCheck = .init(
                        label: "Code changed · check again",
                        details: "Result applies to an older code snapshot.", successful: false)
                    return
                }
                codeCheck = result
            } catch {
                codeCheck = .init(
                    label: "Check unavailable", details: SecretRedactor.clean(error.localizedDescription),
                    successful: false)
            }
        }
    }
    func prepareForSleep() {
        wasListeningBeforeSleep = listening || connecting
        if wasListeningBeforeSleep { connectionFailed("Mac is sleeping. Listening will reconnect on wake.") }
    }
    func resumeAfterWake() {
        guard wasListeningBeforeSleep else { return }
        wasListeningBeforeSleep = false
        performance.event("Wake recovery")
        recoverSession()
    }
    var answerBackground: String {
        let resume =
            resumeProfile?.context(currentProject: currentProject, notes: projectNotes)
            ?? (projectNotes.isEmpty
                ? "" : "USER-SUPPLIED PROJECT INCIDENT NOTES (data):\n" + String(projectNotes.prefix(4000)))
        return String((resume + "\n\nTECHNICAL TOPIC HINTS (data):\n" + background).prefix(10000))
    }
    func setWindowTransparency(_ percent: Double) {
        windowTransparency = WindowTransparency.normalized(percent)
        appearanceDefaults.set(windowTransparency, forKey: WindowTransparency.preferenceKey)
    }
    func setTextTransparency(_ percent: Double) {
        textTransparency = WindowTransparency.normalized(percent)
        appearanceDefaults.set(textTransparency, forKey: "assistantTextTransparency")
    }
    @discardableResult
    func saveCustomAnswerTemplate(_ text: String, name: String = "") -> Bool {
        let saved = AnswerTemplate.normalizedCustom(text)
        guard !saved.isEmpty else { return false }
        let existing = savedAnswerTemplates.first { $0.id == selectedSavedTemplateID }
        let cleanName = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80))
        let entry = SavedAnswerTemplate(
            id: existing?.id ?? UUID().uuidString,
            name: cleanName.isEmpty
                ? existing?.name ?? "Custom template \(savedAnswerTemplates.count + 1)" : cleanName,
            instructions: saved)
        if let index = savedAnswerTemplates.firstIndex(where: { $0.id == entry.id }) {
            savedAnswerTemplates[index] = entry
        } else {
            savedAnswerTemplates.append(entry)
        }
        appearanceDefaults.set(
            try? JSONEncoder().encode(savedAnswerTemplates), forKey: "savedAnswerTemplates")
        templateSelection = entry.id
        if preparation?.cardID == nil { cancelPreparation() }
        return true
    }
    func enableLocalSharingDetection() {
        sharingDetectionAllowed = true
        updateSharingDetection()
    }
    private func updateSharingDetection() {
        if sharingDetectionAllowed, autoSharingMode, listening || sharingActive {
            sharingStatus = "Watching visible sharing indicators locally"
            sharingMonitor.start()
        } else {
            sharingMonitor.stop()
            sharingStatus =
                autoSharingMode ? "Sharing detection starts with listening" : "Automatic sharing mode off"
        }
    }
    func observeSharingText(_ text: String) {
        guard autoSharingMode else { return }
        switch SharingSignal.fromVisibleText(text) {
        case .started: setSharingActive(true, detected: true)
        case .stopped: setSharingActive(false, detected: true)
        case .unknown:
            if sharingActive { sharingStatus = "Sharing indicator not visible · current state retained" }
        }
    }
    func setSharingActive(_ active: Bool, detected: Bool = false) {
        guard active != sharingActive else { return }
        sharingActive = active
        sharingStatus =
            active ? (detected ? "Sharing indicator detected" : "Sharing marked on by you") : "Sharing off"
        if autoSharingMode {
            mode = active ? .coding : .questions
            if active { setScreenWatching(true) }
            performance.event(active ? "Sharing mode started" : "Sharing mode ended")
        }
        updateSharingDetection()
    }
    func presentPreparationAtLaunch() {
        guard !presentedStartup else { return }
        presentedStartup = true
        sheet = .preparation
    }
    func prepareResume(_ url: URL) {
        guard !listening && !connecting else {
            resumeError = "Stop listening before changing your resume or project context."
            return
        }
        guard hasKey else {
            resumeError = "Save an API key in Settings, then upload your resume."
            return
        }
        resumeTask?.cancel()
        let run = UUID()
        resumeRun = run
        resumeLoading = true
        resumeError = nil
        let model = answerModel
        resumeTask = Task { [weak self] in
            guard let self else { return }
            do {
                let text = try await ResumeFile.read(url)
                try Task.checkCancellation()
                guard let key = try await credentials.load() else {
                    throw MeetingError.message("No saved API key. Open Settings.")
                }
                let analysis = try await resumeAnalyzer(key, model, text)
                try Task.checkCancellation()
                guard resumeRun == run else { return }
                resumeProfile = analysis
                resumeName = url.lastPathComponent
                currentProject = analysis.projects.first?.name ?? ""
                status = "Resume ready · \(analysis.projects.count) projects"
            } catch {
                guard resumeRun == run else { return }
                if !(error is CancellationError) {
                    resumeError = SecretRedactor.clean(error.localizedDescription)
                }
            }
            guard resumeRun == run else { return }
            resumeLoading = false
            resumeTask = nil
        }
    }
    func finishPreparation() {
        resumeRun = UUID()
        resumeTask?.cancel()
        resumeTask = nil
        resumeLoading = false
        sheet = nil
    }
    private func wire(_ client: LiveTranscriber, speaker: String) {
        client.onEvent = { [weak self] event in self?.handle(event, speaker: speaker) }
        client.onFailure = { [weak self] message in
            guard let self else { return }
            self.connectionFailed(message)
        }
    }
    func checkAudioAccess() {
        guard !refreshing && !listening && !connecting else { return }
        refreshing = true
        error = nil
        Task {
            defer { refreshing = false }
            do {
                try await AudioCapture.checkAccess()
                status = "Audio access ready · all apps and browsers"
            } catch {
                self.error =
                    "Allow Meetly in System Settings > Privacy & Security > Screen & System Audio Recording, then check audio access. If its switch is already on, remove the old entry and add the installed app again. Capture error: \((error as NSError).domain) \((error as NSError).code)."
                status = "Audio permission needed"
            }
        }
    }
    func start() {
        guard !connecting && !listening else { return }
        guard hasKey else {
            showSettings = true
            error = "Save your API key in Settings first."
            return
        }
        if demo { clear() }
        demo = false
        error = nil
        connecting = true
        status = "Connecting…"
        framesReceived = 0
        level = 0
        let run = UUID()
        session = run
        let useMic = microphone
        let transcribeModel = transcriptionModel
        let liveAnswerModel = fastAnswers ? realtimeAnswerModel : nil
        let profile = background
        let semantic = semanticEndpointing
        if semantic && ["gpt-live-transcribe", "gpt-realtime-whisper"].contains(transcribeModel) {
            connecting = false
            status = "Choose a compatible model for semantic pauses"
            error =
                "Semantic pauses need a compatible transcription model. Choose gpt-4o-mini-transcribe or disable Semantic pauses."
            return
        }
        startTask = Task { [weak self] in
            guard let self else { return }
            do {
                guard let key = try await credentials.load() else {
                    throw MeetingError.message("Save an API key in Settings first.")
                }
                try Task.checkCancellation()
                guard session == run else { return }
                try await meetingClient.connect(
                    key: key, model: transcribeModel, realtimeAnswerModel: liveAnswerModel,
                    background: profile, semantic: semantic)
                try Task.checkCancellation()
                guard session == run else { return }
                if useMic { try await micClient.connect(key: key, model: transcribeModel) }
                try Task.checkCancellation()
                let audioCapture = captureFactory()
                audioCapture.onFailure = { [weak self] message in
                    Task { @MainActor in
                        guard let self, self.session == run else { return }
                        self.connectionFailed(message)
                    }
                }
                capture = audioCapture
                let stream = try await audioCapture.start(microphone: useMic)
                guard !Task.isCancelled, session == run else {
                    await audioCapture.stop()
                    return
                }
                connecting = false
                listening = true
                updateSharingDetection()
                audioStartedAt = now()
                lastAudioFrameAt = now()
                status = "Listening · all apps and browsers"
                reconnectNeeded = false
                resumeRecovery()
                audioTask = Task {
                    for await frame in stream {
                        guard !Task.isCancelled, self.session == run else { break }
                        if frame.microphone {
                            self.micClient.audio(
                                frame.pcm, rms: frame.rms, seconds: frame.seconds,
                                capturedAt: frame.capturedAt)
                        } else {
                            self.framesReceived += 1
                            self.lastAudioFrameAt = self.now()
                            self.level = min(1, frame.rms * 12)
                            self.meetingClient.audio(
                                frame.pcm, rms: frame.rms, seconds: frame.seconds,
                                capturedAt: frame.capturedAt)
                        }
                    }
                    if !Task.isCancelled, self.session == run, self.listening {
                        self.connectionFailed("Audio capture ended. Refresh to reconnect.")
                    }
                }
                watchdog = Task {
                    while !Task.isCancelled, self.session == run, self.listening {
                        try? await Task.sleep(for: .seconds(4))
                        guard !Task.isCancelled, self.session == run, self.listening else { return }
                        if let issue = AudioHealth.issue(
                            now: self.now(), lastFrame: self.lastAudioFrameAt, startedAt: self.audioStartedAt)
                        {
                            self.performance.event("Audio stall")
                            self.connectionFailed(issue)
                            return
                        }
                    }
                }
            } catch {
                guard session == run else { return }
                if !(error is CancellationError) {
                    connectionFailed(SecretRedactor.clean(error.localizedDescription))
                }
            }
        }
    }
    func stop() {
        speechFollowing.stop()
        speech.stop()
        sharingMonitor.stop()
        fragment = nil
        session = UUID()
        startTask?.cancel()
        startTask = nil
        audioTask?.cancel()
        watchdog?.cancel()
        meetingClient.stop()
        micClient.stop()
        let old = capture
        capture = nil
        Task { await old?.stop() }
        listening = false
        connecting = false
        level = 0
        pendingQuestions.removeAll()
        newestQuestion = nil
        recoveryQuestions.removeAll()
        recoveryIncludesActive = false
        reconnectNeeded = false
        queuePaused = false
        lastQuestionAt = .distantPast
        cancelAnswer()
        status = "Listening stopped"
    }
    private func connectionFailed(_ message: String) {
        performance.event("Connection failure")
        let waiting = recoveryQuestions + pendingQuestions
        let includesActive = recoveryIncludesActive
        stop()
        recoveryQuestions = waiting.map {
            AutomaticQuestion(
                text: $0.text, context: $0.context, endedAt: nil, itemID: nil, parentID: $0.parentID,
                intent: $0.intent)
        }
        recoveryIncludesActive = includesActive
        reconnectNeeded = true
        error = message
        status = "Connection stopped · Reconnect audio to recover"
    }
    /// Refresh replaces the displayed explanation, without restarting healthy capture or replaying a backlog.
    func refreshSession() {
        if demo {
            preview()
            status = "Demo refreshed · no audio or API calls"
            return
        }
        let shown = activeCard
        guard let latest = shown?.question ?? questionHistory.questions.last?.text else {
            if reconnectNeeded { recoverSession() } else { error = "No question to refresh yet." }
            return
        }
        guard validateQuestion(latest, hasContext: shown != nil || !questionHistory.questions.isEmpty) else {
            return
        }
        var refreshContext = questionHistory.context
        if let shown {
            refreshContext =
                "Linked request (data):\nDisplayed question: " + String(shown.question.prefix(2000))
            refreshContext +=
                "\nOriginal explanation to simplify (data):\n" + String(shown.answer.prefix(1800))
            if let parentID = shown.parentID, let parent = cards.first(where: { $0.id == parentID }) {
                refreshContext +=
                    "\nRelated question (data): " + String(parent.question.prefix(2000))
                    + "\nRelated answer (data): " + String(parent.answer.prefix(1800))
            }
        }
        let reconnect = reconnectNeeded || connecting
        cancelAnswer()
        pendingQuestions.removeAll()
        recoveryQuestions.removeAll()
        recoveryIncludesActive = false
        queuePaused = false
        clarification = nil
        clarificationContext = nil
        let displayed = activeCard?.id
        cards.removeAll { $0.id == displayed || $0.question == latest }
        selectedCardID = nil
        readingPinned = false
        beginAnswer(
            latest, context: refreshContext, parentID: shown?.parentID, intent: shown?.intent ?? .newQuestion,
            simplified: true, precision: true)
        status = "Refreshing displayed answer · simple explanation"
        if reconnect { start() }
    }
    func recoverSession() {
        performance.event("Refresh")
        if demo {
            cancelAnswer()
            error = nil
            status = "Demo refreshed"
            return
        }
        var waiting = recoveryQuestions + pendingQuestions
        if !recoveryIncludesActive, let card = cards.first,
            !card.finished || QuestionClarity.modelIssue(card.answer) != nil
        {
            waiting.insert(
                AutomaticQuestion(
                    text: card.question, context: clarificationContext ?? questionHistory.context,
                    endedAt: nil, itemID: nil), at: 0)
        }
        waiting = waiting.map {
            AutomaticQuestion(
                text: $0.text, context: $0.context, endedAt: nil, itemID: nil, parentID: $0.parentID,
                intent: $0.intent)
        }
        let reconnect = listening || connecting || reconnectNeeded
        let recentQuestionAt = lastQuestionAt
        stop()
        lastQuestionAt = recentQuestionAt
        error = nil
        clarification = nil
        clarificationContext = nil
        recoveryQuestions = waiting
        recoveryIncludesActive = !waiting.isEmpty
        if watchScreen {
            screen.stop()
            screen.start()
        }
        if reconnect {
            status = "Refreshing connection…"
            start()
        } else {
            resumeRecovery()
            if waiting.isEmpty { status = "Refreshed · ready" }
        }
    }
    private func resumeRecovery() {
        guard !recoveryQuestions.isEmpty else { return }
        let first = recoveryQuestions.removeFirst()
        recoveryIncludesActive = false
        if autoAnswer { pendingQuestions.append(contentsOf: recoveryQuestions) }
        recoveryQuestions.removeAll()
        beginAnswer(
            first.text, context: first.context, parentID: first.parentID, intent: first.intent,
            precision: first.precision)
    }
    func setScreenWatching(_ enabled: Bool) {
        guard !enabled || mode != .questions else { return }
        guard watchScreen != enabled || (enabled && !screen.enabled && !screen.starting) else { return }
        screenGuideTask?.cancel()
        screenGuideTask = nil
        watchScreen = enabled
        lastScreenFingerprint = nil
        lastGuidedFingerprint = nil
        if enabled { screen.start() } else { screen.stop() }
    }
    func adjustTextSize(_ delta: Double) {
        textSize = min(28, max(10, textSize + delta))
        autoFit = false
    }
    func explainMore() {
        guard let card = activeCard else { return }
        beginAnswer(
            card.question, context: questionHistory.context, parentID: card.id,
            intent: .followUp, precision: true)
    }
    private func adoptCodingTask(_ text: String) {
        guard mode != .questions else { return }
        let s = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let newTask = [
            "write ", "implement ", "solve ", "build ", "create ", "reverse ", "new task", "please write ",
        ].contains(where: s.hasPrefix)
        if (codingTask.isEmpty && CodingRequest.isCandidate(text)) || newTask {
            codingTask = String(text.prefix(2000))
            lastGuidedFingerprint = nil
        }
    }
    func finishCodingTask() {
        codingTask = ""
        screenGuideTask?.cancel()
        screenGuideTask = nil
        lastGuidedFingerprint = nil
        if guiding { cancelAnswer() }
    }
    private func screenUpdated(_ snapshot: ScreenSnapshot) {
        if snapshot.fingerprint != lastScreenFingerprint {
            lastScreenFingerprint = snapshot.fingerprint
            lastScreenChange = now()
            screenGuideTask?.cancel()
            screenGuideTask = nil
            guard watchScreen, autoGuide, mode != .questions, snapshot.hasCode, !codingTask.isEmpty else {
                return
            }
            let pause = screenPause
            let delay = max(2, 8 - now().timeIntervalSince(lastGuidedAt))
            // ScreenCaptureKit can emit only idle frames after a change; no second frame is required.
            screenGuideTask = Task { [weak self] in
                do { try await pause(delay) } catch { return }
                guard !Task.isCancelled, let self, self.lastScreenFingerprint == snapshot.fingerprint else {
                    return
                }
                self.screenGuideTask = nil
                self.guideStableScreen(snapshot)
            }
            return
        }
        guideStableScreen(snapshot)
    }
    private func guideStableScreen(_ snapshot: ScreenSnapshot) {
        guard watchScreen, autoGuide, mode != .questions, snapshot.hasCode, !codingTask.isEmpty,
            !answering, !connecting, recoveryQuestions.isEmpty, pendingQuestions.isEmpty,
            !queuePaused, clarification == nil,
            snapshot.fingerprint != lastGuidedFingerprint,
            now().timeIntervalSince(lastScreenChange) >= 2,
            now().timeIntervalSince(lastGuidedAt) >= 8
        else { return }
        guideNextStep()
    }
    func guideNextStep() {
        guard mode != .questions, !codingTask.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            error = "Coding task missing. Enter the task first."
            return
        }
        guard watchScreen || editor.current() != nil else {
            error = "Enable Watch screen or connect your editor for progress guidance."
            return
        }
        screenGuideTask?.cancel()
        screenGuideTask = nil
        lastGuidedFingerprint = screen.snapshot?.fingerprint
        lastGuidedAt = now()
        beginAnswer(
            "Review the current coding task and screen. Give the next small step from the visible progress, including the code to write and how to check it. Do not repeat already completed steps.",
            context: questionHistory.context, guidance: true)
    }
    func answerClarification(_ yes: Bool) {
        guard let clarification else { return }
        let context =
            (clarificationContext ?? questionHistory.context)
            + "\nClarification needing this binary reply (data):\n" + clarification
        beginAnswer(yes ? "Y" : "N", context: context)
    }
    private func handle(_ event: RealtimeEvent, speaker: String) {
        defer { turns = transcript.turns }
        switch event {
        case .committed(let id):
            transcript.update(id: id, speaker: speaker, text: "", final: false, delta: false)
            if speaker == "Meeting", !answeredIDs.contains(id), autoAnswer, listening,
                meetingClient.answersAvailable, !answering,
                preparation == nil, !queuePaused, clarification == nil,
                !(watchScreen && mode != .questions)
            {
                prepareAnswer(itemID: id)
            }
        case .delta(let id, let text):
            transcript.update(id: id, speaker: speaker, text: text, final: false, delta: true)
        case .completed(let id, let text):
            transcript.update(id: id, speaker: speaker, text: text, final: true, delta: false)
            if speaker == "You", clarification != nil {
                let reply = QuestionDetector.normalized(text)
                if ["y", "yes", "yeah"].contains(reply) {
                    answerClarification(true)
                } else if ["n", "no", "nope"].contains(reply) {
                    answerClarification(false)
                }
            }
            guard speaker == "Meeting" else { return }
            guard !answeredIDs.contains(id) else {
                performance.event("Duplicate suppressed")
                return
            }
            var text = text
            if smartConversation, let held = fragment {
                fragment = nil
                if now().timeIntervalSince(held.at) <= 10,
                    ConversationRouter.intent(text, hasContext: false) != .newQuestion
                        || [" and", " or", " because", " versus"].contains(
                            where: QuestionDetector.normalized(held.text).hasSuffix)
                {
                    text = String((held.text + " " + text).prefix(3999))
                    performance.event("Fragment joined")
                    if preparation?.itemID == id { cancelPreparation() }
                } else {
                    performance.event("Incomplete abandoned")
                }
            }
            var intent = ConversationRouter.intent(
                text, hasContext: !questionHistory.questions.isEmpty)
            // A late first transcript must not link to questions that arrived later while it was unconfirmed.
            let related: (related: Bool, card: AnswerCard?) =
                cards.isEmpty && preparation?.itemID == id && preparation?.cardID == nil
                ? (false, nil) : relatedCard(for: text)
            if intent == .newQuestion, related.related { intent = .followUp }
            if smartConversation, intent == .incomplete, autoAnswer, listening {
                rememberQuestionID(id)
                fragment = (text, now())
                if preparation?.itemID == id { cancelPreparation() }
                error = "Question incomplete · waiting for the rest."
                performance.event("Incomplete turn")
                answerPendingQuestion()
                return
            }
            if autoAnswer, listening,
                let issue = QuestionClarity.issue(text, hasContext: !questionHistory.questions.isEmpty)
            {
                if preparation?.itemID == id { cancelPreparation() }
                error = issue
                answerPendingQuestion()
                return
            }
            let candidate =
                smartConversation
                ? intent != .acknowledgement && intent != .incomplete
                : QuestionDetector.isCandidate(
                    text, hasRecentQuestion: now().timeIntervalSince(lastQuestionAt) <= 120)
            if preparation?.itemID == id,
                !autoAnswer || !candidate
            {
                cancelPreparation()
                answerPendingQuestion()
            }
            if autoAnswer, listening, candidate {
                let precision = AnswerQuality.requiresStrongerModel(
                    intent: intent, interrupted: false, requested: false)
                if guiding { cancelAnswer() }
                let target = newestQuestion
                let linked = smartConversation && (intent == .followUp || intent == .correction)
                let parent =
                    linked
                    ? related.card
                        ?? cards.first(where: {
                            if let itemID = target?.itemID { return $0.sourceID == itemID }
                            return $0.question == target?.text
                        }) : nil
                var linkedContext = ""
                if linked, let target {
                    linkedContext =
                        "\nLinked request (data):\n" + (parent?.question ?? target.text)
                        + "\nTarget answer so far (data):\n"
                        + String((parent?.answer ?? "").prefix(1800))
                }
                if smartConversation, intent == .correction, let target {
                    text = ConversationRouter.correcting(text, previous: parent?.question ?? target.text)
                    if let index = pendingQuestions.lastIndex(where: { $0.text == target.text }) {
                        pendingQuestions.remove(at: index)
                    }
                    if let i = cards.firstIndex(where: { $0.id == parent?.id }) { cards[i].superseded = true }
                }
                let urgent =
                    smartConversation && ConversationRouter.isUrgent(text, intent: intent)
                    && parent?.id == cards.first?.id && (target?.text == parent?.question)
                if urgent && (answering || queuePaused || (preparation != nil && preparation?.itemID != id)) {
                    cancelAnswer()
                    queuePaused = false
                    clarification = nil
                    clarificationContext = nil
                    performance.event("Interruption prioritized")
                }
                if precision || ConversationRelation.startsNewTopic(text)
                    || !projectLibrary.retrieve(text).isEmpty
                    || (mode != .questions && (CodingRequest.isCandidate(text) || !codingTask.isEmpty))
                    || (adaptiveAnswers && needsDeepAnswer(text))
                {
                    if preparation?.itemID == id { cancelPreparation() }
                }
                performance.event(intent.rawValue)
                rememberQuestionID(id)
                lastQuestionAt = now()
                let newTopic = ConversationRelation.startsNewTopic(text)
                if newTopic { questionHistory = QuestionHistory() }
                questionHistory.record(
                    id: id, text: text, continuesTopic: intent == .followUp || intent == .correction)
                let endedAt = meetingClient.speechEndedAt(for: id)
                newestQuestion = AutomaticQuestion(
                    text: text,
                    context: (newTopic ? "New topic (data):\n" : "") + questionHistory.context
                        + linkedContext, endedAt: endedAt,
                    itemID: meetingClient.answersAvailable && intent != .correction ? id : nil,
                    parentID: parent?.id, intent: intent, precision: precision)
                if answering || queuePaused || clarification != nil
                    || (preparation != nil && preparation?.itemID != id)
                {
                    guard pendingQuestions.count < 80 else {
                        error = "Too many questions are waiting. Use Answer for the latest question."
                        return
                    }
                    if let newestQuestion {
                        if urgent {
                            pendingQuestions.insert(newestQuestion, at: 0)
                        } else {
                            pendingQuestions.append(newestQuestion)
                        }
                    }
                } else if !showPreparedAnswer(itemID: id, question: text) {
                    beginAnswer(
                        text,
                        context: (newTopic ? "New topic (data):\n" : "") + questionHistory.context
                            + linkedContext, questionEndedAt: endedAt,
                        inputItemID: meetingClient.answersAvailable && intent != .correction ? id : nil,
                        parentID: parent?.id, intent: intent, precision: precision
                    )
                } else if let index = cards.firstIndex(where: { $0.sourceID == id }) {
                    cards[index].parentID = parent?.id
                    cards[index].intent = intent
                }
            }
        default: break
        }
    }
    private func rememberQuestionID(_ id: String) {
        guard answeredIDs.insert(id).inserted else { return }
        answeredOrder.append(id)
        if answeredOrder.count > 500 { answeredIDs.remove(answeredOrder.removeFirst()) }
    }
    private func prepareAnswer(itemID: String) {
        guard answerTemplate != .custom || !customAnswerTemplate.isEmpty else { return }
        cancelPreparation()
        let context = contextWithPreviousAnswer(questionHistory.context)
        let state = PreparedAnswer(
            itemID: itemID, endedAt: meetingClient.speechEndedAt(for: itemID), context: context)
        preparation = state
        let mode = mode
        let task = codingTask
        preparationTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await meetingClient.streamAnswer(
                    itemID: itemID, context: context, mode: mode, codingTask: task, template: answerTemplate,
                    customTemplate: customAnswerTemplate
                ) { [weak self] delta in
                    guard let self, self.preparation === state else { return }
                    state.text += delta
                    self.updatePreparedCard(state)
                }
            } catch {
                guard preparation === state else { return }
                if !(error is CancellationError) {
                    state.error = SecretRedactor.clean(error.localizedDescription)
                }
            }
            guard preparation === state else { return }
            state.finished = true
            if let question = state.question, shouldFallback(state) {
                startFallback(state, question: question)
                return
            }
            if state.cardID != nil, let issue = QuestionClarity.modelIssue(state.text) {
                error = issue
                clarification = QuestionClarity.clarification(state.text)
                clarificationContext =
                    context + "\nQuestion needing clarification (data):\n"
                    + (state.question ?? "")
                queuePaused = true
            }
            updatePreparedCard(state)
            preparationTask = nil
            if state.cardID != nil {
                answering = false
                preparation = nil
                answerPendingQuestion()
            }
        }
    }
    private func showPreparedAnswer(itemID: String, question: String) -> Bool {
        guard let state = preparation, state.itemID == itemID else { return false }
        if shouldFallback(state) {
            startFallback(state, question: question)
            return true
        }
        adoptCodingTask(question)
        error = state.error ?? QuestionClarity.modelIssue(state.text)
        clarification = QuestionClarity.clarification(state.text)
        if state.finished, error != nil {
            queuePaused = true
            clarificationContext = state.context + "\nQuestion needing clarification (data):\n" + question
        }
        var card = AnswerCard(question: question)
        card.sourceID = itemID
        card.route = "Audio"
        state.cardID = card.id
        state.question = question
        card.timing = AnswerTiming(requestStartedAt: state.startedAt, questionEndedAt: state.endedAt)
        insertCard(card)
        updatePreparedCard(state)
        answering = !state.finished
        if state.finished {
            preparation = nil
            answerPendingQuestion()
        }
        return true
    }
    private func shouldFallback(_ state: PreparedAnswer) -> Bool {
        guard state.finished, let failure = state.error,
            state.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return false }
        return !["quota", "billing", "key", "denied", "access"].contains(where: failure.lowercased().contains)
    }
    private func startFallback(_ state: PreparedAnswer, question: String) {
        let oldCard = cards.first(where: { $0.id == state.cardID })
        if let id = state.cardID { cards.removeAll(where: { $0.id == id }) }
        let selected = selectedCardID == state.cardID && state.cardID != nil
        cancelPreparation()
        queuePaused = false
        error = nil
        performance.record(
            route: "Audio", firstUseful: nil,
            total: Date().timeIntervalSince(state.endedAt ?? state.startedAt), failed: true)
        performance.event("Fast fallback")
        beginAnswer(question, context: state.context)
        if !cards.isEmpty {
            cards[0].route = "Fallback"
            cards[0].sourceID = state.itemID
            cards[0].parentID = oldCard?.parentID
            cards[0].intent = oldCard?.intent ?? .newQuestion
            if selected { selectedCardID = cards[0].id }
        }
    }
    private func updatePreparedCard(_ state: PreparedAnswer) {
        guard let id = state.cardID, let index = cards.firstIndex(where: { $0.id == id }) else { return }
        var card = cards[index]
        let wasDone = card.finished || card.interrupted
        card.answer = state.text
        card.timing?.observe(state.text, at: Date())
        card.finished = state.finished && state.error == nil
        card.interrupted = state.error != nil
        cards[index] = card
        if state.finished && !wasDone {
            performance.record(
                route: "Audio", firstUseful: card.timing?.firstUsefulSeconds,
                total: Date().timeIntervalSince(state.endedAt ?? state.startedAt), failed: state.error != nil)
        }
        if let message = state.error {
            error = message
            queuePaused = true
        }
    }
    private func cancelPreparation() {
        preparation = nil
        preparationTask?.cancel()
        preparationTask = nil
        meetingClient.cancelAnswer()
    }
    private func answerPendingQuestion() {
        guard listening, autoAnswer, !answering, !queuePaused, clarification == nil,
            preparation == nil, !pendingQuestions.isEmpty
        else { return }
        let pending = pendingQuestions.removeFirst()
        beginAnswer(
            pending.text, context: pending.context, questionEndedAt: pending.endedAt,
            inputItemID: pending.itemID, parentID: pending.parentID, intent: pending.intent,
            precision: pending.precision)
    }
    private func relatedCard(for text: String) -> (related: Bool, card: AnswerCard?) {
        let recent = questionHistory.questions.suffix(3).map(\.text)
        let matchingCards = recent.map { question in cards.first { $0.question == question && !$0.superseded }
        }
        guard
            let index = ConversationRelation.match(
                text, questions: recent, answers: matchingCards.map { $0?.answer ?? "" })
        else {
            let topic = questionHistory.topicContext
            guard !topic.isEmpty, ConversationRelation.match(text, questions: [topic]) != nil else {
                return (false, nil)
            }
            return (true, cards.first { !$0.superseded && topic.contains(String($0.question.prefix(160))) })
        }
        return (true, matchingCards[index])
    }
    private func contextWithPreviousAnswer(_ context: String) -> String {
        var result = String(context.prefix(5800))
        let spoken = transcript.turns.filter { $0.speaker == "You" && $0.final }.suffix(2)
            .map { String($0.text.prefix(300)) }.joined(separator: "\n")
        if !spoken.isEmpty, !context.contains("New topic (data)") {
            result += "\nRecent user-spoken replies (data):\n" + spoken
        }
        if !context.contains("Linked request (data)"), !context.contains("New topic (data)"),
            let previous = cards.first(where: { $0.finished && !$0.superseded })
        {
            let limit = mode != .questions && !codingTask.isEmpty ? 12000 : 1800
            result += "\nPrevious assistant answer (data):\n" + String(previous.answer.prefix(limit))
        }
        return result
    }
    func answerLatest(useTyped: Bool = true) {
        let typed = question.trimmingCharacters(in: .whitespacesAndNewlines)
        let text = useTyped && !typed.isEmpty ? typed : transcript.latestMeetingText
        ask(text)
    }
    func answerNewestWaiting() {
        guard let latest = newestQuestion ?? pendingQuestions.last ?? recoveryQuestions.last else { return }
        ask(latest.text, questionEndedAt: latest.endedAt, inputItemID: latest.itemID)
    }
    func ask(_ text: String, expanded: Bool = false, questionEndedAt: Date? = nil, inputItemID: String? = nil)
    {
        guard validateQuestion(text, hasContext: !questionHistory.questions.isEmpty) else { return }
        if demo { clear() }
        pendingQuestions.removeAll()
        lastQuestionAt = now()
        let newTopic = ConversationRelation.startsNewTopic(text)
        if newTopic { questionHistory = QuestionHistory() }
        var intent = ConversationRouter.intent(text, hasContext: !questionHistory.questions.isEmpty)
        let related = relatedCard(for: text)
        if intent == .newQuestion, related.related { intent = .followUp }
        let parentID =
            (intent == .followUp || intent == .correction) ? related.card?.id ?? activeCard?.id : nil
        questionHistory.record(
            id: UUID().uuidString, text: text, continuesTopic: intent == .followUp || intent == .correction)
        beginAnswer(
            text, context: (newTopic ? "New topic (data):\n" : "") + questionHistory.context,
            expanded: expanded, questionEndedAt: questionEndedAt,
            inputItemID: inputItemID, parentID: parentID, intent: intent)
    }
    private func beginAnswer(
        _ text: String, context: String, expanded: Bool = false,
        questionEndedAt: Date? = nil, inputItemID: String? = nil, guidance: Bool = false,
        parentID: UUID? = nil, intent: TurnIntent = .newQuestion, simplified: Bool = false,
        precision: Bool = false
    ) {
        guard validateQuestion(text, hasContext: !context.isEmpty) else { return }
        if demo { clear() }
        demo = false
        adoptCodingTask(text)
        let precision = AnswerQuality.requiresStrongerModel(
            intent: intent, interrupted: answering, requested: precision)
        cancelAnswer()
        queuePaused = false
        error = nil
        clarification = nil
        clarificationContext = nil
        answering = true
        guiding = guidance
        let evidence = projectLibrary.retrieve(
            text + " " + (parentID.flatMap { id in cards.first(where: { $0.id == id })?.question } ?? ""))
        var context = contextWithPreviousAnswer(
            parentID == nil ? context : "Linked request (data):\n" + context)
        if let parentID, let target = cards.first(where: { $0.id == parentID }) {
            let limit = mode != .questions && !codingTask.isEmpty ? 12000 : 1800
            context +=
                "\nPrevious assistant answer for linked request (data):\n"
                + String(target.answer.prefix(limit))
        }
        context += "\n" + projectLibrary.context(evidence)
        let editorSnapshot = mode != .questions && !simplified ? editor.current() : nil
        if let editorSnapshot {
            context += "\n" + editorSnapshot.context(previous: previousEditor)
            previousEditor = editorSnapshot
        }
        let codingWork =
            guidance || (mode != .questions && CodingRequest.isCandidate(text))
            || (mode != .questions && !codingTask.isEmpty)
            || (!simplified && mode == .advancedCoding)
        let deep = !simplified && adaptiveAnswers && (needsDeepAnswer(text) || mode == .advancedCoding)
        var card = AnswerCard(question: text)
        card.sourceID = inputItemID
        card.parentID = parentID
        card.intent = intent
        card.evidence = evidence
        card.route =
            precision
            ? "Precision"
            : editorSnapshot != nil
                ? "Editor"
                : watchScreen && mode != .questions && !simplified
                    ? "Screenshot"
                    : codingWork
                        ? "Coding"
                        : deep ? "Deep" : simplified ? "Refresh" : inputItemID != nil ? "Audio" : "Typed"
        insertCard(card)
        let run = UUID()
        answerRun = run
        let model = precision ? followupAnswerModel : codingWork ? codingAnswerModel : answerModel
        let template = answerTemplate
        let customTemplate = customAnswerTemplate
        let profile = background
        let mode = simplified ? (codingWork ? AssistantMode.coding : .questions) : mode
        let task = codingTask
        let includeScreen = watchScreen && mode != .questions && !simplified
        let requestAt = Date()
        answerTask = Task {
            defer {
                if answerRun == run {
                    if let completed = cards.first(where: { $0.id == card.id }) {
                        performance.record(
                            route: completed.route, firstUseful: completed.timing?.firstUsefulSeconds,
                            total: Date().timeIntervalSince(questionEndedAt ?? requestAt),
                            failed: completed.interrupted
                                || QuestionClarity.modelIssue(completed.answer) != nil)
                    }
                    answering = false
                    guiding = false
                    if simplified, status == "Refreshing displayed answer · simple explanation" {
                        status =
                            error == nil
                            ? "Displayed answer refreshed" : "Refresh failed · retry or check Settings"
                    }
                    answerPendingQuestion()
                }
            }
            do {
                guard let key = try await credentials.load() else {
                    throw MeetingError.message("No saved API key. Open Settings.")
                }
                try Task.checkCancellation()
                guard answerRun == run else { return }
                let start = Date()
                let record: @MainActor (String) -> Void = { delta in
                    guard self.answerRun == run, let i = self.cards.firstIndex(where: { $0.id == card.id })
                    else { return }
                    if self.cards[i].timing == nil {
                        self.cards[i].timing = AnswerTiming(
                            requestStartedAt: start, questionEndedAt: questionEndedAt)
                    }
                    self.cards[i].answer += delta
                    self.cards[i].timing?.observe(self.cards[i].answer, at: Date())
                }
                if let inputItemID, meetingClient.answersAvailable, listening, !expanded, !includeScreen,
                    editorSnapshot == nil, !deep, !codingWork, !simplified, !precision
                {
                    do {
                        try await meetingClient.streamAnswer(
                            itemID: inputItemID, context: context, question: text, mode: mode,
                            codingTask: task, template: template, customTemplate: customTemplate,
                            onDelta: record)
                    } catch {
                        try Task.checkCancellation()
                        let message = error.localizedDescription.lowercased()
                        guard answerRun == run,
                            cards.first(where: { $0.id == card.id })?.answer.isEmpty == true,
                            !["quota", "billing", "key", "denied"].contains(where: message.contains)
                        else { throw error }
                        performance.event("Fast fallback")
                        if let i = cards.firstIndex(where: { $0.id == card.id }) {
                            cards[i].route = "Fallback"
                        }
                        try await answerStreamer(
                            AnswerRequest(
                                key: key, model: model, question: text, context: context, background: profile,
                                expanded: false, mode: mode, codingTask: task, screenImage: nil,
                                template: template, customTemplate: customTemplate, simplified: simplified,
                                precision: precision),
                            record)
                    }
                } else {
                    let image = includeScreen ? try await screen.snapshotForAnswer().jpeg : nil
                    try Task.checkCancellation()
                    let request = AnswerRequest(
                        key: key, model: model, question: text, context: context, background: profile,
                        expanded: !precision && (expanded || deep), mode: mode, codingTask: task,
                        screenImage: image,
                        template: template, customTemplate: customTemplate, simplified: simplified,
                        precision: precision)
                    try await answerStreamer(request, record)
                }
                guard answerRun == run, let i = cards.firstIndex(where: { $0.id == card.id }) else {
                    return
                }
                guard !cards[i].answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw MeetingError.message("No answer text received. Refresh to retry.")
                }
                cards[i].finished = true
                if let issue = QuestionClarity.modelIssue(cards[i].answer) {
                    self.error = issue
                    clarification = QuestionClarity.clarification(cards[i].answer)
                    clarificationContext = context
                    queuePaused = true
                } else {
                    speech.offer(cards[i].answer, id: cards[i].id)
                }
            } catch {
                guard answerRun == run else { return }
                queuePaused = true
                if !(error is CancellationError) {
                    self.error = SecretRedactor.clean(error.localizedDescription)
                }
                if let i = cards.firstIndex(where: { $0.id == card.id }) { cards[i].interrupted = true }
            }
        }
    }
    private func needsDeepAnswer(_ text: String) -> Bool {
        let s = QuestionDetector.normalized(text)
        return [
            "system design", "design a", "deadlock", "prove", "optimize", "optimise", "thread safe",
            "concurrent", "debug", "distributed", "tradeoffs", "trade offs",
        ].contains(where: s.contains)
    }
    private func validateQuestion(_ text: String, hasContext: Bool) -> Bool {
        if answerTemplate == .custom, customAnswerTemplate.isEmpty {
            error = "Save a custom answer template first."
            return false
        }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            error = "Enter a question or wait for meeting speech."
            return false
        }
        guard hasKey else {
            showSettings = true
            error = "Save your API key to get live answers. Try demo to preview the interface."
            return false
        }
        if let issue = QuestionClarity.issue(text, hasContext: hasContext) {
            error = issue
            return false
        }
        return true
    }
    func cancelAnswer(pauseQueue: Bool = false) {
        speech.stop()
        if pauseQueue { queuePaused = true }
        cancelPreparation()
        answerRun = UUID()
        answerTask?.cancel()
        answerTask = nil
        answering = false
        guiding = false
        if let i = cards.firstIndex(where: { !$0.finished && !$0.interrupted }) {
            cards[i].interrupted = true
        }
    }
    func clear() {
        guard !listening && !connecting else {
            error = "Stop listening before clearing meeting content."
            return
        }
        cancelAnswer()
        speechFollowing.clear()
        transcript = TranscriptStore()
        questionHistory = QuestionHistory()
        turns = []
        cards = []
        selectedCardID = nil
        readingPinned = false
        fragment = nil
        performance = PerformanceLedger()
        question = ""
        codingTask = ""
        clarification = nil
        clarificationContext = nil
        error = nil
        demo = false
        answeredIDs = []
        answeredOrder = []
        pendingQuestions.removeAll()
        newestQuestion = nil
        recoveryQuestions.removeAll()
        recoveryIncludesActive = false
        reconnectNeeded = false
        queuePaused = false
        lastQuestionAt = .distantPast
        status = "Session cleared"
    }
    func preview() {
        stop()
        clear()
        demo = true
        status = "Demo · no audio capture or API calls"
        let q = "How do you prevent duplicate processing in Kafka?"
        transcript.update(id: "demo", speaker: "Meeting", text: q, final: true, delta: false)
        turns = transcript.turns
        var card = AnswerCard(question: q)
        card.answer =
            "SAY THIS:\n- Make the consumer **idempotent**: processing the same message twice has the same effect as once.\n- Store each event ID with its database update in one **transaction**, so both succeed or fail together.\n- A **unique constraint** prevents storing the same event ID twice.\n\nEXAMPLE:\nIf payment event P123 arrives again, its stored ID prevents a second charge."
        if answerTemplate == .layered {
            card.answer +=
                "\n\nDETAIL:\nKafka may deliver a message again after a retry. Checking the event ID and updating the payment together prevents a crash between those steps from causing a duplicate charge."
        }
        card.finished = true
        cards = [card]
        selectedCardID = card.id
        speech.offer(card.answer, id: card.id)
    }
    func saveKey(_ key: String) {
        do {
            try Keychain.save(key)
            credentials.replace(with: key.trimmingCharacters(in: .whitespacesAndNewlines))
            hasKey = true
            error = nil
            status = "API key saved securely"
        } catch { self.error = SecretRedactor.clean(error.localizedDescription, key: key) }
    }
    func removeKey() {
        stop()
        do {
            try Keychain.delete()
            credentials.replace(with: nil)
            hasKey = false
            error = nil
            status = "Saved API key removed"
        } catch { self.error = SecretRedactor.clean(error.localizedDescription) }
    }
    func testConnection() { ask("Explain dependency injection in Spring Boot with a tiny example.") }
    func setWindowLevel() {
        for window in NSApp.windows where window.title == "Meetly" {
            window.level = alwaysOnTop ? .floating : .normal
        }
    }
}
