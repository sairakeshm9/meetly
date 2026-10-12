# Answer layout and Follow my speech — build 30

## Scope

The basic answer box uses the original SwiftUI renderer from commit `20cbf12` when following is off: the same ScrollView, Text rendering, fit calculation, 3-point line spacing, 12-point block spacing, terminal code and table views. The replacement native scroll container has been removed after the user reported broken fitting and scrolling. The answer controls remain. Follow my speech is now a collapsible disclosure in the top answer line, next to Audio, opening its controls in a popover. It never adds an answer-panel row, whether following is on or off.

With following on, the same Text styling and spacing are used with a separate background highlight canvas. Both the highlight canvas and input observer return nil from hitTest and allow input through. Highlighting never edits the text or adds paragraph padding. No microphone/transcript status lines are inserted below the toolbar; optional Mic diagnostics stay in a popover. Error messages remain visible.

Manual scrolling holds automatic movement, **without freezing speech matching or highlighting**. Resume scroll restores automatic movement. Holding scroll leaves the local microphone running; uncheck Follow my speech or use Stop to release it. Tables/code remain whole-block matches. Glyph layout supplies sentence positions for invisible scroll anchors. The highlight layer never owns scrolling.

## Local recognition

Apple's time-indexed progressive SpeechTranscriber supplies provisional text and word times. Resume, history switches and read-aloud completion filter stale words while accepting new words in a continuous utterance. There is no API or cloud transcription fallback. Microphone activity and recognized words are stored only in memory. This requires supported macOS 26+ and a local English model. Local recognition still has nonzero delay; a specific speech-to-highlight latency is not guaranteed.

An optional CLI integration check generates and transcribes a Python audio file without microphone recording, playback, API calls or downloads. It skipped on this host because Apple's asset inventory in the CLI process did not report the module installed. The installed app did return real microphone text in earlier checks; this does not establish the CLI test passed or the user experience is smooth.

## Regression verification

Core coverage includes the exact reported Python answer, matching all three sentences; own words, synonyms, repeat/backtrack, skipping, partial/final results, uncertainty, negation, ambiguous repetitions and a 400-passage answer. App coverage includes permission/error/retry, cancellation and late callbacks, resume word-time filtering, read-aloud echo suppression, history positions and bounded retention.

Renderer checks prove cache reuse across 100 repeated updates, fitting equivalence with the original typography, complete long-answer text retention, distant glyph positions, resize/text-size/answer invalidation, Unicode/Markdown range correctness, and noninteractive overlays/observers. Highlight layout must leave the full original attributed string unchanged. Repeated unchanged recognition and wheel-pause notifications must not publish repeated controller updates.

Build 30 check: **280 native tests discovered, 268 passed, 12 optional checks skipped, zero failures**. Both companion tests, release compilation with warnings as errors, strict formatting, credential scan and companion packaging passed. The focused regression run passed 28 tests. `git diff --check` passed.

A source comparison confirmed the restored default answer renderer matches the earlier `20cbf12` renderer exactly apart from whitespace and its private type name. In the earlier build 29 installed-app check, version 0.9.1 was reopened with the same signed app identity. The real app generated a Python answer with comments, line numbers, expected output and details (first text 1.68 seconds). Accessibility scroll actions reached **0** at the start and **1** at the end, with intermediate scroll positions changing normally. This validates the installed scroll range via accessibility; physical mouse-wheel smoothness and perceived fitting need user observation because the answer window is capture-excluded.

Saved template, light theme, 15 pt, Fit text and Auto-scroll were preserved. Following was left off and meeting capture was not started. The user was actively interacting during the final optional text-size-button check, so that check was not completed; the existing typography/text-control regression tests passed.

Perceived speech-to-highlight speed is **not declared fixed**. Cached noninteractive highlight rendering, word-time acceptance and continued matching during manual scroll have regression coverage, but this restored build still needs a real reading trial once the basic answer box is satisfactory. Earlier app microphone text and build 27/28 checks are not used to claim that this trial passed.

References: [Apple SpeechAnalyzer overview](https://developer.apple.com/videos/play/wwdc2025/277/) and [time-indexed progressive preset](https://developer.apple.com/documentation/speech/speechtranscriber/preset). Build requires Xcode 26+; CI uses macOS 26. Other app features retain the macOS 15 deployment target.

Build 30 adds UI sizing checks for the collapsed header in both disabled and enabled states. Long recognized text must not increase its single-row height. Installed and reopened version 0.9.1 build 30 with the same signed identity. The top-line disclosure opened and closed the speech popover in both expanded and minimized answer-toolbar layouts; its checkbox remained off. A live Java/Spring Boot answer included 20 commented code lines and the complete detail section. Accessibility scroll actions reached 0 at the start and 1 at the end. The app was left at the start of this answer, with 15 pt, Fit text and Auto-scroll preserved, speech options collapsed and microphone/meeting capture off. The fit calculation retains its readable minimum and scroll fallback, rather than making a long answer illegibly small.
