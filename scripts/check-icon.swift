import AppKit
import Foundation

let root = URL(fileURLWithPath: CommandLine.arguments[1])
for (filename, expected) in [
    "icon_16x16.png": 16, "icon_32x32.png": 32, "icon_128x128.png": 128, "icon_256x256.png": 256,
    "icon_512x512.png": 512, "icon_512x512@2x.png": 1024,
] {
    guard let data = try? Data(contentsOf: root.appendingPathComponent(filename)),
        let bitmap = NSBitmapImageRep(data: data), bitmap.pixelsWide == expected,
        bitmap.pixelsHigh == expected, bitmap.hasAlpha,
        let corner = bitmap.colorAt(x: 0, y: 0), corner.alphaComponent < 0.01,
        let center = bitmap.colorAt(x: expected / 2, y: expected / 2), center.alphaComponent > 0.95
    else { fatalError("Invalid icon dimensions, transparency or content: \(filename)") }
    // Compare the PNG's encoded RGB, before display-profile conversion changes channel values.
    // Tiny icons mix edge pixels during high-quality downsampling.
    let colorTolerance = expected <= 32 ? 0.06 : 0.03
    guard let green = bitmap.colorAt(x: expected / 2, y: expected / 8),
        abs(green.redComponent - 23.0 / 255) < colorTolerance,
        abs(green.greenComponent - 101.0 / 255) < colorTolerance,
        abs(green.blueComponent - 72.0 / 255) < colorTolerance
    else { fatalError("Icon must match Meetly's forest-green buttons: \(filename)") }
}
print("Icon dimensions, transparent corners, nonempty center and brand green verified.")
