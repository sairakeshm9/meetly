# Richer keyword highlighting — build 22

Verified 2026-10-05.

## Behavior

- Multiple important concepts in each sentence and bullet receive bold/accent formatting.
- Longest technical phrases win overlapping matches; plural forms and complexity notation are supported.
- Model-selected bold phrases outside the local vocabulary also receive the theme accent.
- Italic intent is preserved; automatic highlighting leaves inline code alone. Fenced code uses the existing terminal renderer.
- Shared model instructions request selective emphasis across the answer, keeping connective prose plain.
- The matcher is compiled once. No extra API calls are introduced.

## Verification

- `./scripts/check.sh`: 220 native tests discovered, 209 passed, 11 opt-in tests skipped; 2 editor companion tests passed. Strict release compilation, Swift formatting, secret checks and companion packaging passed.
- Six added regression tests cover multi-sentence/bullet coverage, overlapping phrases, Unicode/case/punctuation, empty/plain input, streamed phrase completion, unfamiliar model-bold phrases, styling preservation and unchanged text.
- `./scripts/install-app.sh`: signed bundle installed at `~/Applications/Meetly.app`, version 0.9.1 build 22.
- Manual installed-app check: preparation sheet opened, offline demo rendered the complete three-bullet Kafka answer and example without Markdown markers. Cleared the demo and left Questions mode READY, without starting audio or screen capture.

The accessibility tree verifies the answer content but does not expose bold/color attributes; those are verified by attributed-string regression tests. Paid live model output was not tested in this change. Model-selected emphasis varies with its generated content and custom answer instructions.
