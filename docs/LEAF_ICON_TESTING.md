# Leaf icon and system metadata verification

October 5, 2026; Meetly 0.9.1 build 21.

- All app pictures use a white leaf outline on forest green. No letters remain in the mark. The 18-point menu bar uses the same leaf geometry as a monochrome template, without a green tile; macOS supplies white/dark rendering.
- Full checks passed: 214 native tests discovered, 203 passed, 11 opt-in skipped; two companion tests passed. Release build, strict format lint, secret scan and companion packaging passed.
- Regression verifies menu intrinsic size, template flag, transparent background and equal RGB channels for all visible menu pixels. Aqua/Dark Aqua checks verify white leaf and transparent outer corners. Packaging verifies 16–1024 pixel variants, alpha and green background, allowing small-size resampling tolerance.
- Stable signed installation and bundle checks passed. The declared icon now references `MeetlyLeafIcon.icns`; installation updates bundle timestamp and registers its metadata with Launch Services.
- Root cause observed for old app artwork: macOS icon lookup kept returning the cached M even after the image was replaced and app registration refreshed. Giving the leaf resource its own filename and updating the bundle metadata resolved this. The actual installed app lookup was exported and visually confirmed to show the leaf, not M or a generic placeholder.
- A local menu-strip screenshot confirmed the leaf is white, with no colored background. Startup accessibility exposed the app picture. Final state READY/Questions, no audio or coding capture started.
- Only the installed stable bundle was found by the app-identity Spotlight lookup. Other UI surfaces may hold an already-rendered preview until reopened; no Finder restart or global icon-cache deletion was performed.
