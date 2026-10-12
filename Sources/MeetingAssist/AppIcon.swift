import AppKit

@MainActor
enum AppIcon {
    static var applicationImage: NSImage {
        // Read our bundled artwork directly, avoiding stale Launch Services icon caches after updates.
        if let url = Bundle.main.url(forResource: "MeetlyArtwork", withExtension: "png"),
            let image = NSImage(contentsOf: url)
        {
            return image
        }
        return NSApp.applicationIconImage
    }

    static func menuBarImage() -> NSImage {
        // Intrinsic size constrains MenuBarExtra; macOS supplies monochrome menu contrast.
        BrandMark.menuImage()
    }
}
