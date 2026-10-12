# Meetly 0.9.1 simplified Coding verification

October 4, 2026; stable installed app `~/Applications/Meetly.app`, build 19.

## Behavior

- Mode menu has Questions and Coding. Coding starts screen watching and enables automatic progress guidance. IDE navigation is included; legacy Advanced Coding remains an internal compatibility case only.
- Pause/Resume screen guidance replaces setup toggles. Optional editor integration is collapsed. Returning to Questions stops capture and discards the snapshot. Repeated mode/sharing signals preserve an explicit pause.
- Active coding tasks request the latest answer, next edit, full relevant solution with comments/imports/indentation, and a short explanation/sample/check. This requirement overrides custom templates that suppress code. Missing essential input still asks a Y/N clarification.
- Task follow-ups use the coding model and a bounded latest-answer context (12,000 characters), alongside the last three questions. Coding output is bounded to 4,000 tokens. Ordinary questions without an active task keep their regular route.
- Screen capture samples the main display; automated guidance still requires changed visible code, a quiet period and at least eight seconds between hints. Spoken questions take priority. The user writes and runs code themselves.

## Verification

- Full checks passed: 213 native tests discovered, 202 passed, 11 opt-in skipped; two editor-companion tests passed. Release compilation with warnings as errors, format lint, secret scan and companion packaging passed.
- New regressions cover entering/re-entering Coding, explicit pause retention, returning to Questions, unavailable permission, complete-code instructions on follow-ups, custom-template precedence and output capacity. Existing capture, rapid-question, interruption, recovery and last-three-context tests passed with fake captures.
- Opt-in real API release check passed: Java reverse-string solution compiled/ran and printed `cba`; a why-follow-up kept NEXT STEP/FULL SOLUTION/HOW IT WORKS and complete commented Java that also compiled/ran. Ordinary custom formatting remained intact. No real meeting audio was captured. First useful text in the first cold request was about 2.76 seconds, not a latency guarantee.
- Installed UI showed exactly Questions/Coding; selecting Coding immediately displayed Screen context ready and Pause screen guidance. Pause disabled Next step and removed screen context; Resume restored it. Returning to Questions removed coding controls. Final app state is READY/Questions, no listening or coding capture active.
- Interactive simulated demo stages were exercised in a browser: selection, typing pause, why-follow-up and completion. Full solution stays visible at every stage. Demo Java independently compiled and passed sample, duplicate, negative, no-pair and empty-input cases.

## Limits

- Full solutions are model-generated; the live checks validate the tested examples, not all languages/tasks. Large projects need focused relevant files/functions within the output limit.
- Screenshots require macOS permission and useful visible main-display context. Overlapping speech, hidden IDE details and screenshot/OCR limitations still apply.
- The demo is a simulated walkthrough, not a recording of a live meeting or proof of universal screen-sharing invisibility.
