# Green Meetly branding verification

October 5, 2026; Meetly 0.9.1 build 20, branch `codex/green-meetly-brand`.

- App/Finder icon, startup thumbnail, header picture, README picture and colored 18-point menu-bar icon share one rounded white M on forest green `#176548`, matching the app's light-theme button accent.
- Shared AppKit geometry in `BrandMark.swift` replaces both the generated orbital bitmap and separate orbital menu paths. Installation regenerates the 1024-pixel asset, resizes all native iconset sizes, and packages the same PNG/ICNS. In-app artwork continues to bypass old icon caches.
- Full checks passed: 214 native tests discovered, 203 passed, 11 opt-in skipped; two companion tests passed. Strict release build, formatting, secret scan and companion packaging passed.
- Regression checks cover intrinsic menu size, colored green rendering, white symbol and transparent corners in both Aqua and Dark Aqua. Packaging checks validate dimensions, alpha, exact encoded brand RGB and matching bundled artwork. RGB comparison occurs before display-profile conversion.
- Signed stable app installation passed. Startup accessibility exposed Meetly app picture. A local menu-strip screenshot confirmed the new green/white mark fits the menu bar. App was left READY in Questions mode, with no audio/screen capture started.
- The 1024-pixel source was visually inspected. The fixed green/white tile intentionally keeps its contrast in either appearance; it does not switch to a monochrome template.
