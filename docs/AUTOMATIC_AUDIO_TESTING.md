# Meetly 0.8.0 automatic audio verification

October 4, 2026. Branch: `codex/automatic-headphone-audio`.

Audio now has a persistent on/off mode and a saved Slow–Fast pace slider. Successfully completed answers trigger narration automatically. Coding narration retains explanations, approach and code comments while omitting executable lines. Headphone-output changes retry only the latest waiting answer; new questions cancel stale speech. Playback uses an installed female en-US voice and the selected Mac output.

| Check | Result | Evidence |
| --- | --- | --- |
| Mode available before first answer | PASS | Installed answer heading has Audio off/on and Audio pace. |
| Mode persists across restart | PASS | Enabled Audio, quit/reopened app: Audio on remains. |
| Pace slider and persistence | PASS | Selected 1.35×, restarted, popover still showed 1.35×. Normal speed returned to 1×. |
| Automatic answer handling | PASS | Model integration test completes a synthetic answer and invokes the speech engine without a button click. |
| Waiting for headphones | PASS | Offline demo automatically attempted narration, showed waiting for headphones with Mac speakers selected, and kept mode on. |
| Off prevents future narration | PASS | Mode off clears waiting/playback state; regression test confirms later answers stay silent. |
| Latest waiting follow-up on connection | PASS, simulated | Injected output change from unavailable to headphones reads latest follow-up once; obsolete answer omitted. |
| Pace applied to speech | PASS, simulated | Engine receives slower/faster rates; changing pace restarts active explanation and uses saved rate. |
| Code explanation/comments only | PASS | Java, Python and SQL comment extraction tested; inline comments retained, executable lines and quoted URL excluded. |
| Failed/incomplete answer stays silent | PASS | Failed partial model request does not invoke speech engine. |
| Minimized toolbar | PASS | Audio mode and pace remain accessible while answer controls are collapsed. |
| Device label duplication | FIXED | Manual demo showed repeated speaker/source name; formatting now omits duplicate source names and has regression assertions. |
| Physical headphones / AirPods playback | TODO | No eligible headset selected during manual test. Perceived voice/speed and actual connect/disconnect timing remain unverified. |
| Live meeting with narration enabled | TODO | No new meeting capture was started. Current-process audio exclusion remains enabled; actual echo/crosstalk needs a live headset check. |

190 native tests discovered: 180 passed, ten opt-in checks skipped. Two Node tests passed. Strict release build, formatting and secret scanning passed. Signed app installation and bundle-icon checks passed. The previous version's native American-female speech rendering check passed without playback.

Audio follows macOS's selected output; connecting a device alone does not guarantee macOS selects it. Wired headphone terminals, named headphones and Bluetooth/USB outputs are recognized. Generic Bluetooth/USB devices may also be speakers, so the selected device name is displayed. Built-in speakers are rejected. Tests restored Audio off and Normal pace; meeting capture stayed stopped. Other user preferences were preserved.
