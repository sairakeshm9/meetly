# Stronger follow-up answers — build 25

## Behavior

- Independent questions retain the fast model. Related fully worded questions, short follow-ups, corrections/dissatisfaction, manual interruptions, Better answer and Refresh use the configurable stronger model (default `gpt-6.1-sol`).
- Precision replies request 2–3 bullets and about 70–120 words. They address the new concern, check assumptions and correct earlier mistakes when warranted. Full relevant commented coding solutions remain available.
- Local routing checks the last three questions, linked answer concepts, technical topic families and ambiguous contextual wording. It can link an older of those three questions, rather than always attaching to the newest answer.
- A compact active-topic note retains the opening request, up to six constraint/correction excerpts and four recent topic request excerpts, capped at 2,400 characters. These are user request excerpts, not verified facts or invented project history. Later corrections take precedence. This supplies continuity beyond three questions without a summary API request or a full transcript.
- Explicit “new topic”, “switch gears” and similar transitions clear question/topic context and discard speculative prepared replies. Earlier answer cards remain in history.
- Stronger-model failures are visible; there is no silent cheap-model fallback.

## Automated verification

`./scripts/check.sh` covers native tests, release compilation with warnings treated as errors, strict formatting, secret scanning, companion tests and companion packaging.

Native regression cases include:

- Fully worded related questions, answer-introduced concepts and links to an older of three topics.
- Corrections, dissatisfaction, urgent interruptions and bounded contextual routing.
- Stronger model selection, concise prompt precedence over lengthy custom layouts, and complete-code instructions.
- Better answer targeting an older selected/pinned card; no unrelated newest answer substituted.
- Cancelled requests delivering late text; stale output cannot overwrite the newer answer.
- Model unavailable, preference persistence, duplicate audio IDs and follow-ups after a long pause.
- Independent queued questions, mixed fast/precision queues and forty rapid ordinary requests.
- Twenty-question topic continuity, hundred-request size bounds, duplicate events, explicit topic reset and a wrapped correction surviving beyond the recent-question window.
- A seven-question app flow retains an opening inventory constraint after it leaves the three-question window; a subsequent explicit topic switch excludes it.
- An earlier unconfirmed audio question cannot link to later queued questions.

Latest native result: **249 discovered; 238 passed; 11 opt-in checks skipped; zero failures**. Skipped tests require live credentials, permissions or explicitly enabled environment checks. API request/streaming behavior here is verified with deterministic test transports, not a paid live model-quality evaluation.

## Limits

Topic classification is heuristic. Notes and context are bounded; perfect recall throughout an unlimited meeting is not promised. Missing details may require a Y/N clarification. A stronger model can take longer and cost more, and cannot guarantee correctness. Precise latency on a real meeting and real model output quality require live testing.

No audio listening or screen watching is needed for the local verification.

## Installed UI verification

Installed `/Users/akshay/Applications/Meetly.app`, version 0.9.1 build 25, using the stable bundle ID. Code-sign verification succeeded. Native UI checks confirmed the Follow-up / Better answer model setting shows `gpt-6.1-sol`, ordinary questions retain `gpt-6-luna`, and the local demo displays the renamed Better answer button (disabled for demo to avoid API calls). The saved custom template, light theme, 15 pt, Fit text and Auto-scroll preferences were preserved. Demo content was cleared; the app was left READY in Questions mode with audio capture/screen watching stopped. No paid live model request was made in this verification.

Strict formatting, credential scan, release build, both companion tests and companion packaging passed. `git diff --check` passed.
