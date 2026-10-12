# Meetly leaf icon

A simple white leaf outline on forest green `#176548`, matching Meetly button accents. No letters or decorative objects. App, header, preparation thumbnail and README use the green tile; the menu bar uses only the leaf outline as a monochrome macOS template, without any colored background.

Source geometry: `Sources/MeetingAssist/BrandMark.swift`. `Assets/MeetlyIcon.png` is the committed 1024-pixel rendition. Installation regenerates the PNG, builds all native iconset sizes, checks dimensions/alpha/encoded brand RGB, and packages the ICNS/artwork. The 18-point menu image is drawn separately from the same leaf geometry and adapts automatically to light/dark menu bars.

In-app pictures read bundled artwork directly. The installer explicitly registers the replaced app bundle with Launch Services; CFBundleIconFile names the actual ICNS including its extension. macOS app-icon lookup should resolve the real leaf artwork rather than a generic placeholder.
