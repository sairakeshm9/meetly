# Explanation cues and readable long answers — build 24

Verified October 5, 2026.

## Change

The previous renderer primarily matched a technical vocabulary. It now prioritizes model-selected explanation cues and supplements unformatted prose with short local definition/action phrases and dynamic annotation names. Each sentence/line gets its own bounded budget; overlapping explicit bold is preserved. Negation remains with actions, dangling articles/prepositions are trimmed, and inline/fenced code retain their formatting. The model receives concrete explanation-cue examples after custom-template instructions in both Responses and live-answer requests. No additional production API call is added.

Fit text now stops at 14 pt, or the user's smaller manually selected size, then relies on scrolling. Bold widths are included in measurement. Cues are prepared once per fit operation rather than extracted again for every candidate font size.

## Verification

- `./scripts/check.sh` passed: 233 native tests discovered, 222 passed, 11 opt-in skipped; 2 companion tests passed. Strict release build, format lint, secret checks and companion packaging passed.
- Nine new tests cover unfamiliar action/definition phrases, dynamic annotation names, long multi-section answers, explicit-bold priority, bounded density, negation, Unicode/streamed text, custom/Refresh instruction placement, screenshot-style content and readable long-answer fitting.
- Signed version 0.9.1 build 24 installed in `~/Applications/Meetly.app`.
- Installed-app typed Java/Spring/annotation/microservices request completed with the existing saved template. The UI reported first answer text at 3.76 seconds; this is one observation, not a latency guarantee. Audio listening and screen capture were not enabled. The temporary response was cleared.
- Accessibility verifies content/controls, not font/color attributes. Automated attributed-string tests verify the actual bold/accent ranges.

## Limits and observed follow-up

Local cues use English definition/action heuristics; the model remains responsible for selecting topic-specific meaning and contrasts. Model-selected emphasis is not deterministic. The live response repeated part of its answer with a stray fragment; this content-quality issue is recorded separately, and no clean live output-quality claim is made. The stream completed without a transport error; the existing implementation appends only output-text deltas.
