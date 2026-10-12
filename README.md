# Meetly

<img src="Assets/MeetlyIcon.png" alt="Meetly forest-green icon with a white leaf" width="128">

**Meetly 0.9.1** is a native macOS meeting reference assistant. It listens to capturable sound from all apps and browsers, transcribes questions, and streams concise technical answers with examples. It supports resume/project context, follow-ups, Java-default coding help, optional screen/editor context, readable answer history and customizable transparency.

Use it with Zoom, Teams, Google Meet, Webex, Slack calls or browser meetings without changing the audio source. Audio-device/source compatibility still needs a test before an important meeting. Muted participants provide no sound to recognize.

## Quick start

1. Open **Meetly.app** from your user Applications folder. It runs as a menu-bar app, without a normal Dock or Command-Tab icon.
2. Open **Settings** with the gear button or Command-comma. Enter your API key locally and choose **Save to Keychain**, then **Test connection**. API billing is separate from a ChatGPT subscription. Never put credentials in source files or chat.
3. The preparation screen appears each launch. Use **Upload & analyze resume**, select your **Answer template** immediately below it, review the projects/skills, and add confirmed project incidents. Choose **Ready to answer**, or **Skip for now**. Reopen this screen with **Prepare resume & projects**.
4. Choose **Questions** for general discussion. Click **Start listening** and grant macOS recording permission if needed. Have someone ask an audible question. Confirm that the meter and transcript react and an answer appears.
5. You can also type a question and choose **Answer** without starting audio. Java is the default for coding; explicitly requested languages are preserved.
6. When finished, click **Stop listening** or press Command-period. **Clear session**, available while stopped, discards meeting text and answers.

For a coding exercise, select **Coding** once: screen watching and progress guidance start automatically. Keep your editor visible, ask or enter the task, and write from Meetly's commented full solution. Follow-ups show the explanation and next edit alongside the solution. Use **Pause screen guidance** when needed, or switch to **Questions** to stop coding capture.

No capture starts merely because the app opens. Start listening begins audio capture. Screen watching can start when you explicitly enable it or when an active sharing signal switches the app into Coding mode.

## Requirements and installation

- macOS 15 or newer for the app; macOS 26+ for Follow my speech. Xcode 26+ command-line tools (macOS 26 Speech SDK) to build from source.
- An OpenAI API project with billing and access to the selected models.
- **System Settings → Privacy & Security → Screen & System Audio Recording** permission for Meetly. Microphone permission is needed for **Include my microphone** or local **Follow my speech**; local following does not require screen/system-audio recording permission. Accessibility is used for the global shortcut if available; manual Answer remains a fallback.
- A local JDK for the optional Java Compile/Run sample actions.
- Use agreed meeting transcription and approved handling of client information.

```sh
# Run verification first; no API calls by default.
./scripts/check.sh

# Optional: include the JetBrains companion using an installed IDE SDK.
python3 scripts/build-editor-companions.py --intellij-home '/Applications/PyCharm.app/Contents'

# Build a signed local app and install at a stable path.
./scripts/install-app.sh
open "$HOME/Applications/Meetly.app"

# Build without installing, or show an offline sample.
./scripts/build-app.sh
open 'dist/Meetly.app'
open 'dist/Meetly.app' --args --demo
```

The installer migrates `~/Applications/Meeting Assist.app` when its bundle identity matches. Close the old app first. Display branding is now Meetly; the internal executable/package names, `com.akshay.meetingassist` bundle ID, Keychain services and `~/Library/Application Support/Meeting Assist` folder remain stable to preserve existing credentials, profiles, editor connections and permissions.

The build automatically selects an Apple Development certificate when exactly one is available. Set `CODESIGN_IDENTITY` to choose another installed signing identity. Otherwise, it uses an ad-hoc local signature, which can require recording permission again after a rebuild. Sharing this app with other Macs requires appropriate distribution signing/notarization; this repository does not provide a notarized public installer.

## Resume, project experience and preparation

Upload a text-readable PDF or UTF-8 TXT resume, up to 10 MB and 50 PDF pages. Scanned/locked PDFs need text extraction first. The resume is analyzed through OpenAI and shown as skills/projects for review. A key must be saved first. Choose a **Current project**, or use all projects.

For real incidents, supply the project, symptom, root cause, action, outcome and tradeoff. Unknown details should stay unknown. The app can explain issues you supplied, including bottlenecks and scenarios, but must label hypothetical examples rather than invent experience or claim you performed unprovided work. A local keyword search supplies up to two relevant project excerpts per answer. **Provided context** displays them; it does not certify the model's interpretation.

Resume/notes stay in memory unless you click **Save encrypted profile**. The saved profile uses AES-GCM and a separate Keychain encryption key. **Load saved profile** loads it for review each launch. **Delete saved profile** removes its saved file while retaining the current in-memory preparation. Meeting transcripts and answer history are not included in saved profiles.

### Answer templates

Select a template below Upload resume, or change it later in Settings. The choice persists across launches.

| Template | Requested answer format |
| --- | --- |
| **Brief bullets & comparisons** | SAY THIS: 2–3 short bullets. Comparisons/types use a compact table and takeaway bullets. EXAMPLE when useful, including actual code for coding tasks. |
| **Custom template** | Your saved description controls sections, bullet counts, tone and example layout. |
| **Bullets, example & detail** | SAY THIS: 2–3 brief bullets, then EXAMPLE, then DETAIL with a fuller explanation. |

Choose **New custom template…** to reveal a name field and description box. Saved templates appear by name in the same selector in preparation and Settings. Select one to reuse or edit it; saving an edit updates that item. Select **New custom template…** to add another. Previously saved single formats migrate automatically to **My saved template**. Describe the format (for example, “Start with a one-sentence summary, then two bullets, then an analogy and Java code when needed”) and click **Save template**. Up to 2,000 characters are saved locally across restarts; unsaved edits do not change answers. An empty custom format is rejected with a short issue banner. Custom formats override the standard section/table layout while retaining grounding, clarity and coding/clarification rules. Refresh uses its simpler format regardless of this choice.

The built-in templates request natural spoken explanations, plain definitions of technical terms and bold keywords. Formatting is requested from the model; clarity/content quality still needs your review. Highlights prioritize **explanation cues**: definitions, actions, consequences and contrasts, rather than only language/product names. The model receives this requirement after template instructions, including custom formats. A local fallback finds short definition/action phrases and annotation names in unformatted answers, with a separate emphasis budget for every sentence and bullet. Existing model-bold phrases retain priority, negation stays with an action, and most connecting prose stays plain. Inline and fenced code keep their code formatting. This adds no API calls. When Fit text is enabled, long answers shrink only to 14 pt (or your smaller manually chosen size) and then scroll; fitting includes the extra width of bold text. Tables render in native columns and scroll horizontally when necessary. **Brief cue** shows only SAY THIS; disable it to see examples, code and detail.

## Modes and model routing

| Mode | Behavior |
| --- | --- |
| **Questions** | Normal technical answers and follow-ups. No editor/screenshot consumption. Coding answers are still possible from the question text. |
| **Coding** | One selection enables main-display screen watching and progress guidance. Includes IDE navigation, full commented solutions, next edits, explanations and follow-ups. Java is the default; requested languages are preserved. An active task and its interruptions use the coding model. |

**Settings → Answer model** controls ordinary typed/deep/fallback requests. **Coding model** defaults to `gpt-6.1-sol`; Sol requests use low reasoning with a bounded 4,000-token output budget. **Fast live answers** uses the configured realtime model for eligible audio questions. Sol is an API model, not a use of your Codex chat subscription. Change the model fields if your project has different access.

Adaptive answer depth uses more reasoning for design/debugging/concurrency questions. Larger models, screenshots and detailed answers can take longer; a fixed 1.2–1.3-second ceiling is not guaranteed. **Session health & speed** reports first-useful-text p50/p95 by route, failures and recent event counts.

### Automatic mode while sharing

**Auto mode while sharing** is enabled by default. While listening, local main-display OCR looks for recognizable visible sharing controls such as “Stop sharing”/“You're presenting.” A positive signal switches to **Coding** and enables **Watch screen**. A recognized stopped/idle sharing signal returns to **Questions**. Repeated active signals preserve an explicit pause of screen guidance. Hidden/unknown controls keep the current sharing state instead of guessing that sharing ended.

macOS does not provide this app with a universal event for another app's sharing session. Detection is best-effort, English phrase-based and may miss hidden/localized toolbars or mistake similar screen text. Use **Sharing off · mark started** / **Sharing on · mark stopped** to set the state immediately when needed. Disable Auto mode to retain manual mode selection. The detector's OCR is processed locally; separate Watch screen answer/guidance requests can send screenshots to OpenAI.

## Screen and editor help

Select **Coding** to start watching the entire main display and enable guidance after typing pauses automatically. **Pause screen guidance** stops capture; **Resume screen guidance** restarts it. Switching to **Questions** stops coding capture. Screen permissions are still required. IDE navigation is included in Coding; there is no separate Advanced Coding selection. Screenshots/OCR can contain other visible apps; review what is visible before using this mode. Capture exclusion attempts to omit Meetly. The app does not click/type in your IDE: it supplies instructions for you to carry out.

**Next step** requests guidance immediately for the current coding task. Automatic guidance waits for a quiet period and changed code/editor state, with requests spaced at least eight seconds apart. An active coding task uses this answer structure: answer the latest question, **NEXT STEP**, **FULL SOLUTION** (complete relevant function/query or small files, with imports, indentation, comments and UI line numbers), and **HOW IT WORKS** with sample output and checks. Follow-ups still include the complete solution; incomplete essential input instead produces an issue/clarification. Coding output requirements override custom templates that suppress code. Full output remains bounded to 4,000 tokens; large projects require focused tasks. New meeting questions take priority. Unclear input or unavailable context shows a short red issue banner; model clarification asks Y/N with matching buttons. Continuous overlapping speech remains a transcription limitation.

**Optional editor connection → Use connected editor** is an optional, more precise alternative/addition to screenshots. Install a bundled companion from **Editor Companions**, then explicitly connect it in VS Code/JetBrains. It supplies active-file text, unsaved changes, cursor, bounded diagnostics and changes since the last answer. Frames expire after 12 seconds, and Questions mode does not consume them. See [editor companion installation and data handling](editor-companions/README.md).

Java **Compile** and **Run sample** check a standalone active-file class in a temporary sandbox, with no network/personal-file access, a ten-second limit and bounded output. An expected-output match validates that sample only. Compilation, a successful main run and a matching assertion are separate results; none proves the solution is correct for all inputs. Project dependencies should be checked inside your IDE.

## Follow-ups, interruptions and Refresh

- Only the last **three accepted questions**, a short relevant answer and up to two recent microphone replies are supplied as conversation context. Up to ten answer cards can be browsed without enlarging that model context.
- Independent questions arriving during generation are queued. Smart conversation joins incomplete fragments, ignores acknowledgements and links short follow-ups. A linked urgent “why” or correction can interrupt its target while retaining independent waiting questions. These local English rules are heuristic.
- **Refresh** (Command-R) immediately clears and re-answers the **currently displayed question**, including an older pinned answer. It cancels stale generation and waiting requests, uses that card and its linked parent as context, and gives simpler 2–3 bullets with a small example when useful. It skips new screenshot/editor capture for this refresh and overrides detailed/custom templates. Healthy listening connections stay connected.
- **Meeting menu → Reconnect audio and recover queue** is the separate recovery action for a stalled/disconnected listening connection. It preserves context and retries interrupted/pending questions. Sleep/wake recovery uses this path too.
- **Cancel answer** pauses the waiting queue. **Answer newest** handles the newest waiting request. A valid manual Answer replaces active/waiting work. Empty/incomplete input is rejected before cancelling valid work.
- Stopping listening or disabling automatic answers clears waiting questions. **Clear session** removes meeting history/recovery state while stopped.

## Reading, layout and window controls

| Control | Action |
| --- | --- |
| **Pin window** | Keeps Meetly above ordinary windows. It does not pin an answer or guarantee capture invisibility. |
| **Pin answer** | Keeps the card you are reading visible while newer answers arrive. |
| **Previous/Newer, History, Show latest** | Browse recent answer cards or follow new ones again. |
| **Your answer chevron** | Collapse/restore the heading and answer toolbars; the answer and small restore button remain visible. |
| **Recent conversation chevron** | Collapse/expand the transcript footer. |
| **Sidebar chevron / Show controls** | Collapse/restore the left controls in a wide window. Narrow layouts use the Controls popover. |
| **A− / A+** | Change requested answer font size from 10–28 pt. |
| **Fit text** | Shrink text to fit when possible; lengthy content remains scrollable. |
| **Auto-scroll** | Follow new answer text as it streams. Turn off to read an earlier section. |
| **Reset answer box** | Restore the answer box to its automatic size. Resize the outer window using standard macOS edges or corners. |
| **Answer-box corner handle** | Resize the answer area within the window; double-click or Reset answer box restores it. |
| **Try demo** | Show a canned Kafka/idempotency sample, offline. It clears the existing displayed session and is disabled while listening/connecting. No audio capture or API request. |
| **Copy answer / Copy code** | Copy the response, or code without the line-number gutter. |

Code appears in a terminal-style box with line numbers, indentation and comments; it is still Java/Python/etc., rather than converting programs to shell scripts. Bold emphasis and table layouts are supported for explanations.

### Window and text transparency

Use the half-filled-circle **Window transparency** button to open both independent sliders. **Window transparency** fades background surfaces only: 0% is solid and 100% removes those fills while keeping text and controls visible. **Text transparency** fades answer prose, code, question and conversation text separately: 0% is readable and 100% hides that text. For example, window 100% and text 0% leaves readable text over the apps behind Meetly. The percentages do not multiply.

**Show solid window** resets the background; **Show solid text** resets text. Preferences persist. The Meeting menu and **Command-Shift-0** also restore a solid background. Controls stay usable; there is no separate recovery window. Transparency affects your view and shared capture alike, and does not provide selective invisibility.

### Themes and read-aloud

Click the **sun/moon** header button to switch the whole app between Light and Dark, including preparation and Settings. Settings also has a Theme selector. The choice persists across launches. Code, tables and bold keywords use theme-aware colors. Meetly uses a simple forest-green icon with a white leaf.

Turn **Audio on** in the answer heading once. The setting persists until you switch it off, including across app restarts. Every successfully completed answer and follow-up is then read automatically in your chosen voice. **Mac voice is the default**, with no speech API charge. Audio mode is available before an answer arrives and while the answer controls are minimized.

Narration reads the explanation, approach and code comments; it skips executable code lines and line numbers. Code remains visible. New requests stop stale narration, and failed/incomplete answers are not read. Turn **Audio off** to stop playback and future automatic reading.

The adjacent **Voice & audio** button opens **Voice & audio**, including voice source, preview, and the pace slider. The slider sets Slow–Fast from approximately **0.65×–1.50×**. Its setting persists. **Normal speed** restores 1×. Releasing the slider during playback restarts the current explanation at the new pace; future answers use that pace automatically.

**Voice & audio → Meetly output** shows the currently detected route and updates when devices connect or disconnect, even with Audio off. When Audio is on, Meetly detects connected headphones independently of the Mac's default speaker selection. It keeps an already selected headphone output; otherwise it prefers a named AirPods/headphone/headset device over generic Bluetooth/USB audio. Both Mac and API speech are routed directly to that device using Meetly's own audio engine, leaving other apps' Mac sound output unchanged. New device, device-alive, default-output, and wired jack/source changes are monitored. If headphones are absent, Audio mode waits and later reads only the latest waiting answer. Disconnecting stops stale speech. Bluetooth/USB outputs may also be speakers; check the displayed route name. Built-in speakers are rejected. If a particular device refuses direct routing, the banner asks you to select it in Mac Sound settings.

Choose **Mac · Free, offline** for immediate local speech. **Best available** selects the highest-quality installed American female voice; you can pick an individual voice instead. On this development Mac, **Ava (Premium)** is installed and selected automatically. Other Macs need to download their own voice: **Download Mac voices… → Read & Speak → System voice details → Voice**, search **Ava**, and download **Premium**. Reopen the voice popover after downloading. A one-time Apple asset download is needed; subsequent speech is local. Speech skips template labels, adds short pauses between ideas, and pronounces common technical initialisms more clearly. The displayed answer is unchanged. Voice quality remains dependent on Apple's installed voice.

Choose **API · Natural, paid** only when you want online speech. It uses the existing Meetly Keychain key and sends only the cleaned spoken answer text (not a new screen image or microphone recording) to OpenAI. Choose **Marin**, **Coral**, or **Shimmer**, then **Preview voice** through the selected headphones. These are AI-generated voices. **Stop audio** stops current/pending playback while leaving automatic Audio mode enabled; **Audio off** disables it. Voice choices and pace survive restarts.

| API option | Model and behavior | Additional cost / limitation |
| --- | --- | --- |
| Realtime Mini · Live streaming | `gpt-realtime-2.1-mini`; streams PCM as it arrives | $0.60/million input text tokens, $2.40/million output text tokens, $20/million output audio tokens |
| Mini TTS · Budget | `gpt-4o-mini-tts-2025-12-15`; streams PCM without waiting for the full file | $0.60/million input text tokens, $12/million output audio tokens; scheduled retirement January 6, 2027 |

Prices were checked October 4, 2026 against [Realtime Mini](https://developers.openai.com/api/docs/models/gpt-realtime-2.1-mini), [Mini TTS](https://developers.openai.com/api/docs/models/gpt-4o-mini-tts), and [deprecations](https://developers.openai.com/api/docs/deprecations). They are usage rates, not a fixed price per answer. These speech charges are separate from answer/transcription charges. No idle speech requests, automatic API retries, or speech requests in Mac mode. Network latency varies; streaming cannot promise a 1.2-second first voice response. Prefer Mac for minimum cost and delay.

An API failure **before playback begins** uses the installed Mac voice and shows the reason. A failure after audio starts stops with a warning, without replaying the explanation from the beginning. New questions, Refresh, Audio off, or headphone route changes cancel old speech and pending network work. Long spoken text is split into bounded requests; ordinary short answers use one request. Native speech uses [AVSpeechSynthesizer](https://developer.apple.com/documentation/avfaudio/avspeechsynthesizer). Physical headset listening quality and disconnection/reconnection remain separate hardware checks.

**Advanced tools** in the sidebar holds workspace sharing, session diagnostics, Try demo and Clear session. Expand it only when needed. Duplicate text-transparency controls and Compact/Expand window presets were removed; normal macOS edge/corner resizing and Reset answer box remain.

## Screen sharing and app presence

**Request capture exclusion** applies native macOS capture-protection requests to Meetly surfaces. Earlier local ScreenCaptureKit and Chrome entire-display tests excluded the protected window on this Mac. This does **not** certify Zoom/Teams receiver-side visibility, every browser, recording method or remote-access tool. Test with a viewer before relying on it.

The optional **Meeting Workspace** shows a filtered main-display copy excluding Meetly. Share that specific window for a deterministic filtered source; sharing the physical entire display follows the meeting app's capture behavior. Zoom's window-filtering capture setting may help where available. Capture protection, automatic mode detection and transparency are separate features.

Meetly uses accessory activation (`LSUIElement`) so it has no normal Dock/Command-Tab presence. A previously pinned Dock shortcut can remain until you remove it. Closing the main window keeps the menu-bar app/session running; use the menu bar to reopen or quit it. Hiding Dock presence does not conceal it from Activity Monitor.

## Shortcuts

| Shortcut | Action |
| --- | --- |
| **Command-Shift-0** | Restore a solid window while Meetly is focused. |
| **Command-R** | Clear/re-explain the latest accepted question simply. |
| **Command-Return** | Answer typed/latest heard question while focused. |
| **Control-Option-Space** | Global answer-latest shortcut when registration/permissions allow. |
| **Command-period** | Stop listening. |
| **Command-comma** | Settings. |
| **Command-Q** | Quit. |

## Privacy, persistence and costs

Audio is sent to OpenAI while listening; no local audio recording is made. Optional microphone audio supplies your replies as context. Resume analysis, project excerpts, questions and selected editor/screen context may be sent to OpenAI for answers. Responses requests use `store: false`; provider-side retention remains governed by your API account terms.

API keys are stored in macOS Keychain, not this repository. Saved project profiles are encrypted locally. Session transcripts/answers stay in memory and are discarded by Clear session/quit. Appearance/template/coding-model preferences persist locally. Editor companions temporarily publish active-file text to a private **plaintext** local bridge; disconnect in the editor to delete it. Do not connect secret-bearing files. Pattern-based key redaction cannot detect all secrets.

API usage is billed to your project. Resume analysis, stronger coding models, screenshots, detailed answers and automated guidance can increase cost. Disable Watch screen, Auto next step or listening when unnecessary. The source contains no private resume, actual incident notes, API keys, meeting recordings or screenshots.

## Troubleshooting

| Problem | Check / recovery |
| --- | --- |
| Meter/transcript does not move | Confirm remote speaker is unmuted and audible, recording permission is enabled, and playback is capturable. Stop/start listening. Protected sources may be unavailable. |
| Transcript appears but no answer | Enable Answer automatically, inspect the red issue banner, check the saved key/model access, or submit a typed question. |
| Wrong/unclear transcription | Restate or type the question. The app does not infer missing speech with certainty. |
| Last answer is stuck/too complex | Refresh for a fresh simple explanation. Use Reconnect audio and recover queue if the connection itself is stuck. |
| Sharing did not switch mode | Show the sharing toolbar or use the Sharing button. Hidden/localized controls can prevent detection. |
| Background disappeared | Window transparency → Show solid window, or Command-Shift-0. Text is controlled separately. |
| Text vanished but controls remain | Window transparency popover → Show solid text. |
| Resume analysis failed | Save/test the key first; use a readable unlocked PDF/TXT within limits; stop listening before changing context. |
| Coding lacks file/screen context | Choose Coding/Advanced Coding, enable Watch screen or connect a supported editor; keep the useful editor visible. |
| Editor context stale | Connect in the IDE again and update the active file. Disconnect/reconnect clears the handoff. |
| 401 / quota / unavailable model | Check the saved project key, billing/limits and exact model access in your API project. |
| Recording permission reset after build | Use a stable app path and signing identity; re-enable recording permission and restart if macOS requests it. |
| Meetly visible to a viewer | Verify the meeting app's capture method/settings; use the filtered Workspace window where acceptable. Native exclusion has no universal guarantee. |

**Semantic pauses** is optional. The default `gpt-live-transcribe` and `gpt-realtime-whisper` use manual commits; semantic pauses requires a compatible transcription model (for example `gpt-4o-mini-transcribe`). The app reports incompatible combinations rather than silently changing models. Real-call benchmarking remains necessary.

## Development and verification

```sh
swift test                              # deterministic native tests; paid checks skip
swift build -c release -Xswiftc -warnings-as-errors
xcrun swift-format lint --strict --recursive Sources Tests Package.swift
python3 scripts/check-secrets.py
node --test editor-companions/vscode/test.js
./scripts/check.sh                      # all ordinary checks + VSIX packaging
MEETING_ASSIST_PRESENCE_APP_CHECK=1 swift test --filter AppPresenceTests
```

The opt-in presence check requires the installed app to be running. Paid audio/API tests additionally require explicit test credentials/audio fixtures; CI skips them and never loads your Keychain. `MEETLY_LIVE_RELEASE_CHECK=1 swift test --filter MeetlyLiveReleaseTests` explicitly opts into two paid text requests using an already accessible local Keychain credential, without prompting or capturing audio. It checks Sol Java compilation/sample output and custom labels. JetBrains companion compilation requires an installed IDE SDK and is separate from CI. VS Code companion packaging is included in ordinary checks. See `.github/workflows/check.yml` for macOS CI.

Modules: `MeetingCore` contains request/transcript/conversation/template contracts. `MeetingAssist` contains SwiftUI/AppKit UI, capture, Keychain, model orchestration and editor/screen integration. `Tests` covers queue ordering, rapid questions, interruptions, stale deltas, refresh/recovery, request routing, layouts, privacy bounds and persisted settings. No third-party Swift package dependencies are required.

### 0.9.0 validation

The app icon, startup thumbnail, header picture, README image and 18-point menu-bar icon use the same simple leaf shape, with no letters. The app artwork uses a white leaf on forest green (`#176548`), matching the light-theme button accent. The menu bar uses just the leaf outline as a monochrome template: white on dark backgrounds and dark on light backgrounds, with no colored tile. All sizes are drawn from the same leaf geometry; no runtime image API request is needed.

Local and API voice tests cover premium voice selection, safe fallback when a selected voice is removed, saved choices, conversational speech cleanup, bounded long text, PCM decoding, streaming before network EOF, cancellation, API errors before/after playback, and native-only operation without key/network access. `MEETLY_LIVE_SPEECH_CHECK=1 swift test --filter LiveSpeechTests` makes one small paid Realtime voice request using an already accessible Keychain key without recording or playing sound; CI skips it. See [natural voice testing](docs/NATURAL_VOICE_TESTING.md) for verified results and limitations.

### 0.8.0 validation

190 native tests were discovered: 180 passed and ten default opt-in checks skipped. New checks cover read-aloud validation, voice selection, output disconnection, stale speech completion, theme persistence, independent transparency, pinned follow-up Refresh and cancelled output. See [automatic audio verification](docs/AUTOMATIC_AUDIO_TESTING.md) for this release and [previous manual testing and bug status](docs/MANUAL_TESTING.md) for the earlier UI checks.

The previous 0.6 release's paid Sol/custom-template checks passed. Its Sol first useful text was 1.80 seconds in one synthetic trial; these observations are not live-call latency guarantees. The local JetBrains companion compiles against PyCharm's SDK; IntelliJ runtime remains unverified.

## 0.9.1 simplified Coding verification

Coding mode now combines automatic screen watching, progress hints, IDE navigation and complete commented solutions on task follow-ups. The mode menu has just Questions and Coding. Full checks passed (202 native tests passed, 11 opt-in skipped; two companion tests passed), with installed mode/pause/resume checks and a real API coding follow-up that compiled and ran successfully. See [simplified Coding verification and limits](docs/SIMPLIFIED_CODING_TESTING.md).


### Stronger follow-up answers

Follow-ups (including fully worded questions related to any of the last three questions, concepts introduced in their answers, “why?”, “what if?” and clarification requests), corrections/dissatisfaction (“that is wrong”, “try again”), and interruptions use the **Follow-up / Better answer model** in Settings. The default is the existing GPT-6.1 Sol model. **Better answer** retries the displayed answer with this model and its linked context; **Refresh** also uses it while retaining the simpler refresh behavior. Ordinary new questions keep their usual fast model. Automatic follow-ups discard speculative fast replies and use the stronger API route; queued interruptions retain this routing.

These answers request 2–3 precise bullets, roughly 70–120 words, with one tiny example when helpful. Long custom layouts are overridden for this route; coding solutions remain complete with concise accompanying prose. Only bounded recent conversation, compact active-topic notes and the relevant linked answer are included. Stronger reasoning may increase response time and API cost; it improves the opportunity to reason carefully but cannot guarantee correctness. If the configured model is unavailable, Meetly reports the failure rather than silently switching to the cheap model.

Related-question routing combines shared topic terms, technical concept families, answer-introduced terms and references such as “that”. Ambiguous contextual questions (including risks, tradeoffs and conditional scenarios) conservatively use the stronger route. The stronger model receives the bounded context to resolve the actual relationship. This is local heuristic routing, not a perfect semantic classifier; clear unrelated definitions keep the fast route. The context uses a count limit of three questions rather than expiring solely because of a short pause.

For discussions longer than three questions, compact local topic notes retain the opening request, up to six constraint/correction request excerpts and the four latest topic request excerpts (maximum 2,400 characters). The last three full question texts remain available alongside those notes. Notes come from user requests, not model-invented facts; later corrections take precedence. This adds no summarization API call. It is bounded continuity, not perfect recall of every statement in an unlimited meeting.

Explicit transitions such as “new topic”, “switch gears”, or “moving on” reset the active question context; older cards remain in history. Otherwise, related questions keep the discussion linked across the meeting, including after pauses.

See [stronger follow-up verification](docs/PRECISION_FOLLOWUP_TESTING.md) for the routing, long-discussion, cancellation and UI checks for build 25.

### Follow my speech (optional, local)

Use the **Follow my speech** disclosure in the top answer line, next to Audio. It opens collapsible controls in a popover; select **Follow my speech** there to follow your speaking position. Click the header control again or outside the popover to collapse it. Its controls never take a separate answer-panel row. This is off at each launch and works without starting meeting listening or using an API key. Building this version requires Xcode 26+ (macOS 26 Speech SDK). The feature requires macOS 26+ and a supported on-device English speech model. Your microphone audio for this feature is processed by Apple's local SpeechTranscriber; there is no cloud transcription fallback. On first use, macOS may download the English model assets. Allow Microphone access if prompted.

- The answer keeps the same font size, line spacing, bullets, code and table layout with following either on or off. Speech updates change highlight colors without remeasuring the answer. The current matching sentence gets an inline green background. Final matched passages receive a faint background; the next eligible passage has a light cue. This is a reading aid, not proof that you explained the whole passage correctly.
- Exact phrases, shared concepts and supported synonyms can match your own wording. Single generic words, ambiguous matches or detected opposite negation hold position with **Tracking uncertain**. Arbitrary paraphrases are not guaranteed to match.
- **Fit text** shrinks to the existing readable minimum when needed. Answers that remain longer than the box scroll; you can manually scroll to the first or last line.
- **Auto-scroll** follows the matched passage using its text layout position when it leaves the comfortable visible area; streaming answer text no longer pushes the tracker to the bottom. Turn Auto-scroll off to keep highlighting without scrolling.
- Using the mouse wheel, scrollbar, or scroll keys while the answer is focused holds automatic scrolling. Highlighting continues as you speak, including after manual scrolling. Clicking or selecting answer text does not hold it. You can scroll freely to any part of the full answer; automatic movement holds until **Resume scroll**. **Hold scroll** and **Restart position** are also available; holding scroll leaves speech tracking and the local microphone running. Uncheck **Follow my speech** or use Stop to release the microphone.
- **Mic** opens optional input diagnostics with the actual default input device, sound detection and recent recognized words. They stay in the popover rather than taking space below the answer controls.
- Each of the last ten answer cards retains its own reading position. New answers begin without the previous answer's highlight; returning to a history card restores its position. Word timestamps reject old speech after answer changes and resume while accepting new words in a sentence that began earlier.
- Tracking pauses while Meetly reads aloud, so its own voice is not treated as your explanation. Headphones reduce meeting-speaker leakage into your microphone. Participant speech leaking into the mic cannot always be distinguished from your speech.
- Microphone changes, permission failures, engine errors or overload stop following and show a short red message with **Retry following**. Answer generation and meeting capture continue independently. Clear session discards reading positions.

Passage indexing runs in a cancellable background task; matching uses a local index and never waits for an additional answer/model request. This avoids extra API round trips and charges for the tracker. Local recognition and processing still have nonzero delay and CPU cost; zero added latency and perfect alignment are not guaranteed. The existing **Include my microphone** setting is separate: it still sends your responses to OpenAI for meeting context when enabled. Tables and code are tracked as whole blocks; code syntax, comments, line numbers and existing keyword emphasis remain visible.

See [Follow my speech verification and limitations](docs/FOLLOW_MY_SPEECH_TESTING.md) for test coverage, the local matching benchmark and live-test status.
