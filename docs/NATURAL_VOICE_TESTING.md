# Meetly 0.9.0 voice and icon verification

Date: October 4, 2026. Installed bundle: `~/Applications/Meetly.app`, stable bundle ID `com.akshay.meetingassist`. Branch: `codex/natural-voice-options`.

## Implemented

- Mac speech remains the default and makes no speech network request or Keychain read.
- Ava Premium was downloaded through Apple's Read & Speak settings on this Mac. Highest-quality installed American female voice wins unless explicitly selected otherwise; removed selections safely fall back.
- Spoken text removes template labels and Markdown, turns examples/analogies into conversational transitions, pronounces common initialisms, and preserves explanatory code comments while omitting executable code.
- Native paragraph synthesis adds breathing pauses and uses owned PCM buffers to avoid callback-buffer reuse. Both local and API voices use an app-specific audio engine.
- Optional API voice selection: current `gpt-realtime-2.1-mini`, plus lower-price `gpt-4o-mini-tts-2025-12-15` until its January 6, 2027 retirement. Marin, Coral, Shimmer. Streaming starts before complete audio generation; paid API use is explicitly shown. No idle requests or automatic paid retries.
- API failure before audio starts falls back to Mac. Partial-stream failure stops without replaying the same answer. New questions and Stop cancel stale audio/network work. Speed and voice settings persist.
- Connected AirPods/headphones are detected separately from Mac default output. Both speech engines select the headphone device directly; other apps' default output is unchanged. Devices/alive/source/default changes are watched; connected route is shown even with Audio off.
- Abstract turquoise/silver orbital icon on charcoal with no central egg/seed, no meeting symbol, and transparent outer corners. Startup and README thumbnails use matching artwork. The separate menu-bar vector is an 18-point monochrome template, white on dark menu bars.

## Bugs found and fixed during manual verification

| Issue | Root cause and fix |
| --- | --- |
| Preview silent before an answer appeared, with no visible explanation | Status existed only under an answer card. Voice popover now displays status directly. |
| Connected AirPods still reported Mac speakers | Only default output was inspected/watched. Connected output inventory, alive/topology watchers, deterministic preference and per-app device routing added. |
| API preview made UI unresponsive/high CPU | Device notifications reattached CoreAudio listeners, creating a notification feedback loop. Registrations now stay stable until selected device or inventory actually changes; regression verifies 100 repeated notifications cannot reattach. |
| Menu-bar icon oversized/cropped | MenuBarExtra uses NSImage intrinsic size, ignoring SwiftUI frame constraints. Copy with 18-point intrinsic size, preserving full app icon, plus regression test. |

## Automated and live checks

- Unit/integration tests cover voice selection/removal, choice persistence, spoken text, comment/code separation, bounded chunks, little-endian PCM, native buffer ownership/paragraph streaming, realtime event config, incremental HTTP streaming, HTTP access rejection, empty/wrong-format/truncated audio, cancellation, native-only operation, error/fallback behavior, device preference/status and monitor registration stability.
- Full check runs native tests, release compile with warnings as errors, format lint, secret scan, two VS Code companion tests and companion packaging.
- Final checks: 210 native tests discovered, 199 passed, 11 opt-in skipped; two companion tests passed. Release compile, format, secret scan, packaging, icon and installation checks passed.
- Icon build checks dimensions at 16/32/128/256/512/1024 pixels, transparent corners and nonempty center; app bundle/signature checks run on installation.
- Real small paid speech request (no recording/playback) succeeded for Budget TTS: first PCM about 1.87 seconds, full stream 2.78 seconds. Realtime Mini succeeded: first PCM about 2.05 seconds, full stream 2.68 seconds. These are single cold-request observations, not guaranteed latency or a ranking. No microphone or system-audio capture started.
- Installed UI showed **Meetly output · Akshay's AirPods Pro**, **Mac · Free, offline**, **Best available**, and Ava Premium while previewing. Native preview completed without a displayed playback error. After the monitor fix, API/Marin preview completed with no displayed error, Stop became disabled, UI stayed responsive and observed process CPU was 1.2 percent. Startup accessibility exposes **Meetly app picture**. No listening or screen watching was started.
- Build 18 was installed at the stable path. A local menu-strip screenshot confirmed the monochrome orbital icon appears white and fits within the menu bar. In-app artwork is loaded directly from the packaged PNG; installation verifies it matches the committed source. Final preferences: Mac, Best available, Audio on, pace 1.00×, READY with no capture started.

## Remaining limitations

- Human listening quality is subjective; preview and choose a voice/speed you prefer.
- Physical unplug/reconnect for wired/USB headsets, alternate Bluetooth devices, and speaker-default-plus-connected-headphones remain device-specific hardware checks. Selection logic for that last scenario is automated.
- Generic USB/Bluetooth devices can be speakers. Inspect the route name.
- Network/access limits affect API speech; no 1.2-second guarantee. Long speech needs multiple bounded requests.
- App text is the source for API voice synthesis; generative realtime narration is instructed to read it verbatim, but exact-word fidelity should be checked for critical use.
