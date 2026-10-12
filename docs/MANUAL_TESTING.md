# Meetly 0.7.0 manual testing and bug status

Tested October 3, 2026 on this Mac, using the signed app at `~/Applications/Meetly.app`. Audio capture remained stopped during the new-release tests. Synthetic typed requests used the existing API configuration. Existing custom template and font settings were preserved; window transparency was restored to 25%, text to 0%, and capture exclusion to enabled.

## Installed-app checks

| Check | Result | Evidence / limit |
| --- | --- | --- |
| Startup preparation | PASS | Resume prompt and saved custom-template text present after launching updated app. |
| Compact / Expand removal | PASS | Main toolbar has Reset answer box; no Window preset menu. Resize implementation removed. |
| Light / Dark theme | PASS | Header toggles both ways; screenshots inspected for readable buttons, numbered Java code and comments. Theme persistence also tested automatically. |
| Advanced tools | PASS | Disclosure reveals capture/sharing controls, diagnostics, Try demo and Clear session. |
| New icon | PASS | Generated 1024px speech-bubble M icon visually inspected; signed bundle contains ICNS. |
| Offline demo | PASS | Canned answer renders with Audio control; app reports no capture/API calls. |
| Independent transparency | PASS | Window 100%, text 0% retains answer in native UI; text 100% removes answer text while controls remain; Show solid text restores it independently. Native-window opacity/background tests pass. |
| Audio on speakers | PASS | Audio produces “Select AirPods/headphones … Current: MacBook Pro Speakers,” with no playback. |
| Older pinned Refresh | PASS | Asked dependency injection then database index; selected older answer; Refresh produced simpler dependency-injection bullets and numbered Java example. |
| Custom template | PASS | Initial typed answers followed saved SUMMARY/ANALOGY format; Refresh used brief format. |
| Minimize answer controls | PASS | Header/toolbars collapse while answer and restore control remain. |
| Native American female voice generation | PASS | Local Voice 4 (en-US, female) rendered 139,264 PCM frames to memory without playback. |
| Physical AirPods / headset voice | TODO | No headset selected for this test. Actual perceived voice, sound and disconnect timing need a hardware test. |
| New live meeting / rapid interruptions | TODO | Synthetic queue/regression tests pass; no live participant call was started during this release test. |
| Universal entire-display invisibility | NOT GUARANTEED | macOS capture methods vary; transparency affects the local view too. Existing capture-exclusion setting still needs viewer validation. |

## Bugs found and disposition

| Finding | Status | Fix / remaining work |
| --- | --- | --- |
| Refresh targets newest question rather than older displayed card | FIXED | Uses active card, linked parent and original explanation. Unit regression and installed paid typed test passed. |
| Whole-window opacity also fades text | FIXED | Native window alpha stays 1; only background fills fade. Text has a separate setting. |
| Duplicate transparency controls / crowded tool groups | FIXED | One combined transparency popover; advanced tools collapsed by default; preset-size menu deleted. |
| Refresh status/help incorrectly says latest after targeting displayed answer | FIXED | Updated menu, tooltip and status to displayed answer. |
| Old 0.6 app showed “Audio processing is overloaded” before upgrade | OPEN INVESTIGATION | Observed on the existing listening session; session stopped. No reproducible cause established, and no new live capture test was started. Do not claim fixed. |
| Bluetooth-output classification can include speakers; generic USB names may be rejected | KNOWN LIMIT | Device name is shown; select/check the intended Mac output. No universal headphone identity assumption. |

## Automated checks

183 native tests discovered: 173 passed, ten opt-in checks skipped. Two Node companion tests passed. Strict release build, formatting, secret scan and VS Code packaging passed. JetBrains companion compiled against installed PyCharm SDK; IntelliJ runtime remains unverified. Bundle signature and icon-resource checks passed.

New coverage includes missing answer/voice/output, American-female voice selection, speech stop/disconnect/stale completion, theme persistence, independent transparency, pinned linked-follow-up Refresh and stale cancelled answer rejection. Existing coverage includes answer-box drag bounds and window resizing; removing presets leaves those paths intact.
