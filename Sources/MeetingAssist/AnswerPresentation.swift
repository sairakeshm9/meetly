import AppKit
import MeetingCore
import SwiftUI

enum AnswerTypography {
    static func emphasized(_ source: String) -> AttributedString {
        var result =
            (try? AttributedString(
                markdown: source, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(source)
        let plain = String(result.characters)
        // Model-selected phrases may be absent from the local vocabulary; give them the same accent.
        let explicitBold = result.runs.filter {
            $0.inlinePresentationIntent?.contains(.stronglyEmphasized) == true
        }.map(\.range)
        for range in explicitBold { result[range].foregroundColor = MeetlyPalette.accent }
        let preferred = explicitBold.compactMap { range -> Range<String.Index>? in
            let start = plain.index(
                plain.startIndex,
                offsetBy: result.characters.distance(from: result.startIndex, to: range.lowerBound))
            let end = plain.index(
                start, offsetBy: result.characters.distance(from: range.lowerBound, to: range.upperBound))
            return start..<end
        }
        for range in ExplanationEmphasis.ranges(in: plain, preferred: preferred) {
            let start = result.index(result.startIndex, offsetByCharacters: plain[..<range.lowerBound].count)
            let end = result.index(start, offsetByCharacters: plain[range].count)
            let runs = result[start..<end].runs.map { ($0.range, $0.inlinePresentationIntent ?? []) }
            for (segment, intent) in runs {
                guard !intent.contains(.code) else { continue }
                result[segment].inlinePresentationIntent = intent.union(.stronglyEmphasized)
                result[segment].foregroundColor = MeetlyPalette.accent
            }
        }
        return result
    }
    static func fit(_ answer: String, requested: Double, width: Double, height: Double, enabled: Bool)
        -> Double
    {
        let requested = min(28, max(10, requested))
        guard enabled, width > 80, height > 40 else { return requested }
        let blocks = AnswerBlock.parse(answer)
        // Prepare emphasis once, rather than re-extracting cues for each attempted font size.
        let formatted = blocks.map { block -> (AnswerBlock, String, [NSRange]) in
            guard !block.isCode else { return (block, block.text, []) }
            let styled = emphasized(block.text)
            let plain = String(styled.characters)
            let bold = styled.runs.filter {
                $0.inlinePresentationIntent?.contains(.stronglyEmphasized) == true
            }.map { run in
                NSRange(
                    location: String(styled.characters[..<run.range.lowerBound]).utf16.count,
                    length: String(styled[run.range].characters).utf16.count)
            }
            return (block, plain, bold)
        }
        func measured(_ size: Double) -> Double {
            formatted.reduce(0) { total, row in
                let (block, text, bold) = row
                if block.isCode {
                    return total + 42 + Double(block.text.components(separatedBy: "\n").count)
                        * max(10, size - 2) * 1.45 + 16
                }
                let style = NSMutableParagraphStyle()
                style.lineSpacing = 3
                let measured = NSMutableAttributedString(
                    string: text,
                    attributes: [.font: NSFont.systemFont(ofSize: size), .paragraphStyle: style])
                for range in bold {
                    measured.addAttribute(.font, value: NSFont.boldSystemFont(ofSize: size), range: range)
                }
                let bounds = measured.boundingRect(
                    with: NSSize(width: max(80, width - 8), height: .greatestFiniteMagnitude),
                    options: [.usesLineFragmentOrigin, .usesFontLeading])
                return total + ceil(bounds.height) + 12
            }
        }
        let floor = min(requested, 14)
        var size = requested
        while size > floor, measured(size) > height - 10 { size -= 0.5 }
        return max(floor, size)
    }
}

struct AnswerContentView: View {
    let answer: String
    let textSize: Double
    let autoFit: Bool
    let autoScroll: Bool
    var textOpacity = 1.0
    var speechDocument: SpeechDocument? = nil
    var speechProgress: SpeechProgress? = nil
    var readAloud = false
    var onManualScroll: (() -> Void)? = nil
    var body: some View {
        if speechProgress == nil {
            OriginalAnswerContentView(
                answer: answer, textSize: textSize, autoFit: autoFit,
                autoScroll: autoScroll, textOpacity: textOpacity)
        } else {
            TrackedAnswerContentView(
                answer: answer, textSize: textSize, autoFit: autoFit,
                autoScroll: autoScroll, textOpacity: textOpacity, speechDocument: speechDocument,
                speechProgress: speechProgress, readAloud: readAloud, onManualScroll: onManualScroll)
        }
    }
}

private struct OriginalAnswerContentView: View {
    let answer: String
    let textSize: Double
    let autoFit: Bool
    let autoScroll: Bool
    var textOpacity = 1.0
    var body: some View {
        GeometryReader { geometry in
            let size = AnswerTypography.fit(
                answer, requested: textSize, width: geometry.size.width, height: geometry.size.height,
                enabled: autoFit)
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(
                            Array(
                                AnswerBlock.parse(answer.isEmpty ? "Preparing a brief answer…" : answer)
                                    .enumerated()), id: \.offset
                        ) { _, block in
                            if block.isCode {
                                TerminalCodeView(
                                    code: block.text, fontSize: max(10, size - 2), textOpacity: textOpacity)
                            } else if let table = MarkdownAnswerTable.parse(block.text) {
                                AnswerTableView(table: table, fontSize: size).opacity(textOpacity)
                            } else {
                                Text(AnswerTypography.emphasized(block.text)).font(.system(size: size))
                                    .lineSpacing(3).opacity(textOpacity)
                                    .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                            }
                        }
                        Color.clear.frame(height: 1).id("answer-end")
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
                .onChange(of: answer) {
                    if autoScroll { proxy.scrollTo("answer-end", anchor: .bottom) }
                }
                .onChange(of: autoScroll) {
                    if autoScroll { proxy.scrollTo("answer-end", anchor: .bottom) }
                }
            }
        }
    }
}

private struct TrackedAnswerContentView: View {
    let answer: String
    let textSize: Double
    let autoFit: Bool
    let autoScroll: Bool
    var textOpacity = 1.0
    var speechDocument: SpeechDocument? = nil
    var speechProgress: SpeechProgress? = nil
    var readAloud = false
    var onManualScroll: (() -> Void)? = nil
    @StateObject private var cache = AnswerRenderCache()
    @State private var frames: [Int: CGRect] = [:]
    var body: some View {
        GeometryReader { geometry in
            let plan = cache.resolve(
                answer, requested: textSize, width: geometry.size.width,
                height: geometry.size.height, fit: autoFit)
            let passages = speechDocument?.blocks == plan.blocks ? speechDocument?.passages ?? [] : []
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(Array(plan.blocks.enumerated()), id: \.offset) { index, block in
                            let matching = passages.filter { $0.blockIndex == index }
                            Group {
                                if block.isCode {
                                    TerminalCodeView(
                                        code: block.text, fontSize: max(10, plan.size - 2),
                                        textOpacity: textOpacity
                                    )
                                    .background(blockColor(matching))
                                } else if let table = MarkdownAnswerTable.parse(block.text) {
                                    AnswerTableView(table: table, fontSize: plan.size).opacity(textOpacity)
                                        .background(blockColor(matching))
                                } else {
                                    Text(plan.rows[index].styled).font(.system(size: plan.size))
                                        .lineSpacing(3).opacity(textOpacity)
                                        .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                                        .background(
                                            SpeechHighlightLayer(
                                                layout: plan.rows[index].layout,
                                                passages: matching, progress: speechProgress,
                                                opacity: textOpacity
                                            )
                                            .allowsHitTesting(false))
                                }
                            }
                            .background(
                                GeometryReader { _ in
                                    ForEach(matching) { passage in
                                        Color.clear.frame(width: 1, height: 1)
                                            .background(
                                                GeometryReader { anchor in
                                                    Color.clear.preference(
                                                        key: SpeakingFrames.self,
                                                        value: [
                                                            passage.id: anchor.frame(
                                                                in: .named("answer-scroll"))
                                                        ])
                                                }
                                            )
                                            .position(
                                                x: 0,
                                                y: plan.rows[index].layout?.minY(passage.plainRange) ?? 0
                                            )
                                            .id("speech-\(passage.id)")
                                    }
                                }.allowsHitTesting(false))
                        }
                        Color.clear.frame(height: 1).id("answer-end")
                    }.frame(maxWidth: .infinity, alignment: .leading)
                        .background(ScrollIntentDetector { onManualScroll?() }.allowsHitTesting(false))
                }
                .coordinateSpace(name: "answer-scroll")
                .onPreferenceChange(SpeakingFrames.self) { if frames != $0 { frames = $0 } }
                .onChange(of: answer) {
                    if autoScroll && speechProgress == nil { proxy.scrollTo("answer-end", anchor: .bottom) }
                }
                .onChange(of: autoScroll) {
                    if speechProgress != nil {
                        follow(proxy, height: geometry.size.height)
                    } else if autoScroll {
                        proxy.scrollTo("answer-end", anchor: .bottom)
                    }
                }
                .onChange(of: speechProgress?.current) { follow(proxy, height: geometry.size.height) }
                .onChange(of: speechProgress?.manualPause) { follow(proxy, height: geometry.size.height) }
            }
        }
    }
    private func blockColor(_ passages: [SpeechPassage]) -> Color {
        passages.contains(where: { $0.id == speechProgress?.current })
            ? MeetlyPalette.accent.opacity(0.2 * textOpacity) : .clear
    }
    private func follow(_ proxy: ScrollViewProxy, height: Double) {
        guard let progress = speechProgress, let current = progress.current,
            SpeechScrollPolicy.shouldScroll(
                enabled: autoScroll, manualPause: progress.manualPause,
                readAloud: readAloud, uncertain: progress.uncertain,
                passageMinY: frames[current].map { Double($0.minY) },
                viewportHeight: height)
        else { return }
        proxy.scrollTo("speech-\(current)", anchor: .top)
    }
}

private struct SpeakingFrames: PreferenceKey {
    static var defaultValue: [Int: CGRect] = [:]
    static func reduce(value: inout [Int: CGRect], nextValue: () -> [Int: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, next in next })
    }
}

struct TerminalCodeView: View {
    @Environment(\.surfaceOpacity) private var surfaceOpacity
    let code: String
    let fontSize: Double
    var textOpacity = 1.0
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("CODE", systemImage: "terminal").font(
                    .system(size: 10, weight: .semibold, design: .monospaced)
                ).foregroundStyle(.secondary)
                Spacer()
                Button("Copy code") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(code, forType: .string)
                }.controlSize(.mini)
            }
            ScrollView(.horizontal) {
                VStack(alignment: .leading, spacing: 0) {
                    let lines = code.components(separatedBy: "\n")
                    ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Text(String(index + 1)).foregroundStyle(.secondary)
                                .frame(
                                    width: max(24, Double(String(lines.count).count) * fontSize * 0.65),
                                    alignment: .trailing
                                )
                                .accessibilityLabel("Line \(index + 1)")
                            Text(line.isEmpty ? " " : line).foregroundStyle(
                                isComment(line) ? MeetlyPalette.comment : Color.primary
                            )
                            .fixedSize(horizontal: true, vertical: false).textSelection(.enabled)
                        }.opacity(textOpacity).font(.system(size: fontSize, design: .monospaced)).frame(
                            minHeight: fontSize * 1.45, alignment: .leading)
                    }
                }
            }
        }.padding(12).background(
            MeetlyPalette.codeBackground.opacity(surfaceOpacity), in: RoundedRectangle(cornerRadius: 8))
    }
    private func isComment(_ line: String) -> Bool {
        let s = line.trimmingCharacters(in: .whitespaces)
        return ["//", "/*", "*", "#", "--"].contains(where: s.hasPrefix)
    }
}

struct ScreenTools: View {
    @ObservedObject var model: MeetingModel
    @ObservedObject var screen: ScreenContextController
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("CODING TASK").font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(.secondary)
            TextField("Enter the task · Java by default", text: $model.codingTask, axis: .vertical)
                .textFieldStyle(.roundedBorder).lineLimit(2...4)
            Text("Coding mode watches your screen and guides you after typing pauses.")
                .font(.caption).foregroundStyle(.secondary)
            Text(
                "Whole main-display screenshots are sent to OpenAI for coding guidance. Meetly is excluded. Nothing is saved locally."
            )
            .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if screen.starting { ProgressView("Preparing screen…").controlSize(.small) }
            if screen.enabled {
                Text(screen.snapshot == nil ? "Waiting for first screen…" : "Screen context ready").font(
                    .system(size: 11)
                ).foregroundStyle(.green)
            }
            HStack {
                Button(model.watchScreen ? "Pause screen guidance" : "Resume screen guidance") {
                    model.autoGuide = true
                    model.setScreenWatching(!model.watchScreen)
                }
                Button("Next step") { model.guideNextStep() }.disabled(
                    model.answering || (!model.watchScreen && !model.editor.enabled))
                Button("Finish task") { model.finishCodingTask() }.disabled(model.codingTask.isEmpty)
            }.controlSize(.small)
            DisclosureGroup("Optional editor connection") {
                EditorTools(model: model, editor: model.editor)
            }
            Text(
                "Answers to meeting questions take priority. Guidance follows changes after a pause, at most once every eight seconds."
            )
            .font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}
